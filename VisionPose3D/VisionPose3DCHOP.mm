// VisionPose3D CHOP — TouchDesigner カスタムオペレータ（macOS / Apple Vision）
//
// TOP パラメータで指定した映像から、**最も目立つ1人**の3Dボディポーズ
// （VNDetectHumanBodyPose3DRequest・macOS 14+・17関節）を推定して出力する。
// 2D複数人の VisionPose CHOP と対になる、単一人物・3D版。
//
// 出力チャンネル（91ch・1サンプル）:
//   valid                     検出できたか（1/0）
//   body:facing               体の向き（度・0=レンズを向く / ±90=真横 / ±180=背面）
//   body:pitch                前後の傾き（度・+=前傾＝お辞儀）
//   body:roll                 左右の傾き（度）
//   cam:distance              レンズ〜腰の距離（メートル・Camera FOV を設定すれば実寸）
//   cam:fov                   3D再構成に使われた水平画角（度）
//   {joint}:tx,ty,tz          17関節の3D位置（Space パラメータ基準・メートル・y上向き）
//   {joint}:u,v               17関節の入力画像への2D投影（0〜1・左下原点）
//
// cam:* は Space に関係なく常に同じ意味。全て "cam:" 始まりなので、関節だけ欲しいときは
// Select CHOP の `^*cam*` 一発で落とせる。Space=root のまま cam:t*/cam:r* を
// Camera COMP に挿すと、TD の視点が実カメラと一致する。
//
// Space パラメータ:
//   root（既定）  Vision そのまま。人物の腰が原点。人が跳んでも近づいても図は動かず、
//                 手足の形だけが変わる
//   camera        カメラを原点にした座標。人物が跳ぶ・前後に動くと図もそのまま動く
//
// cameraOriginMatrix の向きに注意（実測で確定）:
//   名前から「カメラの姿勢」に見えるが、実体は **model 空間 → カメラ空間** の変換。
//   カメラ基準の座標は `M * p` で得る。`inverse(M) * p` でも `p - t` でもない。
//   8フレームで検証: `M * p` を射影した (x/z, y/z) は Vision 自身が返す pointInImage と
//   **残差 0.00000（正規化画像座標）** で一致する。対して inverse(M) は 0.0266、
//   平行移動を引くだけは 0.0131 の残差が残る。
//   カメラ空間は -Z が前方（TD のカメラと同じ向き）なので、被写体は -Z 側に来る。
//
// bodyHeight / heightEstimation を出していない理由:
//   Vision は深度があれば実身長を返す（heightEstimation = measured）が、**深度は
//   `initWithCVPixelBuffer:depthData:...` で渡すもので、TOP は色しか運ばない**。
//   そのためこのオペレータでは永久に reference = 1.8m 固定になる（7クリップ44検出で
//   measured=0・bodyHeight=1.8000 を実測）。常に同じ値しか出ないチャンネルは出さない。
//   なお macOS でも深度入力自体は可能（上記 init は macos 14.0+）なので、深度を運ぶ
//   入力経路を足せば measured にできる。「Macだから無理」ではなく「TOP入力だから無理」
//
// 実装: cook のたびに TOP を非同期ダウンロードし、ワーカースレッドが
// Vision 推定 → 結果を保存。cook は最新結果を出力するだけ（1〜2フレーム遅れ）。

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>
#import <simd/simd.h>

#include "../common/AspectCoords.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>

#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

constexpr int kNumJoints = 17;

// 関節以外の固定チャンネル。カメラ系は全て "cam:" 始まりにしてあるので、
// 関節だけ欲しいときは Select CHOP の `^*cam*` 一発で落とせる
static const char* kFixedNames[] = {
    "valid",
    "body:facing",    // 体の向き（度・0=レンズを向く / ±90=真横 / ±180=背面）
    "body:pitch",     // 前後の傾き（度・+=お辞儀の向きに前傾）
    "body:roll",      // 左右の傾き（度・+=左肩側へ傾く）
    "cam:distance",   // レンズ〜腰の距離（メートル）
    "cam:fov",        // 3D再構成に使われた水平画角（度）
};
constexpr int kFixedChans = (int)(sizeof(kFixedNames) / sizeof(kFixedNames[0]));

// チャンネル名（Vision の関節名を snake_case で）
static const char* kJointNames[kNumJoints] = {
    "root", "spine", "center_shoulder", "center_head", "top_head",
    "left_shoulder", "left_elbow", "left_wrist",
    "right_shoulder", "right_elbow", "right_wrist",
    "left_hip", "left_knee", "left_ankle",
    "right_hip", "right_knee", "right_ankle",
};

API_AVAILABLE(macos(14.0))
static VNHumanBodyPose3DObservationJointName JointKey(int i)
{
    switch (i) {
        case 0: return VNHumanBodyPose3DObservationJointNameRoot;
        case 1: return VNHumanBodyPose3DObservationJointNameSpine;
        case 2: return VNHumanBodyPose3DObservationJointNameCenterShoulder;
        case 3: return VNHumanBodyPose3DObservationJointNameCenterHead;
        case 4: return VNHumanBodyPose3DObservationJointNameTopHead;
        case 5: return VNHumanBodyPose3DObservationJointNameLeftShoulder;
        case 6: return VNHumanBodyPose3DObservationJointNameLeftElbow;
        case 7: return VNHumanBodyPose3DObservationJointNameLeftWrist;
        case 8: return VNHumanBodyPose3DObservationJointNameRightShoulder;
        case 9: return VNHumanBodyPose3DObservationJointNameRightElbow;
        case 10: return VNHumanBodyPose3DObservationJointNameRightWrist;
        case 11: return VNHumanBodyPose3DObservationJointNameLeftHip;
        case 12: return VNHumanBodyPose3DObservationJointNameLeftKnee;
        case 13: return VNHumanBodyPose3DObservationJointNameLeftAnkle;
        case 14: return VNHumanBodyPose3DObservationJointNameRightHip;
        case 15: return VNHumanBodyPose3DObservationJointNameRightKnee;
        default: return VNHumanBodyPose3DObservationJointNameRightAnkle;
    }
}

struct Pose3D
{
    bool valid = false;
    float joints[kNumJoints][5] = {};   // tx, ty, tz（root 基準）, u, v
    // model（root 基準）→ カメラ基準 に移す行列（= cameraOriginMatrix そのもの）。
    // Space=camera のときだけ使う
    simd_float4x4 toCamera = matrix_identity_float4x4;
};

class VisionPose3DCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit VisionPose3DCHOP(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionPose3DCHOP() override
    {
        {
            std::lock_guard<std::mutex> lock(myMutex);
            myQuit = true;
        }
        myCond.notify_all();
        if (myWorker.joinable())
            myWorker.join();
    }

    // body:* と cam:* を埋める。
    //
    // **Vision は関節の回転を返さない**。`VNHumanBodyRecognizedPoint3D.position` /
    // `localPosition` は simd_float4x4 だが、3x3 部分は実測で**完全に単位行列**
    // （非対角成分の合計 0.0000・det 1.0）。つまり中身は平行移動だけ。
    // そこで体幹の向きは関節位置から自前で組む。
    //
    // 体の座標系: right = 右肩→左肩 / fwd = right × up（胸の法線）/ up = 世界の上。
    // pitch と roll をこの体自身の枠で測るので、**どちらを向いていても
    // 「前に曲げた」「横に傾けた」が同じ意味**になる。
    static void fillBodyChannels(const Pose3D& pose, float* out)
    {
        const simd_float4x4& M = pose.toCamera;
        const float deg = 180.0f / (float)M_PI;

        auto camPos = [&](int j) {
            const simd_float4 c = simd_mul(M, simd_make_float4(pose.joints[j][0],
                                                               pose.joints[j][1],
                                                               pose.joints[j][2], 1.0f));
            return simd_make_float3(c.x, c.y, c.z);
        };
        const simd_float3 lsh = camPos(5), rsh = camPos(8);
        const simd_float3 root = camPos(0), cshoulder = camPos(2);

        const simd_float3 up = simd_make_float3(0, 1, 0);
        const simd_float3 shoulder = lsh - rsh;
        const simd_float3 fwd = simd_cross(shoulder, up);
        const simd_float3 torso = cshoulder - root;

        if (simd_length(shoulder) > 1e-6f && simd_length(fwd) > 1e-6f) {
            const simd_float3 r = simd_normalize(shoulder);
            const simd_float3 f = simd_normalize(fwd);
            // atan2 なので ±180 度まで表せる（Euler 分解の asin だと ±90 で頭打ちになり、
            // 実際に「全編後ろ姿」の映像で正面/背面を区別できなかった）
            out[0] = atan2f(f.x, f.z) * deg;
            out[1] = atan2f(simd_dot(torso, f), simd_dot(torso, up)) * deg;
            out[2] = atan2f(simd_dot(torso, r), simd_dot(torso, up)) * deg;
        }

        // 腰をレンズから見た位置（= M * 原点）。被写体は -Z 側
        const simd_float3 s = simd_make_float3(M.columns[3].x, M.columns[3].y, M.columns[3].z);
        out[3] = simd_length(s);

        // Vision が内部で使っている画角。u = 0.5 + fx*(x/-z) が厳密に成り立つので
        // （残差 0.00000 を実測済み）、原点を通る最小二乗で fx を逆算して角度に直す
        double num = 0.0, den = 0.0;
        for (int j = 0; j < kNumJoints; j++) {
            const simd_float3 c = camPos(j);
            if (fabsf(c.z) < 1e-6f)
                continue;
            const double ratio = c.x / -c.z;
            num += (pose.joints[j][3] - 0.5) * ratio;
            den += ratio * ratio;
        }
        out[4] = (den > 1e-9) ? (float)(2.0 * atan(0.5 / (num / den)) * 180.0 / M_PI) : 0.0f;
    }

    void getGeneralInfo(CHOP_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
        ginfo->timeslice = false;
    }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override
    {
        info->numChannels = kFixedChans + kNumJoints * 5;
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t index, OP_String* name, const OP_Inputs*, void*) override
    {
        char buf[80];
        if (index < kFixedChans) {
            snprintf(buf, sizeof(buf), "%s", kFixedNames[index]);
        } else {
            const int j = (index - kFixedChans) / 5;
            const int c = (index - kFixedChans) % 5;
            const char* f[5] = {"tx", "ty", "tz", "u", "v"};
            snprintf(buf, sizeof(buf), "%s:%s", kJointNames[j], f[c]);
        }
        name->setString(buf);
    }

    void execute(CHOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        myFlip = inputs->getParInt("Flip") != 0;
        const float fov = (float)inputs->getParDouble("Fov");
        if (fov != myFov.load()) {
            myFov = fov;
            myLastCookSeen = -1;      // 静止画入力でも撮り直させる
        }
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

        Pose3D pose;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            pose = myPose;
        }
        const tdaspect::Mapper map{ inputs->getParInt("Aspectcorrectuv") != 0,
                                    top ? (float)top->textureDesc.width  : 0.0f,
                                    top ? (float)top->textureDesc.height : 0.0f };
        // cam:* は Space に関係なく常に同じ意味。関節だけ Space に従う
        const bool toCam = inputs->getParInt("Space") != 0;
        const bool on = active && pose.valid;
        float fixed[kFixedChans] = {};
        fixed[0] = on ? 1.0f : 0.0f;
        if (on)
            fillBodyChannels(pose, fixed + 1);
        for (int i = 0; i < kFixedChans; i++)
            output->channels[i][0] = fixed[i];
        for (int j = 0; j < kNumJoints; j++) {
            simd_float3 p = simd_make_float3(pose.joints[j][0], pose.joints[j][1], pose.joints[j][2]);
            if (toCam) {
                const simd_float4 q = simd_mul(pose.toCamera, simd_make_float4(p.x, p.y, p.z, 1.0f));
                p = simd_make_float3(q.x, q.y, q.z);
            }
            // tx,ty,tz はメートル単位なので変換しない。u,v（投影座標）のみ再スケール
            for (int c = 0; c < 3; c++)
                output->channels[kFixedChans + j * 5 + c][0] = on ? p[c] : 0.0f;
            output->channels[kFixedChans + j * 5 + 3][0] = on ? map.x(pose.joints[j][3]) : 0.0f;
            output->channels[kFixedChans + j * 5 + 4][0] = on ? map.y(pose.joints[j][4]) : 0.0f;
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        // uv を入力画像のアスペクト比へ再スケール（Body Track CHOP と同名・同既定）
        tdaspect::appendAspectCorrect<OP_ParameterManager, OP_NumericParameter>(manager, "Vision Pose 3D");
        {
            OP_StringParameter p("Top");
            p.label = "TOP";
            p.page = "Vision Pose 3D";
            manager->appendTOP(p);
        }
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Vision Pose 3D";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            // 実カメラの水平画角。0 なら Vision の既定（98.8度の広角仮定）のまま
            OP_NumericParameter p("Fov");
            p.label = "Camera FOV (deg, 0 = auto)";
            p.page = "Vision Pose 3D";
            p.defaultValues[0] = 0.0;
            p.minValues[0] = 0.0;      p.minSliders[0] = 0.0;
            p.maxValues[0] = 150.0;    p.maxSliders[0] = 150.0;
            p.clampMins[0] = true;     p.clampMaxes[0] = true;
            manager->appendFloat(p);
        }
        {
            // 関節座標の基準。root=Vision そのまま（腰が原点）/ camera=カメラが原点
            OP_StringParameter p("Space");
            p.label = "Coordinate Space";
            p.page = "Vision Pose 3D";
            p.defaultValue = "root";
            const char* names[2]  = {"root", "camera"};
            const char* labels[2] = {"Root (hips at origin)", "Camera at origin"};
            manager->appendMenu(p, 2, const_cast<const char**>(names), const_cast<const char**>(labels));
        }
        {
            // TD の TOP ダウンロードは GL 系の上下逆（bottom-up）なので既定でフリップする
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "Vision Pose 3D";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[4] = {"executes", "submits", "analyzes", "analyze_ms"};
        float values[4] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           (float)myAnalyzeMs};
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
            Pose3D pose;
            const double t0 = CFAbsoluteTimeGetCurrent();
            analyze(download, pose);
            myAnalyzeMs = (int)((CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                myPose = pose;
                myBusy = false;
            }
        }
    }

    void analyze(OP_SmartRef<OP_TOPDownloadResult>& download, Pose3D& out)
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
                CVPixelBufferRef buffer = nullptr;
                CVPixelBufferCreateWithBytes(nullptr, w, h, kCVPixelFormatType_32BGRA,
                                             data, w * 4, nullptr, nullptr, nullptr, &buffer);
                if (!buffer)
                    return;

                // リクエストはワーカーで使い回す。毎フレーム作り直すと1割ほど遅い
                // (実測 182ms → 166ms)。ハンドラは画像ごとに必要なので毎回作る
                if (!myRequest)
                    myRequest = [[VNDetectHumanBodyPose3DRequest alloc] init];
                VNDetectHumanBodyPose3DRequest* request = myRequest;

                // **連続フレームとして渡すか、1枚ずつ渡すか** — 両立できないので切り替える。
                //
                //  Camera FOV = 0 … VNSequenceRequestHandler。時間方向の手掛かりが効いて
                //      検出率 56/60 → 60/60、体の向きが180度反転する頻度 18% → 2% になる（3クリップ実測）
                //  Camera FOV > 0 … VNImageRequestHandler + options。**intrinsics を受け付けるのは
                //      この経路だけ**（CMSampleBuffer の attachment 経由は両ハンドラとも無視される
                //      ことを実測で確認: 40度/90度を渡しても復元値は 98.824 のまま）。
                //      距離は正しくなるが、1枚ずつなので向きは不安定になる
                const float fovDeg = myFov.load();
                if (fovDeg > 1.0f) {
                    const float fx = (w * 0.5f) / tanf(fovDeg * (float)M_PI / 360.0f);
                    const simd_float3x3 K = simd_matrix(simd_make_float3(fx, 0, 0),
                                                        simd_make_float3(0, fx, 0),
                                                        simd_make_float3(w * 0.5f, h * 0.5f, 1));
                    VNImageRequestHandler* handler = [[VNImageRequestHandler alloc]
                        initWithCVPixelBuffer:buffer
                                      options:@{ VNImageOptionCameraIntrinsics:
                                                     [NSData dataWithBytes:&K length:sizeof(K)] }];
                    [handler performRequests:@[request] error:nil];
                } else {
                    if (!mySequence)
                        mySequence = [[VNSequenceRequestHandler alloc] init];
                    [mySequence performRequests:@[request] onCVPixelBuffer:buffer error:nil];
                }

                VNHumanBodyPose3DObservation* obs = request.results.firstObject;
                if (obs) {
                    out.valid = true;
                    const simd_float4x4 cam = obs.cameraOriginMatrix;
                    out.toCamera = cam;   // model → camera。逆行列ではない（上のコメント参照）

                    for (int j = 0; j < kNumJoints; j++) {
                        VNHumanBodyRecognizedPoint3D* pt =
                            [obs recognizedPointForJointName:JointKey(j) error:nil];
                        if (pt) {
                            const simd_float4x4 m = pt.position;
                            out.joints[j][0] = m.columns[3].x;
                            out.joints[j][1] = m.columns[3].y;
                            out.joints[j][2] = m.columns[3].z;
                        }
                        VNPoint* p2 = [obs pointInImageForJointName:JointKey(j) error:nil];
                        if (p2) {
                            out.joints[j][3] = (float)p2.x;
                            out.joints[j][4] = (float)p2.y;
                        }
                    }
                }
                CVPixelBufferRelease(buffer);
            }
        }
    }

    // ---------------------------------------------------------- state

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;
    bool myHasPending = false;
    bool myBusy = false;
    OP_SmartRef<OP_TOPDownloadResult> myPending;
    Pose3D myPose;
    int64_t myLastCookSeen = -1;
    std::atomic<bool> myFlip{true};

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
    std::atomic<int> myAnalyzeMs{0};

    // ワーカー専用。使い回して初期化コストを避ける
    VNDetectHumanBodyPose3DRequest* myRequest API_AVAILABLE(macos(14.0)) = nil;
    VNSequenceRequestHandler* mySequence = nil;   // 連続フレームとして扱うため常設
    std::atomic<float> myFov{0.0f};   // 実カメラの水平画角（0=Vision既定）
};

}   // namespace

// ------------------------------------------------------------------ entry points

extern "C" {

DLLEXPORT void
FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Visionpose3d");
    info->customOPInfo.opLabel->setString("Vision Pose 3D");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("VPD");if(info->customOPInfo.opHelpURL)info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/VisionPose3D/README.md");   // アイコンは英字のみ(数字はTD起動時の検証で弾かれる)
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT CHOP_CPlusPlusBase*
CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new VisionPose3DCHOP(info);
}

DLLEXPORT void
DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (VisionPose3DCHOP*)instance;
}

}   // extern "C"
