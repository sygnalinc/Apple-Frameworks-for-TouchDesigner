// VisionAesthetics CHOP — TouchDesigner カスタムオペレータ(macOS / Apple Vision)
//
// 画像の「写真としての良さ」を推定する(VNCalculateImageAestheticsScoresRequest・macOS 15+)。
// 複数カメラ/候補カットからの自動ベストショット選択、スクリーンショット等の
// 「実用画像」(utility)判定に使える。
//
// 出力チャンネル: valid / score(-1〜+1・高いほど良い)/ utility(実用画像=1)
//
// 実装: 解析はワーカースレッドで非同期(cook 非ブロック・結果は1〜2フレーム遅れ)。

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>

#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

class VisionAestheticsCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit VisionAestheticsCHOP(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionAestheticsCHOP() override
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
        info->numChannels = 3;
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t index, OP_String* name, const OP_Inputs*, void*) override
    {
        const char* names[3] = {"valid", "score", "utility"};
        name->setString(names[index]);
    }

    void execute(CHOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        const bool flip = inputs->getParInt("Flip") != 0;

        const OP_TOPInput* top = inputs->getParTOP("Top");
        if (active && top && top->totalCooks != myLastCookSeen) {
            std::unique_lock<std::mutex> lock(myMutex, std::try_to_lock);
            if (lock.owns_lock() && !myHasPending && !myBusy) {
                OP_TOPInputDownloadOptions opts;
                opts.pixelFormat = OP_PixelFormat::BGRA8Fixed;
                opts.verticalFlip = flip;
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

        output->channels[0][0] = (active && myValid) ? 1.0f : 0.0f;
        output->channels[1][0] = active ? myScore.load() : 0.0f;
        output->channels[2][0] = (active && myUtility) ? 1.0f : 0.0f;
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Top");
            p.label = "TOP";
            p.page = "Vision Aesthetics";
            manager->appendTOP(p);
        }
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Vision Aesthetics";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "Vision Aesthetics";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[4] = {"executes", "submits", "analyzes", "analyze_ms"};
        float values[4] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           myAnalyzeMs.load()};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        if (@available(macOS 15.0, *))
            return;
        warning->setString("VisionAesthetics requires macOS 15+");
    }

private:
    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                download = std::move(myPending);
                myHasPending = false;
                myBusy = true;
            }
            const auto t0 = std::chrono::steady_clock::now();
            analyze(download);
            myAnalyzeMs = std::chrono::duration<float, std::milli>(
                              std::chrono::steady_clock::now() - t0).count();
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                myBusy = false;
            }
        }
    }

    void analyze(OP_SmartRef<OP_TOPDownloadResult>& download)
    {
        if (!download)
            return;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || w == 0 || h == 0)
            return;

        if (@available(macOS 15.0, *)) {
            @autoreleasepool {
                CVPixelBufferRef input = nullptr;
                CVPixelBufferCreateWithBytes(nullptr, w, h, kCVPixelFormatType_32BGRA,
                                             data, (size_t)w * 4, nullptr, nullptr, nullptr,
                                             &input);
                if (!input)
                    return;
                VNCalculateImageAestheticsScoresRequest* request =
                    [[VNCalculateImageAestheticsScoresRequest alloc] init];
                VNImageRequestHandler* handler =
                    [[VNImageRequestHandler alloc] initWithCVPixelBuffer:input options:@{}];
                if ([handler performRequests:@[request] error:nil]) {
                    VNImageAestheticsScoresObservation* obs = request.results.firstObject;
                    if (obs) {
                        myScore = obs.overallScore;
                        myUtility = obs.isUtility;
                        myValid = true;
                    }
                }
                CVPixelBufferRelease(input);
            }
        }
    }

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;
    bool myHasPending = false;
    bool myBusy = false;
    OP_SmartRef<OP_TOPDownloadResult> myPending;
    int64_t myLastCookSeen = -1;

    std::atomic<bool> myValid{false}, myUtility{false};
    std::atomic<float> myScore{0.0f};
    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
    std::atomic<float> myAnalyzeMs{0.0f};
};

}   // namespace

extern "C" {

DLLEXPORT void
FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Visionaesthetics");
    info->customOPInfo.opLabel->setString("Vision Aesthetics");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("VAE");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/VisionAesthetics/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT CHOP_CPlusPlusBase*
CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new VisionAestheticsCHOP(info);
}

DLLEXPORT void
DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (VisionAestheticsCHOP*)instance;
}

}   // extern "C"
