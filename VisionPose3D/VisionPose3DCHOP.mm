// VisionPose3D CHOP — TouchDesigner カスタムオペレータ（macOS / Apple Vision）
//
// TOP パラメータで指定した映像から、**最も目立つ1人**の3Dボディポーズ
// （VNDetectHumanBodyPose3DRequest・macOS 14+・17関節）を推定して出力する。
// 2D複数人の VisionPose CHOP と対になる、単一人物・3D版。
//
// 出力チャンネル（91ch・1サンプル）:
//   valid                     検出できたか（1/0）
//   bodyheight                推定身長（メートル）
//   heightestimation          0=reference（既定身長で推定）/ 1=measured（実測）
//   camera:tx,ty,tz           カメラ位置（シーン原点=人物 root 基準・メートル）
//   {joint}:tx,ty,tz          17関節の3D位置（シーン原点基準・メートル・y上向き）
//   {joint}:u,v               17関節の入力画像への2D投影（0〜1・左下原点）
//
// 実装: cook のたびに TOP を非同期ダウンロードし、ワーカースレッドが
// Vision 推定 → 結果を保存。cook は最新結果を出力するだけ（1〜2フレーム遅れ）。

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>
#import <simd/simd.h>

#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>

#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

constexpr int kNumJoints = 17;

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
    float bodyHeight = 0;
    float heightMeasured = 0;      // 1=measured / 0=reference
    float camera[3] = {};          // カメラ位置（tx,ty,tz）
    float joints[kNumJoints][5] = {};   // tx, ty, tz, u, v
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

    void getGeneralInfo(CHOP_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
        ginfo->timeslice = false;
    }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override
    {
        info->numChannels = 6 + kNumJoints * 5;
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t index, OP_String* name, const OP_Inputs*, void*) override
    {
        char buf[80];
        if (index == 0) {
            snprintf(buf, sizeof(buf), "valid");
        } else if (index == 1) {
            snprintf(buf, sizeof(buf), "bodyheight");
        } else if (index == 2) {
            snprintf(buf, sizeof(buf), "heightestimation");
        } else if (index <= 5) {
            const char* axis[3] = {"tx", "ty", "tz"};
            snprintf(buf, sizeof(buf), "camera:%s", axis[index - 3]);
        } else {
            const int j = (index - 6) / 5;
            const int c = (index - 6) % 5;
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
        const bool on = active && pose.valid;
        output->channels[0][0] = on ? 1.0f : 0.0f;
        output->channels[1][0] = on ? pose.bodyHeight : 0.0f;
        output->channels[2][0] = on ? pose.heightMeasured : 0.0f;
        for (int c = 0; c < 3; c++)
            output->channels[3 + c][0] = on ? pose.camera[c] : 0.0f;
        for (int j = 0; j < kNumJoints; j++)
            for (int c = 0; c < 5; c++)
                output->channels[6 + j * 5 + c][0] = on ? pose.joints[j][c] : 0.0f;
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
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

                VNDetectHumanBodyPose3DRequest* request =
                    [[VNDetectHumanBodyPose3DRequest alloc] init];
                VNImageRequestHandler* handler =
                    [[VNImageRequestHandler alloc] initWithCVPixelBuffer:buffer options:@{}];
                [handler performRequests:@[request] error:nil];

                VNHumanBodyPose3DObservation* obs = request.results.firstObject;
                if (obs) {
                    out.valid = true;
                    out.bodyHeight = (float)obs.bodyHeight;
                    out.heightMeasured =
                        (obs.heightEstimation == VNHumanBodyPose3DObservationHeightEstimationMeasured)
                            ? 1.0f : 0.0f;
                    const simd_float4x4 cam = obs.cameraOriginMatrix;
                    out.camera[0] = cam.columns[3].x;
                    out.camera[1] = cam.columns[3].y;
                    out.camera[2] = cam.columns[3].z;

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
    info->customOPInfo.opLabel->setString("Apple Vision Pose 3D");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("VPD");   // アイコンは英字のみ(数字はTD起動時の検証で弾かれる)
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
