// VisionFace CHOP — 顔検出+ランドマーク（macOS / Apple Vision）
//
// TOP パラメータで指定した映像から複数の顔（VNDetectFaceLandmarksRequest）を検出し、
// バウンディングボックス・向き（roll/yaw/pitch）・主要ランドマークを出力する。
// Windows+NVIDIA 専用の Face Track CHOP の macOS 代替を想定（チャンネル形式は独自）。
//
// 出力チャンネル（Max Faces = N のとき face1..faceN）:
//   face{i}:valid                    検出できたか（1/0）
//   face{i}/bbox:u,v,width,height    顔のバウンディングボックス（中心+サイズ・0〜1）
//   face{i}/roll,yaw,pitch           顔の向き（ラジアン。取得できない軸は 0）
//   face{i}/left_eye:u,v             左目の中心（画像正規化座標）
//   face{i}/right_eye:u,v            右目の中心
//   face{i}/nose:u,v                 鼻
//   face{i}/mouth:u,v                口の中心
//   （Landmarks オン時）face{i}/p{0..75}:u,v   全76ランドマーク点
//
// face の並びは bbox 中心の x で左→右にソートする。
//
// 実装: cook のたびに TOP を非同期ダウンロードし、ワーカースレッドが Vision 推定 →
// 結果を保存。cook は最新結果を出すだけ（1〜2フレーム遅れ）。

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

constexpr int kMaxFaces = 100;
constexpr int kNumLandmarks = 76;
constexpr int kNumCentroids = 4;   // left_eye, right_eye, nose, mouth

static const char* kCentroidNames[kNumCentroids] = {
    "left_eye", "right_eye", "nose", "mouth",
};

struct Face
{
    bool valid = false;
    float bbox[4] = {};                       // 中心u, 中心v, width, height
    float rot[3] = {};                        // roll, yaw, pitch
    float centroid[kNumCentroids][2] = {};
    float points[kNumLandmarks][2] = {};
};

class VisionFaceCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit VisionFaceCHOP(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionFaceCHOP() override
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

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs* inputs, void*) override
    {
        myMaxFaces = std::max(1, std::min(kMaxFaces, (int)inputs->getParInt("Maxfaces")));
        myLandmarks = inputs->getParInt("Landmarks") != 0;
        info->numChannels = myMaxFaces * perFace();
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t index, OP_String* name, const OP_Inputs*, void*) override
    {
        const int face = index / perFace() + 1;
        int local = index % perFace();
        char buf[64];
        if (local == 0) {
            snprintf(buf, sizeof(buf), "face%d:valid", face);
            name->setString(buf);
            return;
        }
        local -= 1;
        if (local < 4) {
            const char* f[4] = {"u", "v", "width", "height"};
            snprintf(buf, sizeof(buf), "face%d/bbox:%s", face, f[local]);
            name->setString(buf);
            return;
        }
        local -= 4;
        if (local < 3) {
            const char* f[3] = {"roll", "yaw", "pitch"};
            snprintf(buf, sizeof(buf), "face%d/%s", face, f[local]);
            name->setString(buf);
            return;
        }
        local -= 3;
        if (local < kNumCentroids * 2) {
            const char* f[2] = {"u", "v"};
            snprintf(buf, sizeof(buf), "face%d/%s:%s", face,
                     kCentroidNames[local / 2], f[local % 2]);
            name->setString(buf);
            return;
        }
        local -= kNumCentroids * 2;
        const char* f[2] = {"u", "v"};
        snprintf(buf, sizeof(buf), "face%d/p%d:%s", face, local / 2, f[local % 2]);
        name->setString(buf);
    }

    void execute(CHOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        myFlip = inputs->getParInt("Flip") != 0;
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

        std::vector<Face> faces;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            faces = myFaces;
        }
        for (int i = 0; i < myMaxFaces; i++) {
            const bool on = active && i < (int)faces.size() && faces[i].valid;
            const Face& face = (i < (int)faces.size()) ? faces[i] : myEmpty;
            int ch = i * perFace();
            output->channels[ch++][0] = on ? 1.0f : 0.0f;
            for (int c = 0; c < 4; c++)
                output->channels[ch++][0] = on ? face.bbox[c] : 0.0f;
            for (int c = 0; c < 3; c++)
                output->channels[ch++][0] = on ? face.rot[c] : 0.0f;
            for (int c = 0; c < kNumCentroids; c++) {
                output->channels[ch++][0] = on ? face.centroid[c][0] : 0.0f;
                output->channels[ch++][0] = on ? face.centroid[c][1] : 0.0f;
            }
            if (myLandmarks) {
                for (int p = 0; p < kNumLandmarks; p++) {
                    output->channels[ch++][0] = on ? face.points[p][0] : 0.0f;
                    output->channels[ch++][0] = on ? face.points[p][1] : 0.0f;
                }
            }
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Top");
            p.label = "TOP";
            p.page = "Vision Face";
            manager->appendTOP(p);
        }
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Vision Face";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Maxfaces");
            p.label = "Max Faces";
            p.page = "Vision Face";
            p.defaultValues[0] = 5;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 10;
            p.minValues[0] = 1;
            p.maxValues[0] = kMaxFaces;
            p.clampMins[0] = true;
            p.clampMaxes[0] = true;
            manager->appendInt(p);
        }
        {
            OP_NumericParameter p("Landmarks");
            p.label = "All Landmark Points (76)";
            p.page = "Vision Face";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
        {
            // TD の TOP ダウンロードは GL 系の上下逆（bottom-up）なので既定でフリップする
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "Vision Face";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[3] = {"executes", "submits", "analyzes"};
        float values[3] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

private:
    int perFace() const
    {
        return 1 + 4 + 3 + kNumCentroids * 2 + (myLandmarks ? kNumLandmarks * 2 : 0);
    }

    // ---------------------------------------------------------- worker

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
            std::vector<Face> faces = analyze(download);
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                myFaces = std::move(faces);
                myBusy = false;
            }
        }
    }

    // 顔bbox内の正規化点 → 画像全体の正規化座標へ
    static void mapPoint(const CGPoint& p, const CGRect& bbox, float* out)
    {
        out[0] = (float)(bbox.origin.x + p.x * bbox.size.width);
        out[1] = (float)(bbox.origin.y + p.y * bbox.size.height);
    }

    static void regionCentroid(VNFaceLandmarkRegion2D* region, const CGRect& bbox, float* out)
    {
        if (!region || region.pointCount == 0)
            return;
        const CGPoint* pts = region.normalizedPoints;
        double su = 0, sv = 0;
        for (NSUInteger i = 0; i < region.pointCount; i++) {
            su += pts[i].x;
            sv += pts[i].y;
        }
        CGPoint mean = CGPointMake(su / region.pointCount, sv / region.pointCount);
        mapPoint(mean, bbox, out);
    }

    std::vector<Face> analyze(OP_SmartRef<OP_TOPDownloadResult>& download)
    {
        std::vector<Face> result;
        if (!download)
            return result;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || w == 0 || h == 0)
            return result;

        @autoreleasepool {
            CVPixelBufferRef buffer = nullptr;
            CVPixelBufferCreateWithBytes(nullptr, w, h, kCVPixelFormatType_32BGRA,
                                         data, w * 4, nullptr, nullptr, nullptr, &buffer);
            if (!buffer)
                return result;

            VNDetectFaceLandmarksRequest* request =
                [[VNDetectFaceLandmarksRequest alloc] init];
            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCVPixelBuffer:buffer options:@{}];
            [handler performRequests:@[request] error:nil];

            for (VNFaceObservation* obs in request.results) {
                Face face;
                face.valid = true;
                const CGRect b = obs.boundingBox;
                face.bbox[0] = (float)(b.origin.x + b.size.width * 0.5);
                face.bbox[1] = (float)(b.origin.y + b.size.height * 0.5);
                face.bbox[2] = (float)b.size.width;
                face.bbox[3] = (float)b.size.height;
                face.rot[0] = obs.roll ? obs.roll.floatValue : 0.0f;
                face.rot[1] = obs.yaw ? obs.yaw.floatValue : 0.0f;
                face.rot[2] = obs.pitch ? obs.pitch.floatValue : 0.0f;

                VNFaceLandmarks2D* lm = obs.landmarks;
                if (lm) {
                    regionCentroid(lm.leftEye, b, face.centroid[0]);
                    regionCentroid(lm.rightEye, b, face.centroid[1]);
                    regionCentroid(lm.nose, b, face.centroid[2]);
                    regionCentroid(lm.outerLips, b, face.centroid[3]);
                    VNFaceLandmarkRegion2D* all = lm.allPoints;
                    if (all) {
                        const CGPoint* pts = all.normalizedPoints;
                        const int n = std::min((int)all.pointCount, kNumLandmarks);
                        for (int i = 0; i < n; i++)
                            mapPoint(pts[i], b, face.points[i]);
                    }
                }
                result.push_back(face);
            }
            CVPixelBufferRelease(buffer);
        }
        // 左→右で安定ソート（bbox 中心の u）
        std::stable_sort(result.begin(), result.end(),
                         [](const Face& a, const Face& b) { return a.bbox[0] < b.bbox[0]; });
        return result;
    }

    // ---------------------------------------------------------- state

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;
    bool myHasPending = false;
    bool myBusy = false;
    OP_SmartRef<OP_TOPDownloadResult> myPending;
    std::vector<Face> myFaces;
    Face myEmpty;
    int64_t myLastCookSeen = -1;
    int myMaxFaces = 5;
    bool myLandmarks = false;
    std::atomic<bool> myFlip{true};

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
};

}   // namespace

// ------------------------------------------------------------------ entry points

extern "C" {

DLLEXPORT void
FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Visionface");
    info->customOPInfo.opLabel->setString("Vision Face");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("VFC");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT CHOP_CPlusPlusBase*
CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new VisionFaceCHOP(info);
}

DLLEXPORT void
DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (VisionFaceCHOP*)instance;
}

}   // extern "C"
