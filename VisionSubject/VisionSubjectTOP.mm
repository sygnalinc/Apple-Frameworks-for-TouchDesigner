// VisionSubject TOP — TouchDesigner カスタムオペレータ(macOS / Apple Vision)
//
// 入力 TOP の映像から「被写体」(人に限らない前景オブジェクト)を切り抜く。
// 写真アプリの「被写体をコピー」と同じ VNGenerateForegroundInstanceMaskRequest(macOS 14+)。
// 人物限定の VisionSegment の汎用版。
//
// モード:
//   Mask     全被写体の統合ソフトマスク(入力解像度・Mono32Float・0〜1)
//   Cutout   被写体を切り抜いた画像(背景透過・BGRA)
//   Instance 被写体ごとのマスクを R/G/B/A の各チャンネルに分離(最大4個・低解像度)
//
// 実装: cook のたびに入力 TOP を非同期ダウンロードし、ワーカースレッドが
// Vision 解析 → CPU バッファ化。cook は最新結果をアップロードするだけ(1〜2フレーム遅れ)。

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

#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

struct FrameResult
{
    std::vector<uint8_t> data;
    uint32_t width = 0;
    uint32_t height = 0;
    OP_PixelFormat format = OP_PixelFormat::Mono32Float;
    uint64_t serial = 0;
};

class VisionSubjectTOP : public TOP_CPlusPlusBase
{
public:
    VisionSubjectTOP(const OP_NodeInfo*, TOP_Context* context) : myContext(context)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionSubjectTOP() override
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
        const char* m = inputs->getParString("Mode");
        myMode = (strcmp(m, "cutout") == 0) ? 1 : (strcmp(m, "instance") == 0) ? 2 : 0;

        // 静止画入力でもモード変更で再解析させる
        if (myMode != myLastModeSeen) {
            myLastModeSeen = myMode;
            myLastCookSeen = -1;
        }

        const OP_TOPInput* top = inputs->getInputTOP(0);
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

        FrameResult frame;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            if (myResult.data.empty())
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
            p.page = "Vision Subject";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Mode");
            p.label = "Mode";
            p.page = "Vision Subject";
            p.defaultValue = "mask";
            const char* names[] = {"mask", "cutout", "instance"};
            const char* labels[] = {"Soft Mask", "Cutout (Transparent BG)",
                                    "Instance Masks (RGBA)"};
            manager->appendMenu(p, 3, names, labels);
        }
        {
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "Vision Subject";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[5] = {"executes", "submits", "analyzes", "instances", "analyze_ms"};
        float values[5] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           (float)myInstances, myAnalyzeMs.load()};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        if (@available(macOS 14.0, *))
            return;
        warning->setString("VisionSubject requires macOS 14+");
    }

private:
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            int mode;
            bool flip;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                download = std::move(myPending);
                myHasPending = false;
                myBusy = true;
                mode = myMode;
                flip = myFlip;
            }
            FrameResult result;
            const auto t0 = std::chrono::steady_clock::now();
            analyze(download, mode, flip, result);
            myAnalyzeMs = std::chrono::duration<float, std::milli>(
                              std::chrono::steady_clock::now() - t0).count();
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                if (!result.data.empty()) {
                    result.serial = ++mySerial;
                    myResult = std::move(result);
                }
                myBusy = false;
            }
        }
    }

    void analyze(OP_SmartRef<OP_TOPDownloadResult>& download, int mode, bool flip,
                 FrameResult& out)
    {
        if (!download)
            return;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || w == 0 || h == 0)
            return;

        if (@available(macOS 14.0, *)) {
            @autoreleasepool {
                // generateMaskedImageOfInstances(CoreImage 系)は CreateWithBytes の
                // 非IOSurfaceバッファだと失敗する。IOSurface対応バッファへコピーして渡す
                CVPixelBufferRef input = nullptr;
                NSDictionary* attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
                CVPixelBufferCreate(nullptr, w, h, kCVPixelFormatType_32BGRA,
                                    (__bridge CFDictionaryRef)attrs, &input);
                if (!input)
                    return;
                CVPixelBufferLockBaseAddress(input, 0);
                {
                    const size_t stride = CVPixelBufferGetBytesPerRow(input);
                    uint8_t* base = (uint8_t*)CVPixelBufferGetBaseAddress(input);
                    for (uint32_t y = 0; y < h; y++)
                        memcpy(base + (size_t)y * stride,
                               (const uint8_t*)data + (size_t)y * w * 4, (size_t)w * 4);
                }
                CVPixelBufferUnlockBaseAddress(input, 0);

                VNImageRequestHandler* handler =
                    [[VNImageRequestHandler alloc] initWithCVPixelBuffer:input options:@{}];
                VNGenerateForegroundInstanceMaskRequest* request =
                    [[VNGenerateForegroundInstanceMaskRequest alloc] init];
                if ([handler performRequests:@[request] error:nil]) {
                    VNInstanceMaskObservation* obs = request.results.firstObject;
                    if (obs) {
                        myInstances = (int)obs.allInstances.count;
                        NSError* err = nil;
                        if (mode == 0) {
                            // 入力解像度のソフトマスク(OneComponent32Float)
                            CVPixelBufferRef mask =
                                [obs generateScaledMaskForImageForInstances:obs.allInstances
                                                         fromRequestHandler:handler
                                                                      error:&err];
                            if (mask) {
                                copyFloatMask(mask, flip, out);
                                CVPixelBufferRelease(mask);
                            }
                        } else if (mode == 1) {
                            // 背景透過の切り抜き画像
                            CVPixelBufferRef img =
                                [obs generateMaskedImageOfInstances:obs.allInstances
                                                 fromRequestHandler:handler
                                            croppedToInstancesExtent:NO
                                                              error:&err];
                            if (img) {
                                copyColorImage(img, flip, out);
                                CVPixelBufferRelease(img);
                            }
                        } else {
                            // 画素値=インスタンス番号のマスクを RGBA へ分離
                            copyInstanceMask(obs.instanceMask, flip, out);
                        }
                    } else {
                        myInstances = 0;
                        // 被写体なし: 空の黒マスクを出す(前回の絵が残らないように)
                        out.width = w;
                        out.height = h;
                        out.format = (mode == 1) ? OP_PixelFormat::BGRA8Fixed
                                                 : OP_PixelFormat::Mono8Fixed;
                        out.data.assign((size_t)w * h * ((mode == 1) ? 4 : 1), 0);
                    }
                }
                CVPixelBufferRelease(input);
            }
        }
    }

    static void copyFloatMask(CVPixelBufferRef mask, bool flip, FrameResult& out)
    {
        CVPixelBufferLockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
        const uint32_t mw = (uint32_t)CVPixelBufferGetWidth(mask);
        const uint32_t mh = (uint32_t)CVPixelBufferGetHeight(mask);
        const size_t stride = CVPixelBufferGetBytesPerRow(mask);
        const uint8_t* src = (const uint8_t*)CVPixelBufferGetBaseAddress(mask);
        if (src && mw && mh) {
            out.width = mw;
            out.height = mh;
            out.format = OP_PixelFormat::Mono32Float;
            out.data.resize((size_t)mw * mh * sizeof(float));
            float* dst = (float*)out.data.data();
            for (uint32_t y = 0; y < mh; y++)
                memcpy(dst + (size_t)(flip ? (mh - 1 - y) : y) * mw,
                       src + (size_t)y * stride, mw * sizeof(float));
        }
        CVPixelBufferUnlockBaseAddress(mask, kCVPixelBufferLock_ReadOnly);
    }

    static void copyColorImage(CVPixelBufferRef img, bool flip, FrameResult& out)
    {
        CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
        const uint32_t iw = (uint32_t)CVPixelBufferGetWidth(img);
        const uint32_t ih = (uint32_t)CVPixelBufferGetHeight(img);
        const size_t stride = CVPixelBufferGetBytesPerRow(img);
        const uint8_t* src = (const uint8_t*)CVPixelBufferGetBaseAddress(img);
        if (src && iw && ih) {
            out.width = iw;
            out.height = ih;
            out.format = OP_PixelFormat::BGRA8Fixed;
            out.data.resize((size_t)iw * ih * 4);
            for (uint32_t y = 0; y < ih; y++)
                memcpy(out.data.data() + (size_t)(flip ? (ih - 1 - y) : y) * iw * 4,
                       src + (size_t)y * stride, (size_t)iw * 4);
        }
        CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
    }

    static void copyInstanceMask(CVPixelBufferRef mask, bool flip, FrameResult& out)
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
            out.format = OP_PixelFormat::RGBA8Fixed;
            out.data.assign((size_t)mw * mh * 4, 0);
            for (uint32_t y = 0; y < mh; y++) {
                const uint8_t* row = src + (size_t)y * stride;
                uint8_t* dst = out.data.data() + (size_t)(flip ? (mh - 1 - y) : y) * mw * 4;
                for (uint32_t x = 0; x < mw; x++) {
                    const uint8_t idx = row[x];
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
    FrameResult myResult;
    uint64_t mySerial = 0;
    uint64_t myUploadedSerial = 0;
    int64_t myLastCookSeen = -1;
    int myMode = 0;
    int myLastModeSeen = -1;
    std::atomic<bool> myFlip{true};

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0}, myInstances{0};
    std::atomic<float> myAnalyzeMs{0.0f};
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
    info->customOPInfo.opType->setString("Visionsubject");
    info->customOPInfo.opLabel->setString("Vision Subject");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("VSU");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/VisionSubject/README.md");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT TOP_CPlusPlusBase*
CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new VisionSubjectTOP(info, context);
}

DLLEXPORT void
DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (VisionSubjectTOP*)instance;
}

}   // extern "C"
