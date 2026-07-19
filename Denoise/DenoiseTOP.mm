// Denoise TOP — TouchDesigner カスタムオペレータ(macOS / VideoToolbox VTFrameProcessor)
//
// Apple の ML テンポラルノイズフィルタ(VTTemporalNoiseFilter・macOS 26+)で
// 映像の時間方向ノイズを除去する。暗所カメラのざらつき低減など。
//
// **注意: 対応ハードウェアが限られる**。M2 実測では isSupported=false
// (maximumDimensions=0x0)で動作しない。対応環境ではエラー表示なしで動く想定。
// 入出力は 64RGBAHalf(TD の RGBA16Float と同一レイアウト)。
//
// 実装: 処理はワーカースレッドで非同期(cook 非ブロック)。前フレーム列を
// config.previousFrameCount 分保持して渡す。向きに依存しない処理なので Flip は持たない。

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

struct FrameResult
{
    std::vector<uint8_t> data;   // RGBA16F
    uint32_t width = 0;
    uint32_t height = 0;
    uint64_t serial = 0;
};

class DenoiseTOP : public TOP_CPlusPlusBase
{
public:
    DenoiseTOP(const OP_NodeInfo*, TOP_Context* context) : myContext(context)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~DenoiseTOP() override
    {
        {
            std::lock_guard<std::mutex> lock(myMutex);
            myQuit = true;
        }
        myCond.notify_all();
        if (myWorker.joinable())
            myWorker.join();
    }

    void getGeneralInfo(TOP_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
    }

    void execute(TOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        myStrength = (float)inputs->getParDouble("Strength");

        const OP_TOPInput* top = inputs->getInputTOP(0);
        if (active && top && top->totalCooks != myLastCookSeen) {
            std::unique_lock<std::mutex> lock(myMutex, std::try_to_lock);
            if (lock.owns_lock() && !myHasPending && !myBusy) {
                OP_TOPInputDownloadOptions opts;
                // ノイズ除去は向きに依存しないので flip せずそのまま渡し、そのまま返す
                opts.pixelFormat = OP_PixelFormat::RGBA16Float;
                opts.verticalFlip = false;
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

        FrameResult frame;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            if (myResult.serial == myUploadedSerial || myResult.data.empty())
                return;
            frame = myResult;
            myUploadedSerial = myResult.serial;
        }

        TOP_UploadInfo info;
        info.textureDesc.texDim = OP_TexDim::e2D;
        info.textureDesc.width = frame.width;
        info.textureDesc.height = frame.height;
        info.textureDesc.pixelFormat = OP_PixelFormat::RGBA16Float;
        OP_SmartRef<TOP_Buffer> buf =
            myContext->createOutputBuffer(frame.data.size(), TOP_BufferFlags::None, nullptr);
        if (!buf)
            return;
        memcpy(buf->data, frame.data.data(), frame.data.size());
        output->uploadBuffer(&buf, info, nullptr);
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Denoise";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Strength");
            p.label = "Filter Strength";
            p.page = "Denoise";
            p.defaultValues[0] = 0.5;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 1.0;
            p.minValues[0] = 0.0;
            p.maxValues[0] = 1.0;
            p.clampMins[0] = true;
            p.clampMaxes[0] = true;
            manager->appendFloat(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[4] = {"executes", "submits", "analyzes", "process_ms"};
        float values[4] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           myProcessMs.load()};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getErrorString(OP_String* error, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (!myError.empty())
            error->setString(myError.c_str());
    }

private:
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            float strength;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    break;
                download = std::move(myPending);
                myHasPending = false;
                myBusy = true;
                strength = myStrength;
            }
            FrameResult result;
            std::string error;
            const auto t0 = std::chrono::steady_clock::now();
            if (@available(macOS 26.0, *))
                process(download, strength, result, error);
            else
                error = "Denoise requires macOS 26+";
            myProcessMs = std::chrono::duration<float, std::milli>(
                              std::chrono::steady_clock::now() - t0).count();
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                if (!result.data.empty()) {
                    result.serial = ++mySerial;
                    myResult = std::move(result);
                }
                myError = error;
                myBusy = false;
            }
        }
        if (@available(macOS 26.0, *))
            teardownSession();
    }

    API_AVAILABLE(macos(26.0))
    void teardownSession()
    {
        if (myProcessor)
            [myProcessor endSession];
        myProcessor = nil;
        myConfig = nil;
        mySrcPool = nil;
        myDstPool = nil;
        myPrevFrames.clear();
    }

    API_AVAILABLE(macos(26.0))
    bool ensureSession(uint32_t w, uint32_t h, std::string& error)
    {
        if (myProcessor && mySessW == w && mySessH == h)
            return true;
        teardownSession();

        if (!VTTemporalNoiseFilterConfiguration.isSupported) {
            error = "Temporal noise filter not supported on this hardware";
            return false;
        }
        // 64RGBAHalf を要求(TD の RGBA16Float と直結)。対応外なら諦める
        const OSType wantFmt = kCVPixelFormatType_64RGBAHalf;
        bool haveFmt = false;
        for (NSNumber* f in VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats)
            if (f.unsignedIntValue == wantFmt)
                haveFmt = true;
        if (!haveFmt) {
            error = "64RGBAHalf not supported by noise filter on this hardware";
            return false;
        }

        myConfig = [[VTTemporalNoiseFilterConfiguration alloc]
            initWithFrameWidth:w frameHeight:h sourcePixelFormat:wantFmt];
        if (!myConfig) {
            error = "Noise filter configuration failed (resolution unsupported?)";
            return false;
        }

        CVPixelBufferPoolRef sp = nullptr, dp = nullptr;
        CVPixelBufferPoolCreate(nullptr, nullptr,
            (__bridge CFDictionaryRef)myConfig.sourcePixelBufferAttributes, &sp);
        CVPixelBufferPoolCreate(nullptr, nullptr,
            (__bridge CFDictionaryRef)myConfig.destinationPixelBufferAttributes, &dp);
        mySrcPool = (__bridge_transfer id)sp;
        myDstPool = (__bridge_transfer id)dp;

        VTFrameProcessor* proc = [[VTFrameProcessor alloc] init];
        NSError* err = nil;
        if (![proc startSessionWithConfiguration:myConfig error:&err]) {
            error = "startSession failed: " +
                    std::string(err ? err.localizedDescription.UTF8String : "unknown");
            return false;
        }
        myProcessor = proc;
        mySessW = w;
        mySessH = h;
        myFrameIndex = 0;
        return true;
    }

    API_AVAILABLE(macos(26.0))
    void process(OP_SmartRef<OP_TOPDownloadResult>& download, float strength,
                 FrameResult& out, std::string& error)
    {
        if (!download)
            return;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || w == 0 || h == 0)
            return;

        @autoreleasepool {
            if (!ensureSession(w, h, error))
                return;

            CVPixelBufferRef curPB = nullptr;
            CVPixelBufferPoolCreatePixelBuffer(
                nullptr, (__bridge CVPixelBufferPoolRef)mySrcPool, &curPB);
            CVPixelBufferRef dstPB = nullptr;
            CVPixelBufferPoolCreatePixelBuffer(
                nullptr, (__bridge CVPixelBufferPoolRef)myDstPool, &dstPB);
            if (!curPB || !dstPB) {
                if (curPB) CVPixelBufferRelease(curPB);
                if (dstPB) CVPixelBufferRelease(dstPB);
                error = "pixel buffer allocation failed";
                return;
            }
            id curObj = (__bridge_transfer id)curPB;
            id dstObj = (__bridge_transfer id)dstPB;

            CVPixelBufferLockBaseAddress(curPB, 0);
            {
                const size_t stride = CVPixelBufferGetBytesPerRow(curPB);
                uint8_t* base = (uint8_t*)CVPixelBufferGetBaseAddress(curPB);
                const size_t rowBytes = (size_t)w * 8;
                for (uint32_t y = 0; y < h; y++)
                    memcpy(base + (size_t)y * stride,
                           (const uint8_t*)data + (size_t)y * rowBytes, rowBytes);
            }
            CVPixelBufferUnlockBaseAddress(curPB, 0);

            const int64_t n = ++myFrameIndex;
            VTFrameProcessorFrame* curF = [[VTFrameProcessorFrame alloc]
                initWithBuffer:curPB presentationTimeStamp:CMTimeMake(n, 60)];
            VTFrameProcessorFrame* dstF = [[VTFrameProcessorFrame alloc]
                initWithBuffer:dstPB presentationTimeStamp:CMTimeMake(n, 60)];

            // 直近の前フレーム列(config が要求する数まで)
            NSMutableArray<VTFrameProcessorFrame*>* prev = [NSMutableArray array];
            int64_t backIdx = n - 1;
            for (auto it = myPrevFrames.rbegin();
                 it != myPrevFrames.rend() &&
                 (NSInteger)prev.count < myConfig.previousFrameCount; ++it) {
                [prev insertObject:[[VTFrameProcessorFrame alloc]
                                       initWithBuffer:(__bridge CVPixelBufferRef)*it
                                       presentationTimeStamp:CMTimeMake(backIdx--, 60)]
                           atIndex:0];
            }

            VTTemporalNoiseFilterParameters* params =
                [[VTTemporalNoiseFilterParameters alloc]
                    initWithSourceFrame:curF
                             nextFrames:@[]
                         previousFrames:prev
                       destinationFrame:dstF
                         filterStrength:strength
                       hasDiscontinuity:(myPrevFrames.empty() ? true : false)];
            NSError* err = nil;
            if (!params || ![myProcessor processWithParameters:params error:&err]) {
                error = "process failed: " +
                        std::string(err ? err.localizedDescription.UTF8String : "unknown");
                return;
            }

            copyHalfRGBA(dstPB, out);

            myPrevFrames.push_back(curObj);
            while ((NSInteger)myPrevFrames.size() >
                   std::max<NSInteger>(1, myConfig.previousFrameCount))
                myPrevFrames.pop_front();
        }
    }

    static void copyHalfRGBA(CVPixelBufferRef pb, FrameResult& out)
    {
        CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        const uint32_t w = (uint32_t)CVPixelBufferGetWidth(pb);
        const uint32_t h = (uint32_t)CVPixelBufferGetHeight(pb);
        const size_t stride = CVPixelBufferGetBytesPerRow(pb);
        const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(pb);
        if (base && w && h) {
            out.width = w;
            out.height = h;
            const size_t rowBytes = (size_t)w * 8;
            out.data.resize(rowBytes * h);
            for (uint32_t y = 0; y < h; y++)
                memcpy(out.data.data() + (size_t)y * rowBytes, base + (size_t)y * stride,
                       rowBytes);
        }
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    }

    // ---------------------------------------------------------- state

    TOP_Context* myContext;
    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;
    bool myHasPending = false;
    bool myBusy = false;
    OP_SmartRef<OP_TOPDownloadResult> myPending;
    FrameResult myResult;
    std::string myError;
    uint64_t mySerial = 0;
    uint64_t myUploadedSerial = 0;
    int64_t myLastCookSeen = -1;

    // ワーカー専用(セッション状態)
    VTTemporalNoiseFilterConfiguration* myConfig API_AVAILABLE(macos(26.0)) = nil;
    VTFrameProcessor* myProcessor API_AVAILABLE(macos(15.4)) = nil;
    id mySrcPool = nil, myDstPool = nil;
    std::deque<id> myPrevFrames;
    uint32_t mySessW = 0, mySessH = 0;
    int64_t myFrameIndex = 0;

    std::atomic<float> myStrength{0.5f};
    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
    std::atomic<float> myProcessMs{0.0f};
};

}   // namespace

// ------------------------------------------------------------------ entry points

extern "C" {

DLLEXPORT void
FillTOPPluginInfo(TOP_PluginInfo* info)
{
    if (!info->setAPIVersion(TOPCPlusPlusAPIVersion))
        return;
    info->executeMode = TOP_ExecuteMode::CPUMem;
    info->customOPInfo.opType->setString("Metaldenoise");
    info->customOPInfo.opLabel->setString("Metal Denoise");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("MDN");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT TOP_CPlusPlusBase*
CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new DenoiseTOP(info, context);
}

DLLEXPORT void
DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (DenoiseTOP*)instance;
}

}   // extern "C"
