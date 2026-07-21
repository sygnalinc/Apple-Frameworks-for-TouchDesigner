// FrameInterp TOP — TouchDesigner カスタムオペレータ(macOS / VideoToolbox VTFrameProcessor)
//
// Apple の動画ML処理(VTFrameProcessor・macOS 15.4+)で
//   Interpolate  前フレームと現フレームの中間フレームを ML 補間で生成
//                (Phase 0〜1 で補間位置を指定。スローモーション/フレームレート変換の要素技術)
//   Motion Blur  前フレームからの動きに基づく ML モーションブラー(Strength 1〜100)
//
// 入出力は 64RGBAHalf(TD の RGBA16Float と同一メモリレイアウト)で変換コストなし。
//
// 実装: 処理はワーカースレッドで非同期(cook 非ブロック・結果は1〜2フレーム遅れ)。
// 解像度・モード変更時にセッションを作り直す。

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
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

class FrameInterpTOP : public TOP_CPlusPlusBase
{
public:
    FrameInterpTOP(const OP_NodeInfo*, TOP_Context* context) : myContext(context)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~FrameInterpTOP() override
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
        myMode = (strcmp(inputs->getParString("Mode"), "motionblur") == 0) ? 1 : 0;
        myPhase = (float)inputs->getParDouble("Phase");
        myStrength = (int)inputs->getParInt("Strength");
        inputs->enablePar("Phase", myMode == 0);
        inputs->enablePar("Strength", myMode == 1);

        const OP_TOPInput* top = inputs->getInputTOP(0);
        if (active && top && top->totalCooks != myLastCookSeen) {
            std::unique_lock<std::mutex> lock(myMutex, std::try_to_lock);
            if (lock.owns_lock() && !myHasPending && !myBusy) {
                OP_TOPInputDownloadOptions opts;
                // 補間/ブラーは向きに依存しないので flip せずそのまま渡し、そのまま返す
                // (Vision系と違い出力側の再反転が無いため、flip すると上下逆になる)
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
            p.page = "Frame Interp";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Mode");
            p.label = "Mode";
            p.page = "Frame Interp";
            p.defaultValue = "interpolate";
            const char* names[] = {"interpolate", "motionblur"};
            const char* labels[] = {"Interpolate", "Motion Blur"};
            manager->appendMenu(p, 2, names, labels);
        }
        {
            OP_NumericParameter p("Phase");
            p.label = "Interpolation Phase";
            p.page = "Frame Interp";
            p.defaultValues[0] = 0.5;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 1.0;
            p.minValues[0] = 0.0;
            p.maxValues[0] = 1.0;
            p.clampMins[0] = true;
            p.clampMaxes[0] = true;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Strength");
            p.label = "Blur Strength";
            p.page = "Frame Interp";
            p.defaultValues[0] = 50;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 100;
            p.minValues[0] = 1;
            p.maxValues[0] = 100;
            p.clampMins[0] = true;
            p.clampMaxes[0] = true;
            manager->appendInt(p);
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
            int mode, strength;
            float phase;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    break;
                download = std::move(myPending);
                myHasPending = false;
                myBusy = true;
                mode = myMode;
                phase = myPhase;
                strength = myStrength;
            }
            FrameResult result;
            std::string error;
            const auto t0 = std::chrono::steady_clock::now();
            if (@available(macOS 15.4, *))
                process(download, mode, phase, strength, result, error);
            else
                error = "FrameInterp requires macOS 15.4+";
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
        if (@available(macOS 15.4, *))
            teardownSession();
    }

    API_AVAILABLE(macos(15.4))
    void teardownSession()
    {
        if (myProcessor)
            [myProcessor endSession];
        myProcessor = nil;
        myPrevPB = nil;
        mySrcPool = nil;
        myDstPool = nil;
    }

    API_AVAILABLE(macos(15.4))
    bool ensureSession(uint32_t w, uint32_t h, int mode, std::string& error)
    {
        if (myProcessor && mySessW == w && mySessH == h && mySessMode == mode)
            return true;
        teardownSession();

        id<VTFrameProcessorConfiguration> config = nil;
        if (mode == 0) {
            if (!VTFrameRateConversionConfiguration.isSupported) {
                error = "Frame rate conversion not supported on this hardware";
                return false;
            }
            config = [[VTFrameRateConversionConfiguration alloc]
                initWithFrameWidth:w frameHeight:h usePrecomputedFlow:NO
                qualityPrioritization:VTFrameRateConversionConfigurationQualityPrioritizationNormal
                revision:VTFrameRateConversionConfigurationRevision1];
        } else {
            if (!VTMotionBlurConfiguration.isSupported) {
                error = "Motion blur not supported on this hardware";
                return false;
            }
            config = [[VTMotionBlurConfiguration alloc]
                initWithFrameWidth:w frameHeight:h usePrecomputedFlow:NO
                qualityPrioritization:VTMotionBlurConfigurationQualityPrioritizationNormal
                revision:VTMotionBlurConfigurationRevision1];
        }
        if (!config) {
            error = "VTFrameProcessor configuration failed (resolution unsupported?)";
            return false;
        }

        NSDictionary* srcAttrs = config.sourcePixelBufferAttributes;
        NSDictionary* dstAttrs = config.destinationPixelBufferAttributes;
        CVPixelBufferPoolCreate(nullptr, nullptr, (__bridge CFDictionaryRef)srcAttrs,
                                &mySrcPoolRef);
        CVPixelBufferPoolCreate(nullptr, nullptr, (__bridge CFDictionaryRef)dstAttrs,
                                &myDstPoolRef);
        mySrcPool = (__bridge_transfer id)mySrcPoolRef;
        myDstPool = (__bridge_transfer id)myDstPoolRef;

        VTFrameProcessor* proc = [[VTFrameProcessor alloc] init];
        NSError* err = nil;
        if (![proc startSessionWithConfiguration:config error:&err]) {
            error = "startSession failed: " +
                    std::string(err ? err.localizedDescription.UTF8String : "unknown");
            return false;
        }
        myProcessor = proc;
        mySessW = w;
        mySessH = h;
        mySessMode = mode;
        myFrameIndex = 0;
        myPrevPB = nil;
        return true;
    }

    API_AVAILABLE(macos(15.4))
    CVPixelBufferRef poolBuffer(bool dst)
    {
        CVPixelBufferRef pb = nullptr;
        CVPixelBufferPoolRef pool =
            (__bridge CVPixelBufferPoolRef)(dst ? myDstPool : mySrcPool);
        if (pool)
            CVPixelBufferPoolCreatePixelBuffer(nullptr, pool, &pb);
        return pb;
    }

    API_AVAILABLE(macos(15.4))
    void process(OP_SmartRef<OP_TOPDownloadResult>& download, int mode, float phase,
                 int strength, FrameResult& out, std::string& error)
    {
        if (!download)
            return;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || w == 0 || h == 0)
            return;

        @autoreleasepool {
            if (!ensureSession(w, h, mode, error))
                return;

            // ダウンロードした RGBA16F を 64RGBAHalf のプールバッファへコピー
            CVPixelBufferRef curPB = poolBuffer(false);
            if (!curPB) {
                error = "pixel buffer allocation failed";
                return;
            }
            CVPixelBufferLockBaseAddress(curPB, 0);
            {
                const size_t stride = CVPixelBufferGetBytesPerRow(curPB);
                uint8_t* base = (uint8_t*)CVPixelBufferGetBaseAddress(curPB);
                const uint8_t* src = (const uint8_t*)data;
                const size_t rowBytes = (size_t)w * 8;
                for (uint32_t y = 0; y < h; y++)
                    memcpy(base + (size_t)y * stride, src + (size_t)y * rowBytes, rowBytes);
            }
            CVPixelBufferUnlockBaseAddress(curPB, 0);
            id curPBObj = (__bridge_transfer id)curPB;   // ARC 管理に載せる

            const int64_t n = ++myFrameIndex;
            if (myPrevPB) {
                CVPixelBufferRef dstPB = poolBuffer(true);
                if (!dstPB) {
                    error = "pixel buffer allocation failed";
                    return;
                }
                id dstPBObj = (__bridge_transfer id)dstPB;

                VTFrameProcessorFrame* prevF = [[VTFrameProcessorFrame alloc]
                    initWithBuffer:(__bridge CVPixelBufferRef)myPrevPB
                    presentationTimeStamp:CMTimeMake((n - 1) * 1000, 60000)];
                VTFrameProcessorFrame* curF = [[VTFrameProcessorFrame alloc]
                    initWithBuffer:(__bridge CVPixelBufferRef)curPBObj
                    presentationTimeStamp:CMTimeMake(n * 1000, 60000)];

                NSError* err = nil;
                bool ok = false;
                if (mode == 0) {
                    VTFrameProcessorFrame* dstF = [[VTFrameProcessorFrame alloc]
                        initWithBuffer:(__bridge CVPixelBufferRef)dstPBObj
                        presentationTimeStamp:CMTimeMake((n - 1) * 1000 +
                                                         (int64_t)(phase * 1000.0f), 60000)];
                    VTFrameRateConversionParameters* params =
                        [[VTFrameRateConversionParameters alloc]
                            initWithSourceFrame:prevF
                                      nextFrame:curF
                                    opticalFlow:nil
                             interpolationPhase:@[@(phase)]
                                 submissionMode:VTFrameRateConversionParametersSubmissionModeSequential
                              destinationFrames:@[dstF]];
                    ok = params && [myProcessor processWithParameters:params error:&err];
                } else {
                    VTFrameProcessorFrame* dstF = [[VTFrameProcessorFrame alloc]
                        initWithBuffer:(__bridge CVPixelBufferRef)dstPBObj
                        presentationTimeStamp:CMTimeMake(n * 1000, 60000)];
                    VTMotionBlurParameters* params = [[VTMotionBlurParameters alloc]
                        initWithSourceFrame:curF
                                  nextFrame:nil
                              previousFrame:prevF
                            nextOpticalFlow:nil
                        previousOpticalFlow:nil
                         motionBlurStrength:strength
                             submissionMode:VTMotionBlurParametersSubmissionModeSequential
                           destinationFrame:dstF];
                    ok = params && [myProcessor processWithParameters:params error:&err];
                }

                if (ok) {
                    copyHalfRGBA((__bridge CVPixelBufferRef)dstPBObj, out);
                    error.clear();
                } else {
                    error = "process failed: " +
                            std::string(err ? err.localizedDescription.UTF8String : "unknown");
                }
            }
            myPrevPB = curPBObj;
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
    VTFrameProcessor* myProcessor = nil;
    id mySrcPool = nil;
    id myDstPool = nil;
    CVPixelBufferPoolRef mySrcPoolRef = nullptr;
    CVPixelBufferPoolRef myDstPoolRef = nullptr;
    id myPrevPB = nil;
    uint32_t mySessW = 0, mySessH = 0;
    int mySessMode = -1;
    int64_t myFrameIndex = 0;

    std::atomic<int> myMode{0}, myStrength{50};
    std::atomic<float> myPhase{0.5f};

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
    info->customOPInfo.opType->setString("Metalframeinterp");
    info->customOPInfo.opLabel->setString("Metal Frame Interp");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.opIcon->setString("MFI");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/MetalFrameInterp/README.md");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT TOP_CPlusPlusBase*
CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new FrameInterpTOP(info, context);
}

DLLEXPORT void
DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (FrameInterpTOP*)instance;
}

}   // extern "C"
