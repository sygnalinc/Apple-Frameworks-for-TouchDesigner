// VisionSaliency TOP — 顕著性マップ（macOS / Apple Vision）
//
// 入力 TOP の映像から「どこが目を引くか」のヒートマップを生成する。
// オートクロップ / オートフレーミング / カメラワーク自動化に使える形で、
// ヒートマップ（TOP出力）に加えて注目領域の矩形・視線の重心・スムージング済みの
// おすすめクロップ矩形を Info CHOP チャンネルで出す。
//
// モード:
//   Attention   VNGenerateAttentionBasedSaliencyImageRequest。人の視線が向かいやすい場所
//   Objectness  VNGenerateObjectnessBasedSaliencyImageRequest。物体がありそうな場所
//
// Info CHOP チャンネル（Info CHOP を接続して取り出す・座標はすべて 0〜1・左下原点）:
//   regions                          注目領域の数（Vision が返す salientObjects・最大3）
//   region{1..3}_u,v,width,height    各領域のバウンディングボックス（中心+サイズ）
//   focus_u, focus_v                 顕著性で重み付けした重心（スムージング済み）
//   frame_u, v, width, height       おすすめクロップ矩形（全領域の外接矩形に Padding を
//                                    掛け、Aspect 指定があれば比率を保ち、EMA で平滑化）
//
// frame_* を Crop TOP に式で繋げばオートフレーミングになる:
//   cropleft   = op('sal_info')['frame_u'] - op('sal_info')['frame_width']/2   等
//
// 実装: cook のたびに入力 TOP を非同期ダウンロードし、ワーカースレッドが Vision 推定 →
// ヒートマップ(Mono32Float)と矩形群を保存。cook は最新値を出すだけ（1〜2フレーム遅れ）。

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

constexpr int kMaxRegions = 3;

struct SaliencyResult
{
    std::vector<float> heat;        // Mono32Float
    uint32_t width = 0;
    uint32_t height = 0;
    uint64_t serial = 0;

    int regions = 0;
    float region[kMaxRegions][4] = {};   // 中心u, 中心v, width, height
    float focus[2] = {0.5f, 0.5f};
    float frame[4] = {0.5f, 0.5f, 1.0f, 1.0f};
};

class VisionSaliencyTOP : public TOP_CPlusPlusBase
{
public:
    VisionSaliencyTOP(const OP_NodeInfo*, TOP_Context* context) : myContext(context)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionSaliencyTOP() override
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
        myObjectness = strcmp(inputs->getParString("Mode"), "objectness") == 0;
        myPadding = inputs->getParDouble("Padding");
        myAspect = inputs->getParDouble("Aspect");
        mySmooth = inputs->getParDouble("Smooth");

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

        // 最新ヒートマップをアップロード
        SaliencyResult result;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            myLatest = myShared;   // Info CHOP 用に cook スレッド側へコピー
            if (myShared.serial == myUploadedSerial || myShared.heat.empty())
                return;
            result = myShared;
            myUploadedSerial = myShared.serial;
        }
        TOP_UploadInfo info;
        info.textureDesc.texDim = OP_TexDim::e2D;
        info.textureDesc.width = result.width;
        info.textureDesc.height = result.height;
        info.textureDesc.pixelFormat = OP_PixelFormat::Mono32Float;
        const uint64_t bytes = (uint64_t)result.heat.size() * sizeof(float);
        OP_SmartRef<TOP_Buffer> buf =
            myContext->createOutputBuffer(bytes, TOP_BufferFlags::None, nullptr);
        if (!buf)
            return;
        memcpy(buf->data, result.heat.data(), bytes);
        output->uploadBuffer(&buf, info, nullptr);
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Vision Saliency";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Mode");
            p.label = "Mode";
            p.page = "Vision Saliency";
            p.defaultValue = "attention";
            const char* names[] = {"attention", "objectness"};
            const char* labels[] = {"Attention", "Objectness"};
            manager->appendMenu(p, 2, names, labels);
        }
        {
            OP_NumericParameter p("Padding");
            p.label = "Frame Padding";
            p.page = "Vision Saliency";
            p.defaultValues[0] = 1.2;
            p.minSliders[0] = 1.0;
            p.maxSliders[0] = 2.0;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Aspect");
            p.label = "Frame Aspect (W/H, 0=Free)";
            p.page = "Vision Saliency";
            p.defaultValues[0] = 0.0;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 3.0;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Smooth");
            p.label = "Frame Smoothing";
            p.page = "Vision Saliency";
            p.defaultValues[0] = 0.7;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 0.95;
            manager->appendFloat(p);
        }
        {
            // TD の TOP ダウンロードは GL 系の上下逆（bottom-up）なので既定でフリップする
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "Vision Saliency";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override
    {
        return 1 + kMaxRegions * 4 + 2 + 4 + 2;   // regions + region* + focus + frame + 診断
    }

    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const SaliencyResult& r = myLatest;
        char buf[32];
        if (index == 0) {
            chan->name->setString("regions");
            chan->value = (float)r.regions;
            return;
        }
        index -= 1;
        if (index < kMaxRegions * 4) {
            const int reg = index / 4;
            const int c = index % 4;
            const char* f[4] = {"u", "v", "width", "height"};
            snprintf(buf, sizeof(buf), "region%d_%s", reg + 1, f[c]);
            chan->name->setString(buf);
            chan->value = r.region[reg][c];
            return;
        }
        index -= kMaxRegions * 4;
        if (index < 2) {
            chan->name->setString(index == 0 ? "focus_u" : "focus_v");
            chan->value = r.focus[index];
            return;
        }
        index -= 2;
        if (index < 4) {
            const char* f[4] = {"frame_u", "frame_v", "frame_width", "frame_height"};
            chan->name->setString(f[index]);
            chan->value = r.frame[index];
            return;
        }
        index -= 4;
        chan->name->setString(index == 0 ? "executes" : "analyzes");
        chan->value = index == 0 ? (float)myExecCount : (float)myAnalyzeCount;
    }

private:
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            bool objectness;
            double padding, aspect, smooth;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                download = std::move(myPending);
                myHasPending = false;
                myBusy = true;
                objectness = myObjectness;
                padding = myPadding;
                aspect = myAspect;
                smooth = mySmooth;
            }
            SaliencyResult result;
            const bool ok = analyze(download, objectness, result);
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                if (ok) {
                    // focus / frame は前回値と EMA でなめらかに追従させる
                    computeFrame(result, padding, aspect);
                    const float a = 1.0f - (float)smooth;
                    for (int i = 0; i < 2; i++)
                        result.focus[i] = myPrevFocus[i] + (result.focus[i] - myPrevFocus[i]) * a;
                    for (int i = 0; i < 4; i++)
                        result.frame[i] = myPrevFrame[i] + (result.frame[i] - myPrevFrame[i]) * a;
                    memcpy(myPrevFocus, result.focus, sizeof(myPrevFocus));
                    memcpy(myPrevFrame, result.frame, sizeof(myPrevFrame));
                    result.serial = ++mySerial;
                    myShared = std::move(result);
                }
                myBusy = false;
            }
        }
    }

    bool analyze(OP_SmartRef<OP_TOPDownloadResult>& download, bool objectness,
                 SaliencyResult& out)
    {
        if (!download)
            return false;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || w == 0 || h == 0)
            return false;

        @autoreleasepool {
            CVPixelBufferRef input = nullptr;
            CVPixelBufferCreateWithBytes(nullptr, w, h, kCVPixelFormatType_32BGRA,
                                         data, w * 4, nullptr, nullptr, nullptr, &input);
            if (!input)
                return false;

            VNImageBasedRequest* request;
            if (objectness)
                request = [[VNGenerateObjectnessBasedSaliencyImageRequest alloc] init];
            else
                request = [[VNGenerateAttentionBasedSaliencyImageRequest alloc] init];
            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCVPixelBuffer:input options:@{}];
            [handler performRequests:@[request] error:nil];
            CVPixelBufferRelease(input);

            VNSaliencyImageObservation* obs =
                (VNSaliencyImageObservation*)request.results.firstObject;
            if (!obs)
                return false;

            // ヒートマップ（OneComponent32Float・上下は Vision=top-down → 行反転）
            CVPixelBufferRef heat = obs.pixelBuffer;
            CVPixelBufferLockBaseAddress(heat, kCVPixelBufferLock_ReadOnly);
            const uint32_t mw = (uint32_t)CVPixelBufferGetWidth(heat);
            const uint32_t mh = (uint32_t)CVPixelBufferGetHeight(heat);
            const size_t stride = CVPixelBufferGetBytesPerRow(heat);
            const uint8_t* src = (const uint8_t*)CVPixelBufferGetBaseAddress(heat);
            bool ok = false;
            if (src && mw && mh) {
                out.width = mw;
                out.height = mh;
                out.heat.resize((size_t)mw * mh);
                double sum = 0, sumU = 0, sumV = 0;
                for (uint32_t y = 0; y < mh; y++) {
                    const float* row = (const float*)(src + (size_t)y * stride);
                    float* dst = out.heat.data() + (size_t)(myFlip ? (mh - 1 - y) : y) * mw;
                    memcpy(dst, row, mw * sizeof(float));
                    // 顕著性の重心（左下原点の v に直して積算）
                    const double v = (mh - 0.5 - y) / mh;
                    for (uint32_t x = 0; x < mw; x++) {
                        const double s = row[x];
                        sum += s;
                        sumU += s * ((x + 0.5) / mw);
                        sumV += s * v;
                    }
                }
                if (sum > 1e-6) {
                    out.focus[0] = (float)(sumU / sum);
                    out.focus[1] = (float)(sumV / sum);
                }
                ok = true;
            }
            CVPixelBufferUnlockBaseAddress(heat, kCVPixelBufferLock_ReadOnly);

            // 注目領域（boundingBox は 0〜1・左下原点 = TD と同じ向き）
            out.regions = 0;
            for (VNRectangleObservation* rect in obs.salientObjects) {
                if (out.regions >= kMaxRegions)
                    break;
                const CGRect b = rect.boundingBox;
                out.region[out.regions][0] = (float)(b.origin.x + b.size.width * 0.5);
                out.region[out.regions][1] = (float)(b.origin.y + b.size.height * 0.5);
                out.region[out.regions][2] = (float)b.size.width;
                out.region[out.regions][3] = (float)b.size.height;
                out.regions++;
            }
            return ok;
        }
    }

    // 全注目領域の外接矩形 → Padding → Aspect 制約 → 画面内へクランプ
    static void computeFrame(SaliencyResult& r, double padding, double aspect)
    {
        if (r.regions == 0) {
            r.frame[0] = 0.5f;
            r.frame[1] = 0.5f;
            r.frame[2] = 1.0f;
            r.frame[3] = 1.0f;
            return;
        }
        float minU = 1, minV = 1, maxU = 0, maxV = 0;
        for (int i = 0; i < r.regions; i++) {
            minU = std::min(minU, r.region[i][0] - r.region[i][2] * 0.5f);
            maxU = std::max(maxU, r.region[i][0] + r.region[i][2] * 0.5f);
            minV = std::min(minV, r.region[i][1] - r.region[i][3] * 0.5f);
            maxV = std::max(maxV, r.region[i][1] + r.region[i][3] * 0.5f);
        }
        float cu = (minU + maxU) * 0.5f;
        float cv = (minV + maxV) * 0.5f;
        float fw = std::min(1.0f, (maxU - minU) * (float)padding);
        float fh = std::min(1.0f, (maxV - minV) * (float)padding);
        if (aspect > 0.001) {
            // 指定比率(W/H)を保ったまま、外接矩形を覆う最小サイズへ広げる
            if (fw / fh < aspect)
                fw = std::min(1.0f, fh * (float)aspect);
            else
                fh = std::min(1.0f, fw / (float)aspect);
        }
        cu = std::clamp(cu, fw * 0.5f, 1.0f - fw * 0.5f);
        cv = std::clamp(cv, fh * 0.5f, 1.0f - fh * 0.5f);
        r.frame[0] = cu;
        r.frame[1] = cv;
        r.frame[2] = fw;
        r.frame[3] = fh;
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

    SaliencyResult myShared;    // ワーカー→cook（mutex 保護）
    SaliencyResult myLatest;    // cook スレッド側コピー（Info CHOP が読む）
    uint64_t mySerial = 0;
    uint64_t myUploadedSerial = 0;
    float myPrevFocus[2] = {0.5f, 0.5f};
    float myPrevFrame[4] = {0.5f, 0.5f, 1.0f, 1.0f};

    int64_t myLastCookSeen = -1;
    bool myObjectness = false;
    double myPadding = 1.2, myAspect = 0.0, mySmooth = 0.7;
    std::atomic<bool> myFlip{true};

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
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
    info->customOPInfo.opType->setString("Visionsaliency");
    info->customOPInfo.opLabel->setString("Vision Saliency");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("VSL");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/VisionSaliency/README.md");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT TOP_CPlusPlusBase*
CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new VisionSaliencyTOP(info, context);
}

DLLEXPORT void
DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (VisionSaliencyTOP*)instance;
}

}   // extern "C"
