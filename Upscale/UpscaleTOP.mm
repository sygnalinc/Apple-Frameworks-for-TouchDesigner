// Upscale TOP — TouchDesigner カスタムオペレータ(macOS / MetalFX・VideoToolbox)
//
// リアルタイム超解像。Windows+NVIDIA 専用の Nvidia Upscaler TOP の macOS 代替。
//
// バックエンド:
//   MetalFX    MTLFXSpatialScaler(macOS 13+)。任意倍率(1〜4x)・毎フレーム実行できる
//              ゲーム向けアップスケーラ。速い
//   VT SuperRes VTSuperResolutionScaler(macOS 26+)。ML超解像・倍率は固定
//              (このAPIが返す対応倍率。実測4x)。初回に Download Model パルスで
//              MLモデルのダウンロードが必要。高品質だが重い
//
// 実装: 処理はワーカースレッドで非同期(cook 非ブロック・結果は1〜2フレーム遅れ)。

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
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
    std::vector<uint8_t> data;
    uint32_t width = 0;
    uint32_t height = 0;
    OP_PixelFormat format = OP_PixelFormat::BGRA8Fixed;
    uint64_t serial = 0;
};

class UpscaleTOP : public TOP_CPlusPlusBase
{
public:
    UpscaleTOP(const OP_NodeInfo*, TOP_Context* context) : myContext(context)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~UpscaleTOP() override
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
        myFlip = inputs->getParInt("Flip") != 0;
        myVT = strcmp(inputs->getParString("Backend"), "vtsuper") == 0;
        myScale = (float)inputs->getParDouble("Scale");
        inputs->enablePar("Scale", !myVT);
        inputs->enablePar("Downloadmodel", myVT);

        // 静止画入力でもバックエンド/倍率変更で再処理させる
        const int settings = (myVT ? 1000 : 0) + (int)(myScale * 100.0f);
        if (settings != myLastSettingsSeen) {
            myLastSettingsSeen = settings;
            myLastCookSeen = -1;
        }

        const OP_TOPInput* top = inputs->getInputTOP(0);
        if (active && top && top->totalCooks != myLastCookSeen) {
            std::unique_lock<std::mutex> lock(myMutex, std::try_to_lock);
            if (lock.owns_lock() && !myHasPending && !myBusy) {
                OP_TOPInputDownloadOptions opts;
                // MetalFX は BGRA8、VT SuperRes は RGBA16F(64RGBAHalf)で受ける
                opts.pixelFormat = myVT ? OP_PixelFormat::RGBA16Float
                                        : OP_PixelFormat::BGRA8Fixed;
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
        info.textureDesc.pixelFormat = frame.format;
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
            p.page = "Upscale";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Backend");
            p.label = "Backend";
            p.page = "Upscale";
            p.defaultValue = "metalfx";
            const char* names[] = {"metalfx", "vtsuper"};
            const char* labels[] = {"MetalFX Spatial (Fast)", "VT Super Resolution (ML, 4x)"};
            manager->appendMenu(p, 2, names, labels);
        }
        {
            OP_NumericParameter p("Scale");
            p.label = "Scale Factor";
            p.page = "Upscale";
            p.defaultValues[0] = 2.0;
            p.minSliders[0] = 1.0;
            p.maxSliders[0] = 4.0;
            p.minValues[0] = 1.0;
            p.maxValues[0] = 4.0;
            p.clampMins[0] = true;
            p.clampMaxes[0] = true;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Downloadmodel");
            p.label = "Download Model";
            p.page = "Upscale";
            manager->appendPulse(p);
        }
        {
            // Upscale は幾何変換なので入出力の向きを変えない = flip 不要。
            // ダウンロード時のみ flip し出力側で戻していないため、On にすると出力が上下逆になる。
            // 既定 Off = ソースと同じ正立。逆さ素材を受けたときだけ On にする
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "Upscale";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Downloadmodel") == 0) {
            {
                std::lock_guard<std::mutex> lock(myMutex);
                myDownloadRequested = true;
            }
            myLastCookSeen = -1;   // 静止画入力でもワーカーへジョブを流す
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[5] = {"executes", "submits", "analyzes", "process_ms",
                                "model_status"};
        float values[5] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           myProcessMs.load(), (float)myModelStatus.load()};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getErrorString(OP_String* error, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (!myError.empty())
            error->setString(myError.c_str());
    }

    void getWarningString(OP_String* warning, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (!myWarning.empty())
            warning->setString(myWarning.c_str());
    }

private:
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            bool vt, wantDownload;
            float scale;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    break;
                download = std::move(myPending);
                myHasPending = false;
                myBusy = true;
                vt = myVT;
                scale = myScale;
                wantDownload = myDownloadRequested;
                myDownloadRequested = false;
            }
            FrameResult result;
            std::string error, warning;
            const auto t0 = std::chrono::steady_clock::now();
            if (vt) {
                if (@available(macOS 26.0, *))
                    processVT(download, wantDownload, result, error, warning);
                else
                    error = "VT Super Resolution requires macOS 26+";
            } else {
                processMetalFX(download, scale, result, error);
            }
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
                myWarning = warning;
                myBusy = false;
            }
        }
        if (@available(macOS 26.0, *))
            teardownVT();
    }

    // ---------------------------------------------------------- MetalFX backend

    void processMetalFX(OP_SmartRef<OP_TOPDownloadResult>& download, float scale,
                        FrameResult& out, std::string& error)
    {
        if (!download)
            return;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || w == 0 || h == 0)
            return;
        const uint32_t ow = (uint32_t)((float)w * scale + 0.5f);
        const uint32_t oh = (uint32_t)((float)h * scale + 0.5f);
        if (ow == 0 || oh == 0)
            return;

        @autoreleasepool {
            if (!myDevice) {
                myDevice = MTLCreateSystemDefaultDevice();
                myQueue = [myDevice newCommandQueue];
            }
            if (!myDevice) {
                error = "Metal device unavailable";
                return;
            }

            // 解像度が変わったらスケーラとテクスチャを作り直す
            if (!myScaler || myMfxW != w || myMfxH != h || myMfxOW != ow || myMfxOH != oh) {
                MTLFXSpatialScalerDescriptor* desc = [[MTLFXSpatialScalerDescriptor alloc] init];
                desc.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
                desc.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
                desc.inputWidth = w;
                desc.inputHeight = h;
                desc.outputWidth = ow;
                desc.outputHeight = oh;
                desc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
                myScaler = [desc newSpatialScalerWithDevice:myDevice];
                if (!myScaler) {
                    error = "MTLFXSpatialScaler creation failed";
                    return;
                }

                MTLTextureDescriptor* tin = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                 width:w height:h mipmapped:NO];
                tin.usage = MTLTextureUsageShaderRead | myScaler.colorTextureUsage;
                tin.storageMode = MTLStorageModeShared;
                myInTex = [myDevice newTextureWithDescriptor:tin];

                MTLTextureDescriptor* tout = [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                 width:ow height:oh mipmapped:NO];
                tout.usage = myScaler.outputTextureUsage | MTLTextureUsageShaderRead;
                tout.storageMode = MTLStorageModeShared;
                myOutTex = [myDevice newTextureWithDescriptor:tout];

                myMfxW = w; myMfxH = h; myMfxOW = ow; myMfxOH = oh;
            }
            if (!myInTex || !myOutTex) {
                error = "Metal texture allocation failed";
                return;
            }

            [myInTex replaceRegion:MTLRegionMake2D(0, 0, w, h)
                       mipmapLevel:0
                         withBytes:data
                       bytesPerRow:(NSUInteger)w * 4];

            myScaler.colorTexture = myInTex;
            myScaler.outputTexture = myOutTex;
            myScaler.inputContentWidth = w;
            myScaler.inputContentHeight = h;

            id<MTLCommandBuffer> cb = [myQueue commandBuffer];
            [myScaler encodeToCommandBuffer:cb];
            [cb commit];
            [cb waitUntilCompleted];
            if (cb.status == MTLCommandBufferStatusError) {
                error = "MetalFX encode failed";
                return;
            }

            out.width = ow;
            out.height = oh;
            out.format = OP_PixelFormat::BGRA8Fixed;
            out.data.resize((size_t)ow * oh * 4);
            [myOutTex getBytes:out.data.data()
                   bytesPerRow:(NSUInteger)ow * 4
                    fromRegion:MTLRegionMake2D(0, 0, ow, oh)
                   mipmapLevel:0];
        }
    }

    // ---------------------------------------------------------- VT SuperRes backend

    API_AVAILABLE(macos(26.0))
    void teardownVT()
    {
        if (myVTProcessor)
            [myVTProcessor endSession];
        myVTProcessor = nil;
        myVTConfig = nil;
        myVTSrcPool = nil;
        myVTDstPool = nil;
        myVTPrevIn = nil;
        myVTPrevOut = nil;
    }

    API_AVAILABLE(macos(26.0))
    void processVT(OP_SmartRef<OP_TOPDownloadResult>& download, bool wantDownload,
                   FrameResult& out, std::string& error, std::string& warning)
    {
        if (!download)
            return;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || w == 0 || h == 0)
            return;

        @autoreleasepool {
            if (!VTSuperResolutionScalerConfiguration.isSupported) {
                error = "VT Super Resolution not supported on this hardware";
                return;
            }

            // 設定(解像度が変わったら作り直し)
            if (!myVTConfig || myVTW != w || myVTH != h) {
                teardownVT();
                NSInteger factor = 4;
                NSArray<NSNumber*>* factors =
                    VTSuperResolutionScalerConfiguration.supportedScaleFactors;
                if (factors.count > 0)
                    factor = factors.firstObject.integerValue;
                myVTConfig = [[VTSuperResolutionScalerConfiguration alloc]
                    initWithFrameWidth:w frameHeight:h scaleFactor:factor
                    inputType:VTSuperResolutionScalerConfigurationInputTypeVideo
                    usePrecomputedFlow:NO
                    qualityPrioritization:
                        VTSuperResolutionScalerConfigurationQualityPrioritizationNormal
                    revision:VTSuperResolutionScalerConfigurationRevision1];
                if (!myVTConfig) {
                    error = "VT SuperRes configuration failed (input too large? max 1080p)";
                    return;
                }
                myVTW = w;
                myVTH = h;
                myVTFactor = (uint32_t)factor;
            }

            // MLモデルの取得状態(0=要ダウンロード 1=ダウンロード中 2=準備完了)
            const NSInteger status = myVTConfig.configurationModelStatus;
            myModelStatus = (int)status;
            if (status != VTSuperResolutionScalerConfigurationModelStatusReady) {
                if (wantDownload &&
                    status == VTSuperResolutionScalerConfigurationModelStatusDownloadRequired) {
                    [myVTConfig downloadConfigurationModelWithCompletionHandler:
                        ^(NSError* e) { /* 完了は modelStatus のポーリングで検知 */ }];
                    warning = "Model download started...";
                } else if (status ==
                           VTSuperResolutionScalerConfigurationModelStatusDownloading) {
                    warning = "Model downloading... " +
                              std::to_string(
                                  (int)(myVTConfig.configurationModelPercentageAvailable *
                                        100)) + "%";
                } else {
                    warning = "Pulse 'Download Model' to fetch the ML model";
                }
                return;
            }

            if (!myVTProcessor) {
                CVPixelBufferPoolRef sp = nullptr, dp = nullptr;
                CVPixelBufferPoolCreate(
                    nullptr, nullptr,
                    (__bridge CFDictionaryRef)myVTConfig.sourcePixelBufferAttributes, &sp);
                CVPixelBufferPoolCreate(
                    nullptr, nullptr,
                    (__bridge CFDictionaryRef)myVTConfig.destinationPixelBufferAttributes, &dp);
                myVTSrcPool = (__bridge_transfer id)sp;
                myVTDstPool = (__bridge_transfer id)dp;
                VTFrameProcessor* proc = [[VTFrameProcessor alloc] init];
                NSError* err = nil;
                if (![proc startSessionWithConfiguration:myVTConfig error:&err]) {
                    error = "startSession failed: " +
                            std::string(err ? err.localizedDescription.UTF8String : "unknown");
                    return;
                }
                myVTProcessor = proc;
                myVTFrameIndex = 0;
                myVTPrevIn = nil;
                myVTPrevOut = nil;
            }

            // 入力(RGBA16F)をプールバッファへ
            CVPixelBufferRef curPB = nullptr;
            CVPixelBufferPoolCreatePixelBuffer(
                nullptr, (__bridge CVPixelBufferPoolRef)myVTSrcPool, &curPB);
            CVPixelBufferRef dstPB = nullptr;
            CVPixelBufferPoolCreatePixelBuffer(
                nullptr, (__bridge CVPixelBufferPoolRef)myVTDstPool, &dstPB);
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

            const int64_t n = ++myVTFrameIndex;
            VTFrameProcessorFrame* curF = [[VTFrameProcessorFrame alloc]
                initWithBuffer:curPB presentationTimeStamp:CMTimeMake(n, 60)];
            VTFrameProcessorFrame* dstF = [[VTFrameProcessorFrame alloc]
                initWithBuffer:dstPB presentationTimeStamp:CMTimeMake(n, 60)];
            VTFrameProcessorFrame* prevInF =
                myVTPrevIn ? [[VTFrameProcessorFrame alloc]
                                 initWithBuffer:(__bridge CVPixelBufferRef)myVTPrevIn
                                 presentationTimeStamp:CMTimeMake(n - 1, 60)]
                           : nil;
            VTFrameProcessorFrame* prevOutF =
                myVTPrevOut ? [[VTFrameProcessorFrame alloc]
                                  initWithBuffer:(__bridge CVPixelBufferRef)myVTPrevOut
                                  presentationTimeStamp:CMTimeMake(n - 1, 60)]
                            : nil;

            VTSuperResolutionScalerParameters* params =
                [[VTSuperResolutionScalerParameters alloc]
                    initWithSourceFrame:curF
                          previousFrame:prevInF
                    previousOutputFrame:prevOutF
                            opticalFlow:nil
                         submissionMode:VTSuperResolutionScalerParametersSubmissionModeSequential
                       destinationFrame:dstF];
            NSError* err = nil;
            if (!params || ![myVTProcessor processWithParameters:params error:&err]) {
                error = "process failed: " +
                        std::string(err ? err.localizedDescription.UTF8String : "unknown");
                return;
            }

            copyHalfRGBA(dstPB, out);
            myVTPrevIn = curObj;
            myVTPrevOut = dstObj;
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
            out.format = OP_PixelFormat::RGBA16Float;
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
    bool myDownloadRequested = false;
    OP_SmartRef<OP_TOPDownloadResult> myPending;
    FrameResult myResult;
    std::string myError, myWarning;
    uint64_t mySerial = 0;
    uint64_t myUploadedSerial = 0;
    int64_t myLastCookSeen = -1;
    int myLastSettingsSeen = -1;

    // ワーカー専用(MetalFX)
    id<MTLDevice> myDevice = nil;
    id<MTLCommandQueue> myQueue = nil;
    id<MTLFXSpatialScaler> myScaler = nil;
    id<MTLTexture> myInTex = nil, myOutTex = nil;
    uint32_t myMfxW = 0, myMfxH = 0, myMfxOW = 0, myMfxOH = 0;

    // ワーカー専用(VT SuperRes)
    VTSuperResolutionScalerConfiguration* myVTConfig API_AVAILABLE(macos(26.0)) = nil;
    VTFrameProcessor* myVTProcessor API_AVAILABLE(macos(15.4)) = nil;
    id myVTSrcPool = nil, myVTDstPool = nil;
    id myVTPrevIn = nil, myVTPrevOut = nil;
    uint32_t myVTW = 0, myVTH = 0, myVTFactor = 4;
    int64_t myVTFrameIndex = 0;

    std::atomic<bool> myFlip{true}, myVT{false};
    std::atomic<float> myScale{2.0f};
    std::atomic<int> myModelStatus{-1};

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
    info->customOPInfo.opType->setString("Upscale");
    info->customOPInfo.opLabel->setString("Upscale");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("UPS");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT TOP_CPlusPlusBase*
CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new UpscaleTOP(info, context);
}

DLLEXPORT void
DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (UpscaleTOP*)instance;
}

}   // extern "C"
