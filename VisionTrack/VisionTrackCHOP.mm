// VisionTrack CHOP — TouchDesigner カスタムオペレータ(macOS / Apple Vision)
//
// 初期バウンディングボックスで指定した「任意のオブジェクト」を映像内で追跡する。
// VNTrackObjectRequest + VNSequenceRequestHandler。人以外の物体も追える点で
// Blob Track TOP(Nvidia 専用)の代替に近い。
//
// 使い方: Init Bbox U/V/W/H(uv・中心+サイズ)で追跡対象を囲み、Start Tracking を
// パルス → 以降のフレームで追従する。見失ったら再度パルスで再シード。
//
// 出力チャンネル: valid / u / v / w / h / confidence(u,v は bbox 中心・uv 座標)
//
// 実装: 推論はワーカースレッドで非同期(cook 非ブロック・結果は1〜2フレーム遅れ)。

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

struct TrackState
{
    bool valid = false;
    float u = 0, v = 0, w = 0, h = 0;   // 中心+サイズ(uv)
    float confidence = 0;
};

class VisionTrackCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit VisionTrackCHOP(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionTrackCHOP() override
    {
        {
            std::lock_guard<std::mutex> lock(myMutex);
            myQuit = true;
        }
        myCond.notify_all();
        if (myWorker.joinable())
            myWorker.join();
    }

    void getGeneralInfo(CHOP_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
        ginfo->timeslice = false;
    }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override
    {
        info->numChannels = 6;
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t index, OP_String* name, const OP_Inputs*, void*) override
    {
        const char* names[6] = {"valid", "u", "v", "w", "h", "confidence"};
        name->setString(names[index]);
    }

    void execute(CHOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        myFlip = inputs->getParInt("Flip") != 0;
        myFast = strcmp(inputs->getParString("Trackinglevel"), "fast") == 0;
        myMinConf = (float)inputs->getParDouble("Minconfidence");
        mySeedU = (float)inputs->getParDouble("Initbbox", 0);
        mySeedV = (float)inputs->getParDouble("Initbbox", 1);
        mySeedW = (float)inputs->getParDouble("Initbboxsize", 0);
        mySeedH = (float)inputs->getParDouble("Initbboxsize", 1);

        const OP_TOPInput* top = inputs->getParTOP("Top");
        if (active && top && top->totalCooks != myLastCookSeen) {
            std::unique_lock<std::mutex> lock(myMutex, std::try_to_lock);
            if (lock.owns_lock() && !myHasPending && !myBusy) {
                OP_TOPInputDownloadOptions opts;
                opts.pixelFormat = OP_PixelFormat::BGRA8Fixed;
                opts.verticalFlip = myFlip;
                myPending = top->downloadTexture(opts, nullptr);
                if (myPending) {
                    myHasPending = true;
                    mySubmitCount++;
                    myLastCookSeen = top->totalCooks;
                    lock.unlock();
                    myCond.notify_one();
                }
            }
        }

        TrackState s;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            s = myTrack;
        }
        const bool on = active && s.valid;
        output->channels[0][0] = on ? 1.0f : 0.0f;
        output->channels[1][0] = on ? s.u : 0.0f;
        output->channels[2][0] = on ? s.v : 0.0f;
        output->channels[3][0] = on ? s.w : 0.0f;
        output->channels[4][0] = on ? s.h : 0.0f;
        output->channels[5][0] = on ? s.confidence : 0.0f;
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Top");
            p.label = "TOP";
            p.page = "Vision Track";
            manager->appendTOP(p);
        }
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Vision Track";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Initbbox");
            p.label = "Init Bbox Center";
            p.page = "Vision Track";
            p.defaultValues[0] = 0.5;
            p.defaultValues[1] = 0.5;
            for (int i = 0; i < 2; i++) {
                p.minSliders[i] = 0.0;
                p.maxSliders[i] = 1.0;
            }
            manager->appendXY(p);
        }
        {
            OP_NumericParameter p("Initbboxsize");
            p.label = "Init Bbox Size";
            p.page = "Vision Track";
            p.defaultValues[0] = 0.2;
            p.defaultValues[1] = 0.2;
            for (int i = 0; i < 2; i++) {
                p.minSliders[i] = 0.0;
                p.maxSliders[i] = 1.0;
            }
            manager->appendXY(p);
        }
        {
            OP_NumericParameter p("Start");
            p.label = "Start Tracking";
            p.page = "Vision Track";
            manager->appendPulse(p);
        }
        {
            OP_NumericParameter p("Stop");
            p.label = "Stop Tracking";
            p.page = "Vision Track";
            manager->appendPulse(p);
        }
        {
            OP_StringParameter p("Trackinglevel");
            p.label = "Tracking Level";
            p.page = "Vision Track";
            p.defaultValue = "accurate";
            const char* names[] = {"accurate", "fast"};
            const char* labels[] = {"Accurate", "Fast"};
            manager->appendMenu(p, 2, names, labels);
        }
        {
            OP_NumericParameter p("Minconfidence");
            p.label = "Min Confidence";
            p.page = "Vision Track";
            p.defaultValues[0] = 0.3;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 1.0;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "Vision Track";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (strcmp(name, "Start") == 0)
            mySeedRequested = true;
        else if (strcmp(name, "Stop") == 0)
            myStopRequested = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 6; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[6] = {"executes", "submits", "analyzes", "analyze_ms",
                                "seeds", "losses"};
        float values[6] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           myAnalyzeMs.load(), (float)mySeedCount, (float)myLossCount};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (!myLastError.empty())
            warning->setString(myLastError.c_str());
    }

private:
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            bool seed = false, stop = false, fast;
            float su, sv, sw, sh, minConf;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                download = std::move(myPending);
                myHasPending = false;
                myBusy = true;
                seed = mySeedRequested;
                stop = myStopRequested;
                mySeedRequested = false;
                myStopRequested = false;
                su = mySeedU; sv = mySeedV; sw = mySeedW; sh = mySeedH;
                fast = myFast;
                minConf = myMinConf;
            }

            TrackState state;
            const auto t0 = std::chrono::steady_clock::now();
            track(download, seed, stop, su, sv, sw, sh, fast, minConf, state);
            myAnalyzeMs = std::chrono::duration<float, std::milli>(
                              std::chrono::steady_clock::now() - t0).count();
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                myTrack = state;
                myBusy = false;
            }
        }
    }

    void track(OP_SmartRef<OP_TOPDownloadResult>& download, bool seed, bool stop,
               float su, float sv, float sw, float sh, bool fast, float minConf,
               TrackState& out)
    {
        if (stop) {
            myLastObs = nil;
            mySeqHandler = nil;
        }
        if (!download)
            return;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || w == 0 || h == 0)
            return;

        @autoreleasepool {
            if (seed) {
                // 中心+サイズ → Vision の bbox(左下原点+サイズ)。シーケンスも仕切り直す
                const CGRect rect = CGRectMake(su - sw * 0.5, sv - sh * 0.5, sw, sh);
                myLastObs = [VNDetectedObjectObservation observationWithBoundingBox:rect];
                mySeqHandler = [[VNSequenceRequestHandler alloc] init];
                mySeedCount++;
            }
            if (!myLastObs || !mySeqHandler)
                return;

            CVPixelBufferRef cur = nullptr;
            CVPixelBufferCreateWithBytes(nullptr, w, h, kCVPixelFormatType_32BGRA,
                                         data, w * 4, nullptr, nullptr, nullptr, &cur);
            if (!cur)
                return;

            VNTrackObjectRequest* request =
                [[VNTrackObjectRequest alloc] initWithDetectedObjectObservation:myLastObs];
            request.trackingLevel = fast ? VNRequestTrackingLevelFast
                                         : VNRequestTrackingLevelAccurate;
            // Revision2 は "unexpected tracked object bounding box size" で失敗する
            // 環境がある(macOS 26 で実測)。Revision1 を明示する
            request.revision = VNTrackObjectRequestRevision1;

            NSError* err = nil;
            const bool ok = [mySeqHandler performRequests:@[request]
                                          onCVPixelBuffer:cur
                                                    error:&err];
            CVPixelBufferRelease(cur);

            VNDetectedObjectObservation* obs =
                ok ? (VNDetectedObjectObservation*)request.results.firstObject : nil;
            if (obs && obs.confidence >= minConf) {
                myLastObs = obs;   // 次フレームは今回の結果から追跡を続ける
                const CGRect r = obs.boundingBox;
                out.valid = true;
                out.u = (float)(r.origin.x + r.size.width * 0.5);
                out.v = (float)(r.origin.y + r.size.height * 0.5);
                out.w = (float)r.size.width;
                out.h = (float)r.size.height;
                out.confidence = (float)obs.confidence;
                std::lock_guard<std::mutex> lock(myMutex);
                myLastError.clear();
            } else {
                // 見失った(またはエラー)。再シードまで invalid
                out.valid = false;
                if (!ok || !obs) {
                    myLastObs = nil;
                    mySeqHandler = nil;
                    myLossCount++;
                    std::string msg = "tracking lost";
                    if (err)
                        msg += std::string(": ") + err.localizedDescription.UTF8String;
                    std::lock_guard<std::mutex> lock(myMutex);
                    myLastError = msg;
                }
            }
        }
    }

    // ---------------------------------------------------------- state

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;
    bool myHasPending = false;
    bool myBusy = false;
    bool mySeedRequested = false;
    bool myStopRequested = false;
    OP_SmartRef<OP_TOPDownloadResult> myPending;
    TrackState myTrack;
    int64_t myLastCookSeen = -1;

    // ワーカー専用(追跡シーケンス状態)
    VNDetectedObjectObservation* myLastObs = nil;
    VNSequenceRequestHandler* mySeqHandler = nil;

    std::atomic<bool> myFlip{true}, myFast{false};
    std::atomic<float> myMinConf{0.3f};
    std::atomic<float> mySeedU{0.5f}, mySeedV{0.5f}, mySeedW{0.2f}, mySeedH{0.2f};

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
    std::atomic<int> mySeedCount{0}, myLossCount{0};
    std::atomic<float> myAnalyzeMs{0.0f};
    std::string myLastError;   // myMutex 保護
};

}   // namespace

// ------------------------------------------------------------------ entry points

extern "C" {

DLLEXPORT void
FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Visiontrack");
    info->customOPInfo.opLabel->setString("Vision Track");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.opIcon->setString("VTR");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT CHOP_CPlusPlusBase*
CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new VisionTrackCHOP(info);
}

DLLEXPORT void
DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (VisionTrackCHOP*)instance;
}

}   // extern "C"
