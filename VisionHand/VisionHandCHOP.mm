// VisionHand CHOP — 手指トラッキング（macOS / Apple Vision）
//
// TOP パラメータで指定した映像から複数の手の21関節
// （VNDetectHumanHandPoseRequest）を推定して出力する。
//
// 出力チャンネル（Max Hands = N のとき hand1..handN・各 65ch）:
//   hand{i}:valid                検出できたか（1/0）
//   hand{i}/chirality            -1=左手 / 1=右手 / 0=不明（映像に映った手の左右）
//   hand{i}/{joint}:u,v,confidence   21関節（0〜1・左下原点）
//
// hand の並びは手首の x 位置で左→右にソートする。
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

constexpr int kMaxHands = 100;
constexpr int kNumJoints = 21;

static const char* kJointNames[kNumJoints] = {
    "wrist",
    "thumb_cmc", "thumb_mp", "thumb_ip", "thumb_tip",
    "index_mcp", "index_pip", "index_dip", "index_tip",
    "middle_mcp", "middle_pip", "middle_dip", "middle_tip",
    "ring_mcp", "ring_pip", "ring_dip", "ring_tip",
    "little_mcp", "little_pip", "little_dip", "little_tip",
};

static VNRecognizedPointKey JointKey(int i)
{
    switch (i) {
        case 0: return VNHumanHandPoseObservationJointNameWrist;
        case 1: return VNHumanHandPoseObservationJointNameThumbCMC;
        case 2: return VNHumanHandPoseObservationJointNameThumbMP;
        case 3: return VNHumanHandPoseObservationJointNameThumbIP;
        case 4: return VNHumanHandPoseObservationJointNameThumbTip;
        case 5: return VNHumanHandPoseObservationJointNameIndexMCP;
        case 6: return VNHumanHandPoseObservationJointNameIndexPIP;
        case 7: return VNHumanHandPoseObservationJointNameIndexDIP;
        case 8: return VNHumanHandPoseObservationJointNameIndexTip;
        case 9: return VNHumanHandPoseObservationJointNameMiddleMCP;
        case 10: return VNHumanHandPoseObservationJointNameMiddlePIP;
        case 11: return VNHumanHandPoseObservationJointNameMiddleDIP;
        case 12: return VNHumanHandPoseObservationJointNameMiddleTip;
        case 13: return VNHumanHandPoseObservationJointNameRingMCP;
        case 14: return VNHumanHandPoseObservationJointNameRingPIP;
        case 15: return VNHumanHandPoseObservationJointNameRingDIP;
        case 16: return VNHumanHandPoseObservationJointNameRingTip;
        case 17: return VNHumanHandPoseObservationJointNameLittleMCP;
        case 18: return VNHumanHandPoseObservationJointNameLittlePIP;
        case 19: return VNHumanHandPoseObservationJointNameLittleDIP;
        default: return VNHumanHandPoseObservationJointNameLittleTip;
    }
}

struct Hand
{
    bool valid = false;
    float chirality = 0;                 // -1=左 / 1=右 / 0=不明
    float joints[kNumJoints][3] = {};    // u, v, conf
    float wristU = 0.5f;
};

class VisionHandCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit VisionHandCHOP(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionHandCHOP() override
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
        myMaxHands = std::max(1, std::min(kMaxHands, (int)inputs->getParInt("Maxhands")));
        info->numChannels = myMaxHands * (2 + kNumJoints * 3);
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t index, OP_String* name, const OP_Inputs*, void*) override
    {
        const int perHand = 2 + kNumJoints * 3;
        const int hand = index / perHand + 1;
        const int local = index % perHand;
        char buf[64];
        if (local == 0) {
            snprintf(buf, sizeof(buf), "hand%d:valid", hand);
        } else if (local == 1) {
            snprintf(buf, sizeof(buf), "hand%d/chirality", hand);
        } else {
            const int j = (local - 2) / 3;
            const char* f[3] = {"u", "v", "confidence"};
            snprintf(buf, sizeof(buf), "hand%d/%s:%s", hand, kJointNames[j], f[(local - 2) % 3]);
        }
        name->setString(buf);
    }

    void execute(CHOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        myFlip = inputs->getParInt("Flip") != 0;
        myWantHands = myMaxHands;
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

        std::vector<Hand> hands;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            hands = myHands;
        }
        const tdaspect::Mapper map{ inputs->getParInt("Aspectcorrectuv") != 0,
                                    top ? (float)top->textureDesc.width  : 0.0f,
                                    top ? (float)top->textureDesc.height : 0.0f };
        const int perHand = 2 + kNumJoints * 3;
        for (int h = 0; h < myMaxHands; h++) {
            const bool on = active && h < (int)hands.size() && hands[h].valid;
            const Hand& hand = (h < (int)hands.size()) ? hands[h] : myEmpty;
            const int base = h * perHand;
            output->channels[base + 0][0] = on ? 1.0f : 0.0f;
            output->channels[base + 1][0] = on ? hand.chirality : 0.0f;
            for (int j = 0; j < kNumJoints; j++) {
                const int jb = base + 2 + j * 3;
                output->channels[jb + 0][0] = on ? map.x(hand.joints[j][0]) : 0.0f;
                output->channels[jb + 1][0] = on ? map.y(hand.joints[j][1]) : 0.0f;
                output->channels[jb + 2][0] = on ? hand.joints[j][2] : 0.0f;
            }
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        // uv を入力画像のアスペクト比へ再スケール（Body Track CHOP と同名・同既定）
        tdaspect::appendAspectCorrect<OP_ParameterManager, OP_NumericParameter>(manager, "Vision Hand");
        {
            OP_StringParameter p("Top");
            p.label = "TOP";
            p.page = "Vision Hand";
            manager->appendTOP(p);
        }
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Vision Hand";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Maxhands");
            p.label = "Max Hands";
            p.page = "Vision Hand";
            p.defaultValues[0] = 4;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 10;
            p.minValues[0] = 1;
            p.maxValues[0] = kMaxHands;
            p.clampMins[0] = true;
            p.clampMaxes[0] = true;
            manager->appendInt(p);
        }
        {
            // TD の TOP ダウンロードは GL 系の上下逆（bottom-up）なので既定でフリップする
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "Vision Hand";
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
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            int wantHands;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                download = std::move(myPending);
                myHasPending = false;
                myBusy = true;
                wantHands = myWantHands;
            }
            std::vector<Hand> hands = analyze(download, wantHands);
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                myHands = std::move(hands);
                myBusy = false;
            }
        }
    }

    std::vector<Hand> analyze(OP_SmartRef<OP_TOPDownloadResult>& download, int wantHands)
    {
        std::vector<Hand> result;
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

            VNDetectHumanHandPoseRequest* request =
                [[VNDetectHumanHandPoseRequest alloc] init];
            request.maximumHandCount = wantHands;
            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCVPixelBuffer:buffer options:@{}];
            [handler performRequests:@[request] error:nil];

            for (VNHumanHandPoseObservation* obs in request.results) {
                NSDictionary<VNRecognizedPointKey, VNRecognizedPoint*>* points =
                    [obs recognizedPointsForGroupKey:VNRecognizedPointGroupKeyAll error:nil];
                if (!points)
                    continue;
                Hand hand;
                hand.valid = true;
                switch (obs.chirality) {
                    case VNChiralityLeft: hand.chirality = -1; break;
                    case VNChiralityRight: hand.chirality = 1; break;
                    default: hand.chirality = 0; break;
                }
                for (int j = 0; j < kNumJoints; j++) {
                    VNRecognizedPoint* pt = points[JointKey(j)];
                    if (pt) {
                        hand.joints[j][0] = (float)pt.location.x;
                        hand.joints[j][1] = (float)pt.location.y;
                        hand.joints[j][2] = (float)pt.confidence;
                    }
                }
                hand.wristU = hand.joints[0][0];
                result.push_back(hand);
            }
            CVPixelBufferRelease(buffer);
        }
        // 左→右で安定ソート（手首の x）
        std::stable_sort(result.begin(), result.end(),
                         [](const Hand& a, const Hand& b) { return a.wristU < b.wristU; });
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
    std::vector<Hand> myHands;
    Hand myEmpty;
    int64_t myLastCookSeen = -1;
    int myMaxHands = 4;
    int myWantHands = 4;
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
    info->customOPInfo.opType->setString("Visionhand");
    info->customOPInfo.opLabel->setString("Vision Hand");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("VHD");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/VisionHand/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT CHOP_CPlusPlusBase*
CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new VisionHandCHOP(info);
}

DLLEXPORT void
DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (VisionHandCHOP*)instance;
}

}   // extern "C"
