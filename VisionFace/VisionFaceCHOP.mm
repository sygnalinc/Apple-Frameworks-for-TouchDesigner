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
//   （Landmarks オン時）face{i}/p{0..84}:u,v   全85ランドマーク点
//
// face の並びは bbox 中心の x で左→右にソートする。
//
// 実装: cook のたびに TOP を非同期ダウンロードし、ワーカースレッドが Vision 推定 →
// 結果を保存。cook は最新結果を出すだけ（1〜2フレーム遅れ）。

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>

#include "../common/AspectCoords.h"

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
// 各領域の点数は Vision が返す実測値（288サンプルで一定・macOS 26）。合計85。
// allPoints は76しか返さないが、これは medianLine が他領域と重複しているため。
// **確保数を実測より小さくすると末尾が切り捨てられ、輪郭が片側だけ短くなる**（実際に踏んだ）。
constexpr int kNumLandmarks = 85;
constexpr int kNumCentroids = 4;   // left_eye, right_eye, nose, mouth

static const char* kCentroidNames[kNumCentroids] = {
    "left_eye", "right_eye", "nose", "mouth",
};

struct Face
{
    bool valid = false;
    float bbox[4] = {};                       // 中心u, 中心v, width, height
    float rot[3] = {};                        // roll, yaw, pitch
    float quality = 0;                        // 顔写りスコア 0〜1(Quality有効時)
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
        myQuality = inputs->getParInt("Quality") != 0;
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
        if (myQuality) {
            if (local == 0) {
                snprintf(buf, sizeof(buf), "face%d/quality", face);
                name->setString(buf);
                return;
            }
            local -= 1;
        }
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
        const tdaspect::Mapper map{ inputs->getParInt("Aspectcorrectuv") != 0,
                                    top ? (float)top->textureDesc.width  : 0.0f,
                                    top ? (float)top->textureDesc.height : 0.0f };
        for (int i = 0; i < myMaxFaces; i++) {
            const bool on = active && i < (int)faces.size() && faces[i].valid;
            const Face& face = (i < (int)faces.size()) ? faces[i] : myEmpty;
            int ch = i * perFace();
            output->channels[ch++][0] = on ? 1.0f : 0.0f;
            output->channels[ch++][0] = on ? map.x(face.bbox[0]) : 0.0f;
            output->channels[ch++][0] = on ? map.y(face.bbox[1]) : 0.0f;
            output->channels[ch++][0] = on ? map.dx(face.bbox[2]) : 0.0f;
            output->channels[ch++][0] = on ? map.dy(face.bbox[3]) : 0.0f;
            for (int c = 0; c < 3; c++)
                output->channels[ch++][0] = on ? face.rot[c] : 0.0f;
            if (myQuality)
                output->channels[ch++][0] = on ? face.quality : 0.0f;
            for (int c = 0; c < kNumCentroids; c++) {
                output->channels[ch++][0] = on ? map.x(face.centroid[c][0]) : 0.0f;
                output->channels[ch++][0] = on ? map.y(face.centroid[c][1]) : 0.0f;
            }
            if (myLandmarks) {
                for (int p = 0; p < kNumLandmarks; p++) {
                    output->channels[ch++][0] = on ? map.x(face.points[p][0]) : 0.0f;
                    output->channels[ch++][0] = on ? map.y(face.points[p][1]) : 0.0f;
                }
            }
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        // uv を入力画像のアスペクト比へ再スケール（Body Track CHOP と同名・同既定）
        tdaspect::appendAspectCorrect<OP_ParameterManager, OP_NumericParameter>(manager, "Vision Face");
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
            p.label = "All Landmark Points (85)";
            p.page = "Vision Face";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
        {
            // VNDetectFaceCaptureQualityRequest による顔写りスコア(ベストショット選択用)
            OP_NumericParameter p("Quality");
            p.label = "Face Capture Quality";
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
        return 1 + 4 + 3 + (myQuality ? 1 : 0) + kNumCentroids * 2 +
               (myLandmarks ? kNumLandmarks * 2 : 0);
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

            // 顔写りスコア(有効時のみ・別リクエスト)。bbox中心の最近傍で対応付ける
            NSArray<VNFaceObservation*>* qualityObs = nil;
            if (myQuality) {
                VNDetectFaceCaptureQualityRequest* qreq =
                    [[VNDetectFaceCaptureQualityRequest alloc] init];
                if ([handler performRequests:@[qreq] error:nil])
                    qualityObs = qreq.results;
            }

            for (VNFaceObservation* obs in request.results) {
                Face face;
                // ランドマークの未使用スロットは -1 で埋める（0 だと bbox 隅の
                // 「実在しない点」に見えてしまい、線を引くと画面外へ飛ぶ）。
                // 領域ごとの点数は顔の constellation により変わる（目が6点のこともある）。
                for (int i = 0; i < kNumLandmarks; i++) {
                    face.points[i][0] = -1.0f;
                    face.points[i][1] = -1.0f;
                }
                face.valid = true;
                const CGRect b = obs.boundingBox;
                face.bbox[0] = (float)(b.origin.x + b.size.width * 0.5);
                face.bbox[1] = (float)(b.origin.y + b.size.height * 0.5);
                face.bbox[2] = (float)b.size.width;
                face.bbox[3] = (float)b.size.height;
                face.rot[0] = obs.roll ? obs.roll.floatValue : 0.0f;
                face.rot[1] = obs.yaw ? obs.yaw.floatValue : 0.0f;
                face.rot[2] = obs.pitch ? obs.pitch.floatValue : 0.0f;

                if (qualityObs) {
                    double bestD = 1e9;
                    for (VNFaceObservation* q in qualityObs) {
                        const CGRect qb = q.boundingBox;
                        const double du = (qb.origin.x + qb.size.width * 0.5) - face.bbox[0];
                        const double dv = (qb.origin.y + qb.size.height * 0.5) - face.bbox[1];
                        const double d = du * du + dv * dv;
                        if (d < bestD && q.faceCaptureQuality) {
                            bestD = d;
                            face.quality = q.faceCaptureQuality.floatValue;
                        }
                    }
                }

                VNFaceLandmarks2D* lm = obs.landmarks;
                if (lm) {
                    regionCentroid(lm.leftEye, b, face.centroid[0]);
                    regionCentroid(lm.rightEye, b, face.centroid[1]);
                    regionCentroid(lm.nose, b, face.centroid[2]);
                    regionCentroid(lm.outerLips, b, face.centroid[3]);
                    // allPoints は「領域を繋いだ順」ではなく描画に使えない並びなので、
                    // **領域ごとに、その領域内の正しい順序で**詰め直す。
                    // 並び（p0 始まり・合計85点）:
                    //   0-16  faceContour(17)  17-22 leftEye(6)   23-28 rightEye(6)
                    //   29-34 leftEyebrow(6)   35-40 rightEyebrow(6)
                    //   41-48 nose(8)          49-54 noseCrest(6)  55-64 medianLine(10)
                    //   65-78 outerLips(14)    79-84 innerLips(6)
                    // 点数は macOS 26 実測（288サンプルで一定）。**allPoints は76しか返さないが
                    // 領域の合計は85**（medianLine が他領域と重複するため）。
                    // 確保数を実測より小さくすると末尾が切り捨てられる。以前 contour を 16 に
                    // していたため 17 点目が落ち、輪郭の片側だけ短く終わって左右非対称に見えた。
                    // 領域が取れなかった分は 0 のまま（描画側は confidence ではなく
                    // この並びを前提に線を引ける）。
                    {
                        VNFaceLandmarkRegion2D* regions[10] = {
                            lm.faceContour, lm.leftEye, lm.rightEye,
                            lm.leftEyebrow, lm.rightEyebrow,
                            lm.nose, lm.noseCrest, lm.medianLine,
                            lm.outerLips, lm.innerLips,
                        };
                        const int counts[10] = {17, 6, 6, 6, 6, 8, 6, 10, 14, 6};
                        int base = 0;
                        for (int r = 0; r < 10; r++) {
                            VNFaceLandmarkRegion2D* reg = regions[r];
                            if (reg) {
                                const CGPoint* pts = reg.normalizedPoints;
                                const int n = std::min((int)reg.pointCount, counts[r]);
                                for (int i = 0; i < n && base + i < kNumLandmarks; i++)
                                    mapPoint(pts[i], b, face.points[base + i]);
                            }
                            base += counts[r];
                        }
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
    std::atomic<bool> myQuality{false};
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
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    // ランドマークの並びを 76 → 85 に変更した（輪郭17点目などの切り捨てを解消）。
    // p インデックスがずれる後方非互換の変更なので、この op だけ major を上げる。
    info->customOPInfo.majorVersion = 1;
    info->customOPInfo.minorVersion = 0;
    info->customOPInfo.opIcon->setString("VFC");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/VisionFace/README.md");
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
