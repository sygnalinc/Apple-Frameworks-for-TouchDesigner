// VisionFlow TOP — TouchDesigner カスタムオペレータ(macOS / Apple Vision)
//
// 入力 TOP の連続フレームからオプティカルフロー(動きベクトル場)を生成する。
// Windows+NVIDIA 専用の Optical Flow TOP の macOS 代替。
// VNGenerateOpticalFlowRequest(Revision2 は GPU/ANE 実行)。
//
// 出力: RG32Float の 2チャンネルテクスチャ。R=dx, G=dy。
//   Units=Pixels: Vision の生値(画素単位。+y は画面下向き)
//   Units=UV:     解像度で正規化し dy の符号を反転(TD の uv 系。+v は画面上向き)
//
// 実装: ワーカースレッドが前フレームを保持し、前→現フレームのフローを推定。
// cook はブロックしない(結果は1〜2フレーム遅れ)。

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
    uint64_t serial = 0;
};

class VisionFlowTOP : public TOP_CPlusPlusBase
{
public:
    VisionFlowTOP(const OP_NodeInfo*, TOP_Context* context) : myContext(context)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionFlowTOP() override
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
        myUV = strcmp(inputs->getParString("Units"), "uv") == 0;
        const char* a = inputs->getParString("Accuracy");
        myAccuracy = (strcmp(a, "veryhigh") == 0) ? 3
                   : (strcmp(a, "high") == 0)     ? 2
                   : (strcmp(a, "medium") == 0)   ? 1 : 0;

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
            if (myResult.serial == myUploadedSerial || myResult.data.empty())
                return;
            frame = myResult;
            myUploadedSerial = myResult.serial;
        }

        TOP_UploadInfo info;
        info.textureDesc.texDim = OP_TexDim::e2D;
        info.textureDesc.width = frame.width;
        info.textureDesc.height = frame.height;
        info.textureDesc.pixelFormat = OP_PixelFormat::RG32Float;
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
            p.page = "Vision Flow";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Accuracy");
            p.label = "Accuracy";
            p.page = "Vision Flow";
            p.defaultValue = "medium";
            const char* names[] = {"low", "medium", "high", "veryhigh"};
            const char* labels[] = {"Low (Fast)", "Medium", "High", "Very High (Slow)"};
            manager->appendMenu(p, 4, names, labels);
        }
        {
            OP_StringParameter p("Units");
            p.label = "Output Units";
            p.page = "Vision Flow";
            p.defaultValue = "uv";
            const char* names[] = {"uv", "pixels"};
            const char* labels[] = {"UV (Normalized, +v Up)", "Pixels (+y Down)"};
            manager->appendMenu(p, 2, names, labels);
        }
        {
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "Vision Flow";
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

private:
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            int accuracy;
            bool uv;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                download = std::move(myPending);
                myHasPending = false;
                myBusy = true;
                accuracy = myAccuracy;
                uv = myUV;
            }
            FrameResult result;
            const auto t0 = std::chrono::steady_clock::now();
            analyze(download, accuracy, uv, result);
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

    void analyze(OP_SmartRef<OP_TOPDownloadResult>& download, int accuracy, bool uv,
                 FrameResult& out)
    {
        if (!download)
            return;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || w == 0 || h == 0)
            return;

        // 解像度が変わったら前フレームを破棄
        if (myPrevW != w || myPrevH != h)
            myPrev.clear();

        @autoreleasepool {
            if (!myPrev.empty()) {
                CVPixelBufferRef cur = nullptr, prev = nullptr;
                CVPixelBufferCreateWithBytes(nullptr, w, h, kCVPixelFormatType_32BGRA,
                                             data, w * 4, nullptr, nullptr, nullptr, &cur);
                CVPixelBufferCreateWithBytes(nullptr, w, h, kCVPixelFormatType_32BGRA,
                                             myPrev.data(), w * 4, nullptr, nullptr, nullptr,
                                             &prev);
                if (cur && prev) {
                    // target=前フレーム、handler=現フレーム(前→現の移動ベクトル)
                    VNGenerateOpticalFlowRequest* request =
                        [[VNGenerateOpticalFlowRequest alloc]
                            initWithTargetedCVPixelBuffer:prev options:@{}];
                    request.computationAccuracy =
                        (accuracy == 3) ? VNGenerateOpticalFlowRequestComputationAccuracyVeryHigh
                      : (accuracy == 2) ? VNGenerateOpticalFlowRequestComputationAccuracyHigh
                      : (accuracy == 1) ? VNGenerateOpticalFlowRequestComputationAccuracyMedium
                                        : VNGenerateOpticalFlowRequestComputationAccuracyLow;
                    request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float;

                    VNImageRequestHandler* handler =
                        [[VNImageRequestHandler alloc] initWithCVPixelBuffer:cur options:@{}];
                    if ([handler performRequests:@[request] error:nil]) {
                        VNPixelBufferObservation* obs = request.results.firstObject;
                        if (obs)
                            copyFlow(obs.pixelBuffer, uv, out);
                    }
                }
                if (cur)
                    CVPixelBufferRelease(cur);
                if (prev)
                    CVPixelBufferRelease(prev);
            }
            // 現フレームを次回の「前フレーム」として保存
            myPrev.assign((const uint8_t*)data, (const uint8_t*)data + (size_t)w * h * 4);
            myPrevW = w;
            myPrevH = h;
        }
    }

    // Vision のフロー(top-down)を TD 向けに行反転してコピー。UV モードでは正規化し
    // dy の符号を反転(TD の v は上向き)
    static void copyFlow(CVPixelBufferRef flow, bool uv, FrameResult& out)
    {
        if (!flow)
            return;
        CVPixelBufferLockBaseAddress(flow, kCVPixelBufferLock_ReadOnly);
        const uint32_t fw = (uint32_t)CVPixelBufferGetWidth(flow);
        const uint32_t fh = (uint32_t)CVPixelBufferGetHeight(flow);
        const size_t stride = CVPixelBufferGetBytesPerRow(flow);
        const uint8_t* src = (const uint8_t*)CVPixelBufferGetBaseAddress(flow);
        if (src && fw && fh) {
            out.width = fw;
            out.height = fh;
            out.data.resize((size_t)fw * fh * 2 * sizeof(float));
            float* dst = (float*)out.data.data();
            const float su = uv ? 1.0f / (float)fw : 1.0f;
            const float sv = uv ? -1.0f / (float)fh : 1.0f;
            for (uint32_t y = 0; y < fh; y++) {
                const float* row = (const float*)(src + (size_t)y * stride);
                float* drow = dst + (size_t)(fh - 1 - y) * fw * 2;
                for (uint32_t x = 0; x < fw; x++) {
                    drow[x * 2 + 0] = row[x * 2 + 0] * su;
                    drow[x * 2 + 1] = row[x * 2 + 1] * sv;
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(flow, kCVPixelBufferLock_ReadOnly);
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
    int myAccuracy = 1;
    std::atomic<bool> myFlip{true}, myUV{true};

    // ワーカー専用(前フレーム保持)
    std::vector<uint8_t> myPrev;
    uint32_t myPrevW = 0, myPrevH = 0;

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
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
    info->customOPInfo.opType->setString("Visionflow");
    info->customOPInfo.opLabel->setString("Vision Flow");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("VFL");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT TOP_CPlusPlusBase*
CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new VisionFlowTOP(info, context);
}

DLLEXPORT void
DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (VisionFlowTOP*)instance;
}

}   // extern "C"
