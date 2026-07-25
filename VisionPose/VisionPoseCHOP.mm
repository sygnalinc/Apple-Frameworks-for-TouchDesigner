// VisionPose CHOP — TouchDesigner カスタムオペレータ（macOS / Apple Vision）
//
// TOP パラメータで指定した映像を Apple Vision（VNDetectHumanBodyPoseRequest）で
// 多人数ボディポーズ推定し、**TD 標準の Body Track CHOP（NVIDIA・2D複数人）と
// 同じチャンネル形式**で出力する。Body Track CHOP の Windows 専用環境を
// macOS で置き換えるドロップイン用途を想定。
//
// 出力（Max Bodies = N のとき body1..bodyN・各 108ch / Rotations 有効時 210ch）:
//   body{i}:valid            トラッキング中か（1/0）
//   body{i}/bbox:u,v         バウンディングボックス中心（信頼できる関節の外接矩形）
//   body{i}/bbox:width,height
//   body{i}/trackingid       永続ID（フレーム間の最近傍マッチで維持・1始まり）
//   body{i}/{kp}:u,v,confidence[,rx,ry,rz]   34キーポイント（Maxine準拠の名前・順序）
//
// 座標は 0〜1・左下原点（Body Track CHOP と同一）。
// Vision に無いキーポイント（つま先・かかと・手指）は親関節の位置を confidence=0 で出力。
// rx/ry/rz は Vision では取れないため常に 0（チャンネルレイアウト互換のためのオプション）。
//
// 実装: cook のたびに TOP を非同期ダウンロードし、ワーカースレッドが
// getData()（完了までブロック）→ Vision 推定 → スロット割当。cook は最新結果を
// 出力するだけなのでフレームを止めない（結果は1〜2フレーム遅れ）。

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

#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

constexpr int kMaxBodies = 100;
constexpr int kNumKP = 34;

// Body Track CHOP（NVIDIA Maxine）の34キーポイント。名前・順序とも実機出力に一致させている
static const char* kKPNames[kNumKP] = {
    "pelvis", "left_hip", "right_hip", "torso", "left_knee", "right_knee",
    "neck", "left_ankle", "right_ankle",
    "left_big_toe", "right_big_toe", "left_small_toe", "right_small_toe",
    "left_heel", "right_heel",
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist",
    "left_pinky_knuckle", "right_pinky_knuckle", "left_middle_tip", "right_middle_tip",
    "left_index_knuckle", "right_index_knuckle", "left_thumb_tip", "right_thumb_tip",
};

// Vision の関節（内部インデックス）
enum VJoint {
    vNose = 0, vNeck, vLShoulder, vRShoulder, vLElbow, vRElbow, vLWrist, vRWrist,
    vRoot, vLHip, vRHip, vLKnee, vRKnee, vLAnkle, vRAnkle,
    vLEye, vREye, vLEar, vREar, vCount
};

static VNRecognizedPointKey VJointKey(int i)
{
    switch (i) {
        case vNose: return VNHumanBodyPoseObservationJointNameNose;
        case vNeck: return VNHumanBodyPoseObservationJointNameNeck;
        case vLShoulder: return VNHumanBodyPoseObservationJointNameLeftShoulder;
        case vRShoulder: return VNHumanBodyPoseObservationJointNameRightShoulder;
        case vLElbow: return VNHumanBodyPoseObservationJointNameLeftElbow;
        case vRElbow: return VNHumanBodyPoseObservationJointNameRightElbow;
        case vLWrist: return VNHumanBodyPoseObservationJointNameLeftWrist;
        case vRWrist: return VNHumanBodyPoseObservationJointNameRightWrist;
        case vRoot: return VNHumanBodyPoseObservationJointNameRoot;
        case vLHip: return VNHumanBodyPoseObservationJointNameLeftHip;
        case vRHip: return VNHumanBodyPoseObservationJointNameRightHip;
        case vLKnee: return VNHumanBodyPoseObservationJointNameLeftKnee;
        case vRKnee: return VNHumanBodyPoseObservationJointNameRightKnee;
        case vLAnkle: return VNHumanBodyPoseObservationJointNameLeftAnkle;
        case vRAnkle: return VNHumanBodyPoseObservationJointNameRightAnkle;
        case vLEye: return VNHumanBodyPoseObservationJointNameLeftEye;
        case vREye: return VNHumanBodyPoseObservationJointNameRightEye;
        case vLEar: return VNHumanBodyPoseObservationJointNameLeftEar;
        default: return VNHumanBodyPoseObservationJointNameRightEar;
    }
}

// Maxine 34kp ← Vision 19関節の対応。approx=true は Vision に無い kp で、
// 近い関節の位置を confidence=0 で流用する（つま先/かかと→足首、手指→手首）。
struct KPMap { int vjoint; bool approx; };
static const KPMap kKPMap[kNumKP] = {
    {vRoot, false},                     // pelvis
    {vLHip, false}, {vRHip, false},
    {-1, true},                         // torso（neck と root の中点で近似）
    {vLKnee, false}, {vRKnee, false},
    {vNeck, false},
    {vLAnkle, false}, {vRAnkle, false},
    {vLAnkle, true}, {vRAnkle, true},   // big_toe
    {vLAnkle, true}, {vRAnkle, true},   // small_toe
    {vLAnkle, true}, {vRAnkle, true},   // heel
    {vNose, false},
    {vLEye, false}, {vREye, false}, {vLEar, false}, {vREar, false},
    {vLShoulder, false}, {vRShoulder, false},
    {vLElbow, false}, {vRElbow, false},
    {vLWrist, false}, {vRWrist, false},
    {vLWrist, true}, {vRWrist, true},   // pinky_knuckle
    {vLWrist, true}, {vRWrist, true},   // middle_tip
    {vLWrist, true}, {vRWrist, true},   // index_knuckle
    {vLWrist, true}, {vRWrist, true},   // thumb_tip
};

struct Body
{
    bool valid = false;
    int trackingId = 0;
    float cx = 0.5f, cy = 0.5f;         // マッチング用の中心
    float bbox[4] = {};                 // u, v, width, height（中心+サイズ）
    float kp[kNumKP][3] = {};           // u, v, confidence
};

class VisionPoseCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit VisionPoseCHOP(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionPoseCHOP() override
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
        myMaxBodies = std::max(1, std::min(kMaxBodies, (int)inputs->getParInt("Maxbodies")));
        myRotations = inputs->getParInt("Rotations") != 0;
        const int perKP = myRotations ? 6 : 3;
        info->numChannels = myMaxBodies * (6 + kNumKP * perKP);
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t index, OP_String* name, const OP_Inputs*, void*) override
    {
        const int perKP = myRotations ? 6 : 3;
        const int perBody = 6 + kNumKP * perKP;
        const int body = index / perBody + 1;      // body1 始まり（Body Track CHOP と同じ）
        const int local = index % perBody;
        char buf[80];
        if (local == 0) {
            snprintf(buf, sizeof(buf), "body%d:valid", body);
        } else if (local <= 4) {
            const char* f[4] = {"u", "v", "width", "height"};
            snprintf(buf, sizeof(buf), "body%d/bbox:%s", body, f[local - 1]);
        } else if (local == 5) {
            snprintf(buf, sizeof(buf), "body%d/trackingid", body);
        } else {
            const int k = (local - 6) / perKP;
            const int c = (local - 6) % perKP;
            const char* f6[6] = {"u", "v", "confidence", "rx", "ry", "rz"};
            snprintf(buf, sizeof(buf), "body%d/%s:%s", body, kKPNames[k], f6[c]);
        }
        name->setString(buf);
    }

    void execute(CHOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        myFlip = inputs->getParInt("Flip") != 0;
        const OP_TOPInput* top = inputs->getParTOP("Top");

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

        // 最新結果を出力（ワーカー未完了の間は前回値を保持）
        Body slots[kMaxBodies];
        {
            std::lock_guard<std::mutex> lock(myMutex);
            memcpy(slots, mySlots, sizeof(slots));
        }
        const int perKP = myRotations ? 6 : 3;
        const int perBody = 6 + kNumKP * perKP;
        for (int b = 0; b < myMaxBodies; b++) {
            const Body& body = slots[b];
            const bool on = active && body.valid;
            const int base = b * perBody;
            output->channels[base + 0][0] = on ? 1.0f : 0.0f;
            for (int f = 0; f < 4; f++)
                output->channels[base + 1 + f][0] = on ? body.bbox[f] : 0.0f;
            output->channels[base + 5][0] = on ? (float)body.trackingId : 0.0f;
            for (int k = 0; k < kNumKP; k++) {
                const int kb = base + 6 + k * perKP;
                output->channels[kb + 0][0] = on ? body.kp[k][0] : 0.0f;
                output->channels[kb + 1][0] = on ? body.kp[k][1] : 0.0f;
                output->channels[kb + 2][0] = on ? body.kp[k][2] : 0.0f;
                if (myRotations) {
                    output->channels[kb + 3][0] = 0.0f;   // rx/ry/rz は Vision では取れない
                    output->channels[kb + 4][0] = 0.0f;
                    output->channels[kb + 5][0] = 0.0f;
                }
            }
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Top");
            p.label = "TOP";
            p.page = "Vision Pose";
            manager->appendTOP(p);
        }
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Vision Pose";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Maxbodies");
            p.label = "Max Bodies";
            p.page = "Vision Pose";
            p.defaultValues[0] = 8;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 10;
            p.minValues[0] = 1;
            p.maxValues[0] = kMaxBodies;
            p.clampMins[0] = true;
            p.clampMaxes[0] = true;
            manager->appendInt(p);
        }
        {
            // Body Track CHOP の Rotations 相当（チャンネルレイアウト互換のため。値は常に0）
            OP_NumericParameter p("Rotations");
            p.label = "Rotations (layout only)";
            p.page = "Vision Pose";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
        {
            // TD の TOP ダウンロードは GL 系の上下逆（bottom-up）なので既定でフリップする
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "Vision Pose";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 6; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[6] = {"executes", "submits", "analyzes", "last_w", "last_h", "last_bytes"};
        float values[6] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           (float)myLastW, (float)myLastH, (float)myLastSize};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

private:
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
            std::vector<Body> detected = analyze(download);
            myAnalyzeCount++;
            assignSlots(detected);   // myTrackSlots はワーカーのみが触る
            {
                std::lock_guard<std::mutex> lock(myMutex);
                memcpy(mySlots, myTrackSlots, sizeof(mySlots));
                myBusy = false;
            }
        }
    }

    std::vector<Body> analyze(OP_SmartRef<OP_TOPDownloadResult>& download)
    {
        std::vector<Body> result;
        if (!download)
            return result;
        void* data = download->getData();   // 完了までブロック（ワーカースレッドなのでOK）
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        myLastW = (int)w;
        myLastH = (int)h;
        myLastSize = (int64_t)download->size;
        if (!data || w == 0 || h == 0)
            return result;

        @autoreleasepool {
            CVPixelBufferRef buffer = nullptr;
            CVPixelBufferCreateWithBytes(nullptr, w, h, kCVPixelFormatType_32BGRA,
                                         data, w * 4, nullptr, nullptr, nullptr, &buffer);
            if (!buffer)
                return result;

            VNDetectHumanBodyPoseRequest* request = [[VNDetectHumanBodyPoseRequest alloc] init];
            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCVPixelBuffer:buffer options:@{}];
            [handler performRequests:@[request] error:nil];

            for (VNHumanBodyPoseObservation* obs in request.results) {
                NSDictionary<VNRecognizedPointKey, VNRecognizedPoint*>* points =
                    [obs recognizedPointsForGroupKey:VNRecognizedPointGroupKeyAll error:nil];
                if (!points)
                    continue;

                float vj[vCount][3] = {};
                for (int j = 0; j < vCount; j++) {
                    VNRecognizedPoint* pt = points[VJointKey(j)];
                    if (pt) {
                        vj[j][0] = (float)pt.location.x;
                        vj[j][1] = (float)pt.location.y;
                        vj[j][2] = (float)pt.confidence;
                    }
                }

                Body body;
                body.valid = true;
                for (int k = 0; k < kNumKP; k++) {
                    const KPMap& m = kKPMap[k];
                    if (m.vjoint >= 0) {
                        body.kp[k][0] = vj[m.vjoint][0];
                        body.kp[k][1] = vj[m.vjoint][1];
                        body.kp[k][2] = m.approx ? 0.0f : vj[m.vjoint][2];
                    } else {
                        // torso = neck と root の中点
                        body.kp[k][0] = (vj[vNeck][0] + vj[vRoot][0]) * 0.5f;
                        body.kp[k][1] = (vj[vNeck][1] + vj[vRoot][1]) * 0.5f;
                        body.kp[k][2] = std::min(vj[vNeck][2], vj[vRoot][2]);
                    }
                }

                // bbox = 信頼できる関節の外接矩形（中心 + サイズ）
                float minU = 1, minV = 1, maxU = 0, maxV = 0;
                int n = 0;
                float sumU = 0, sumV = 0;
                for (int j = 0; j < vCount; j++) {
                    if (vj[j][2] > 0.1f) {
                        minU = std::min(minU, vj[j][0]);
                        maxU = std::max(maxU, vj[j][0]);
                        minV = std::min(minV, vj[j][1]);
                        maxV = std::max(maxV, vj[j][1]);
                        sumU += vj[j][0];
                        sumV += vj[j][1];
                        n++;
                    }
                }
                if (n == 0)
                    continue;
                body.bbox[0] = (minU + maxU) * 0.5f;
                body.bbox[1] = (minV + maxV) * 0.5f;
                body.bbox[2] = maxU - minU;
                body.bbox[3] = maxV - minV;
                body.cx = (vj[vRoot][2] > 0.1f) ? vj[vRoot][0] : sumU / n;
                body.cy = (vj[vRoot][2] > 0.1f) ? vj[vRoot][1] : sumV / n;
                result.push_back(body);
            }
            CVPixelBufferRelease(buffer);
        }
        return result;
    }

    // 前フレームのスロットと最近傍マッチして body スロット/trackingid を維持する
    // （Body Track CHOP の People Tracking 相当の簡易版）
    void assignSlots(std::vector<Body>& detected)
    {
        constexpr float kMatchDist = 0.3f;
        bool used[kMaxBodies] = {};
        std::vector<bool> taken(detected.size(), false);
        Body next[kMaxBodies];

        // ① 既存スロットに近い検出を割り当て（距離昇順の貪欲マッチ）
        struct Cand { float d; int slot; int det; };
        std::vector<Cand> cands;
        for (int s = 0; s < kMaxBodies; s++) {
            if (!myTrackSlots[s].valid)
                continue;
            for (int d = 0; d < (int)detected.size(); d++) {
                const float du = myTrackSlots[s].cx - detected[d].cx;
                const float dv = myTrackSlots[s].cy - detected[d].cy;
                const float dist = std::sqrt(du * du + dv * dv);
                if (dist < kMatchDist)
                    cands.push_back({dist, s, d});
            }
        }
        std::sort(cands.begin(), cands.end(),
                  [](const Cand& a, const Cand& b) { return a.d < b.d; });
        for (const Cand& c : cands) {
            if (used[c.slot] || taken[c.det])
                continue;
            next[c.slot] = detected[c.det];
            next[c.slot].trackingId = myTrackSlots[c.slot].trackingId;
            used[c.slot] = true;
            taken[c.det] = true;
        }

        // ② 新規検出は空きスロットへ（新しい trackingid を発番）
        for (int d = 0; d < (int)detected.size(); d++) {
            if (taken[d])
                continue;
            for (int s = 0; s < kMaxBodies; s++) {
                if (!used[s]) {
                    next[s] = detected[d];
                    next[s].trackingId = ++myNextTrackingId;
                    used[s] = true;
                    break;
                }
            }
        }
        memcpy(myTrackSlots, next, sizeof(next));
    }

    // ---------------------------------------------------------- state

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;
    bool myHasPending = false;
    bool myBusy = false;
    OP_SmartRef<OP_TOPDownloadResult> myPending;
    Body mySlots[kMaxBodies];          // 共有（mutex 保護）
    Body myTrackSlots[kMaxBodies];     // ワーカー専用（トラッキング状態）
    int myNextTrackingId = 0;
    int64_t myLastCookSeen = -1;
    int myMaxBodies = kMaxBodies;
    bool myRotations = false;
    std::atomic<bool> myFlip{true};

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
    std::atomic<int> myLastW{0}, myLastH{0};
    std::atomic<int64_t> myLastSize{0};
};

}   // namespace

// ------------------------------------------------------------------ entry points

extern "C" {

DLLEXPORT void
FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Visionpose");
    info->customOPInfo.opLabel->setString("Vision Pose");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("VPS");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/VisionPose/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT CHOP_CPlusPlusBase*
CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new VisionPoseCHOP(info);
}

DLLEXPORT void
DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (VisionPoseCHOP*)instance;
}

}   // extern "C"
