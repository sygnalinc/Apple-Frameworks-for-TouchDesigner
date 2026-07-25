// VisionSegment TOP — TouchDesigner カスタムオペレータ（macOS / Apple Vision）
//
// 入力 TOP の映像から人物セグメンテーションマスクを生成する。
// Windows+NVIDIA 専用の Nvidia Background TOP の macOS 代替を想定。
//
// モード:
//   Mask      VNGeneratePersonSegmentationRequest。人物領域の統合マスク（Mono・0〜1）。
//             Quality（fast/balanced/accurate）で解像度と精度が変わる
//   Instance  VNGeneratePersonInstanceMaskRequest（macOS 14+）。人物ごとのマスクを
//             R/G/B/A の各チャンネルに分離（最大4人。R=instance1, G=2, B=3, A=4）
//
// 出力はマスクのネイティブ解像度（入力よりも低い。合成時は Fit/Composite で合わせる）。
//
// 実装: cook のたびに入力 TOP を非同期ダウンロードし、ワーカースレッドが
// Vision 推定 → マスクを CPU バッファ化。cook は最新マスクをアップロードするだけ
// なのでフレームを止めない（結果は1〜2フレーム遅れ）。

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>

#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

// ワーカーが作る最新マスク（CPU バッファ）
struct MaskResult
{
    std::vector<uint8_t> data;
    uint32_t width = 0;
    uint32_t height = 0;
    bool rgba = false;      // false=Mono8（Mask） / true=RGBA8（Instance）
    uint64_t serial = 0;    // 更新検知用
};

class VisionSegmentTOP : public TOP_CPlusPlusBase
{
public:
    VisionSegmentTOP(const OP_NodeInfo*, TOP_Context* context) : myContext(context)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionSegmentTOP() override
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
        myInstanceMode = strcmp(inputs->getParString("Mode"), "instance") == 0;
        const char* q = inputs->getParString("Quality");
        myQuality = (strcmp(q, "accurate") == 0) ? 2 : (strcmp(q, "balanced") == 0) ? 1 : 0;

        const OP_TOPInput* top = inputs->getInputTOP(0);

        // 新しいフレームが来ていて、ワーカーが空いていればダウンロードを投入
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

        // 最新マスクをアップロード（新しい結果が無ければ前回のテクスチャが残る）
        MaskResult mask;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            if (myResult.serial == myUploadedSerial || myResult.data.empty())
                return;
            mask = myResult;
            myUploadedSerial = myResult.serial;
        }

        TOP_UploadInfo info;
        info.textureDesc.texDim = OP_TexDim::e2D;
        info.textureDesc.width = mask.width;
        info.textureDesc.height = mask.height;
        info.textureDesc.pixelFormat = mask.rgba ? OP_PixelFormat::RGBA8Fixed
                                                 : OP_PixelFormat::Mono8Fixed;
        OP_SmartRef<TOP_Buffer> buf =
            myContext->createOutputBuffer(mask.data.size(), TOP_BufferFlags::None, nullptr);
        if (!buf)
            return;
        memcpy(buf->data, mask.data.data(), mask.data.size());
        output->uploadBuffer(&buf, info, nullptr);
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Vision Segment";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Mode");
            p.label = "Mode";
            p.page = "Vision Segment";
            p.defaultValue = "mask";
            const char* names[] = {"mask", "instance"};
            const char* labels[] = {"Person Mask", "Instance Masks (RGBA)"};
            manager->appendMenu(p, 2, names, labels);
        }
        {
            OP_StringParameter p("Quality");
            p.label = "Quality";
            p.page = "Vision Segment";
            p.defaultValue = "balanced";
            const char* names[] = {"fast", "balanced", "accurate"};
            const char* labels[] = {"Fast", "Balanced", "Accurate"};
            manager->appendMenu(p, 3, names, labels);
        }
        {
            // TD の TOP ダウンロードは GL 系の上下逆（bottom-up）なので既定でフリップする
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "Vision Segment";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[5] = {"executes", "submits", "analyzes", "mask_w", "mask_h"};
        float values[5] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           (float)myMaskW, (float)myMaskH};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

private:
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            bool instanceMode;
            int quality;
            bool flip;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                download = std::move(myPending);
                myHasPending = false;
                myBusy = true;
                instanceMode = myInstanceMode;
                quality = myQuality;
                flip = myFlip;
            }
            MaskResult result;
            analyze(download, instanceMode, quality, flip, result);
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                if (!result.data.empty()) {
                    result.serial = ++mySerial;
                    myResult = std::move(result);
                    myMaskW = (int)myResult.width;
                    myMaskH = (int)myResult.height;
                }
                myBusy = false;
            }
        }
    }

    void analyze(OP_SmartRef<OP_TOPDownloadResult>& download, bool instanceMode,
                 int quality, bool flip, MaskResult& out)
    {
        if (!download)
            return;
        void* data = download->getData();   // 完了までブロック（ワーカースレッドなのでOK）
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || w == 0 || h == 0)
            return;

        @autoreleasepool {
            CVPixelBufferRef input = nullptr;
            CVPixelBufferCreateWithBytes(nullptr, w, h, kCVPixelFormatType_32BGRA,
                                         data, w * 4, nullptr, nullptr, nullptr, &input);
            if (!input)
                return;

            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCVPixelBuffer:input options:@{}];

            if (instanceMode) {
                if (@available(macOS 14.0, *)) {
                    VNGeneratePersonInstanceMaskRequest* request =
                        [[VNGeneratePersonInstanceMaskRequest alloc] init];
                    if ([handler performRequests:@[request] error:nil]) {
                        VNInstanceMaskObservation* obs = request.results.firstObject;
                        if (obs)
                            copyInstanceMask(obs.instanceMask, flip, out);
                    }
                }
                // macOS 13 以前は instance 非対応（出力を更新しない）
            } else {
                VNGeneratePersonSegmentationRequest* request =
                    [[VNGeneratePersonSegmentationRequest alloc] init];
                request.qualityLevel =
                    (quality == 2) ? VNGeneratePersonSegmentationRequestQualityLevelAccurate
                  : (quality == 1) ? VNGeneratePersonSegmentationRequestQualityLevelBalanced
                                   : VNGeneratePersonSegmentationRequestQualityLevelFast;
                request.outputPixelFormat = kCVPixelFormatType_OneComponent8;
                if ([handler performRequests:@[request] error:nil]) {
                    VNPixelBufferObservation* obs = request.results.firstObject;
                    if (obs)
                        copyMonoMask(obs.pixelBuffer, flip, out);
                }
            }
            CVPixelBufferRelease(input);
        }
    }

    // Vision のマスク（top-down）を TD 向け（flip 時は行反転で bottom-up）にコピーする
    static void copyMonoMask(CVPixelBufferRef mask, bool flip, MaskResult& out)
    {
        if (!mask)
            return;
        CVPixelBufferLockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
        const uint32_t mw = (uint32_t)CVPixelBufferGetWidth(mask);
        const uint32_t mh = (uint32_t)CVPixelBufferGetHeight(mask);
        const size_t stride = CVPixelBufferGetBytesPerRow(mask);
        const uint8_t* src = (const uint8_t*)CVPixelBufferGetBaseAddress(mask);
        if (src && mw && mh) {
            out.width = mw;
            out.height = mh;
            out.rgba = false;
            out.data.resize((size_t)mw * mh);
            for (uint32_t y = 0; y < mh; y++) {
                const uint8_t* row = src + (size_t)y * stride;
                uint8_t* dst = out.data.data() + (size_t)(flip ? (mh - 1 - y) : y) * mw;
                memcpy(dst, row, mw);
            }
        }
        CVPixelBufferUnlockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
    }

    // インスタンスマスク（画素値=インスタンス番号）を RGBA 各チャンネルへ分離する
    static void copyInstanceMask(CVPixelBufferRef mask, bool flip, MaskResult& out)
    {
        if (!mask)
            return;
        CVPixelBufferLockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
        const uint32_t mw = (uint32_t)CVPixelBufferGetWidth(mask);
        const uint32_t mh = (uint32_t)CVPixelBufferGetHeight(mask);
        const size_t stride = CVPixelBufferGetBytesPerRow(mask);
        const uint8_t* src = (const uint8_t*)CVPixelBufferGetBaseAddress(mask);
        if (src && mw && mh) {
            out.width = mw;
            out.height = mh;
            out.rgba = true;
            out.data.assign((size_t)mw * mh * 4, 0);
            for (uint32_t y = 0; y < mh; y++) {
                const uint8_t* row = src + (size_t)y * stride;
                uint8_t* dst = out.data.data() + (size_t)(flip ? (mh - 1 - y) : y) * mw * 4;
                for (uint32_t x = 0; x < mw; x++) {
                    const uint8_t idx = row[x];      // 0=背景, 1..4=人物
                    if (idx >= 1 && idx <= 4)
                        dst[x * 4 + (idx - 1)] = 255;
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
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
    MaskResult myResult;
    uint64_t mySerial = 0;
    uint64_t myUploadedSerial = 0;
    int64_t myLastCookSeen = -1;
    bool myInstanceMode = false;
    int myQuality = 1;
    std::atomic<bool> myFlip{true};

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
    std::atomic<int> myMaskW{0}, myMaskH{0};
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
    info->customOPInfo.opType->setString("Visionsegment");
    info->customOPInfo.opLabel->setString("Vision Segment");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("VSG");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/VisionSegment/README.md");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT TOP_CPlusPlusBase*
CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new VisionSegmentTOP(info, context);
}

DLLEXPORT void
DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (VisionSegmentTOP*)instance;
}

}   // extern "C"
