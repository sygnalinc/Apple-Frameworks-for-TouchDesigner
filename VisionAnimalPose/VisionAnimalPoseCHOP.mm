// VisionAnimalPose CHOP — multi-animal 2D body pose via Apple Vision (macOS 14+).

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

constexpr int kMaxAnimals = 100;
constexpr int kNumJoints = 25;

static const char* kJointNames[kNumJoints] = {
    "left_ear_top", "right_ear_top", "left_ear_middle", "right_ear_middle",
    "left_ear_bottom", "right_ear_bottom", "left_eye", "right_eye", "nose", "neck",
    "left_front_elbow", "right_front_elbow", "left_front_knee", "right_front_knee",
    "left_front_paw", "right_front_paw", "left_back_elbow", "right_back_elbow",
    "left_back_knee", "right_back_knee", "left_back_paw", "right_back_paw",
    "tail_top", "tail_middle", "tail_bottom"
};

static VNAnimalBodyPoseObservationJointName jointKey(int i)
{
    switch (i) {
        case 0: return VNAnimalBodyPoseObservationJointNameLeftEarTop;
        case 1: return VNAnimalBodyPoseObservationJointNameRightEarTop;
        case 2: return VNAnimalBodyPoseObservationJointNameLeftEarMiddle;
        case 3: return VNAnimalBodyPoseObservationJointNameRightEarMiddle;
        case 4: return VNAnimalBodyPoseObservationJointNameLeftEarBottom;
        case 5: return VNAnimalBodyPoseObservationJointNameRightEarBottom;
        case 6: return VNAnimalBodyPoseObservationJointNameLeftEye;
        case 7: return VNAnimalBodyPoseObservationJointNameRightEye;
        case 8: return VNAnimalBodyPoseObservationJointNameNose;
        case 9: return VNAnimalBodyPoseObservationJointNameNeck;
        case 10: return VNAnimalBodyPoseObservationJointNameLeftFrontElbow;
        case 11: return VNAnimalBodyPoseObservationJointNameRightFrontElbow;
        case 12: return VNAnimalBodyPoseObservationJointNameLeftFrontKnee;
        case 13: return VNAnimalBodyPoseObservationJointNameRightFrontKnee;
        case 14: return VNAnimalBodyPoseObservationJointNameLeftFrontPaw;
        case 15: return VNAnimalBodyPoseObservationJointNameRightFrontPaw;
        case 16: return VNAnimalBodyPoseObservationJointNameLeftBackElbow;
        case 17: return VNAnimalBodyPoseObservationJointNameRightBackElbow;
        case 18: return VNAnimalBodyPoseObservationJointNameLeftBackKnee;
        case 19: return VNAnimalBodyPoseObservationJointNameRightBackKnee;
        case 20: return VNAnimalBodyPoseObservationJointNameLeftBackPaw;
        case 21: return VNAnimalBodyPoseObservationJointNameRightBackPaw;
        case 22: return VNAnimalBodyPoseObservationJointNameTailTop;
        case 23: return VNAnimalBodyPoseObservationJointNameTailMiddle;
        default: return VNAnimalBodyPoseObservationJointNameTailBottom;
    }
}

struct Animal
{
    float bbox[4] = {}; // center u/v, width/height
    float joints[kNumJoints][3] = {};
};

class VisionAnimalPoseCHOP final : public CHOP_CPlusPlusBase
{
public:
    explicit VisionAnimalPoseCHOP(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionAnimalPoseCHOP() override
    {
        {
            std::lock_guard<std::mutex> lock(myMutex);
            myQuit = true;
        }
        myCond.notify_all();
        if (myWorker.joinable()) myWorker.join();
    }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrameIfAsked = true;
        g->timeslice = false;
    }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs* inputs, void*) override
    {
        myMaxAnimals = std::clamp(inputs->getParInt("Maxanimals"), 1, kMaxAnimals);
        info->numChannels = myMaxAnimals * (5 + kNumJoints * 3);
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t index, OP_String* name, const OP_Inputs*, void*) override
    {
        constexpr int per = 5 + kNumJoints * 3;
        const int animal = index / per + 1;
        const int local = index % per;
        char buffer[96];
        if (local == 0)
            snprintf(buffer, sizeof(buffer), "animal%d:valid", animal);
        else if (local < 5) {
            const char* fields[] = {"u", "v", "w", "h"};
            snprintf(buffer, sizeof(buffer), "animal%d/bbox:%s", animal, fields[local - 1]);
        } else {
            const int joint = (local - 5) / 3;
            const char* fields[] = {"u", "v", "confidence"};
            snprintf(buffer, sizeof(buffer), "animal%d/%s:%s", animal, kJointNames[joint],
                     fields[(local - 5) % 3]);
        }
        name->setString(buffer);
    }

    void execute(CHOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        const bool flip = inputs->getParInt("Flip") != 0;
        const float minConfidence = (float)inputs->getParDouble("Minconfidence");
        const std::string signature = std::to_string(minConfidence) + (flip ? ":1" : ":0");
        if (signature != mySignature) {
            mySignature = signature;
            myLastCookSeen = -1;
        }
        const OP_TOPInput* top = inputs->getParTOP("Top");
        if (active && top && (int64_t)top->totalCooks != myLastCookSeen) {
            std::unique_lock<std::mutex> lock(myMutex, std::try_to_lock);
            if (lock.owns_lock() && !myHasPending && !myBusy) {
                OP_TOPInputDownloadOptions options;
                options.pixelFormat = OP_PixelFormat::BGRA8Fixed;
                options.verticalFlip = flip;
                myPending = top->downloadTexture(options, nullptr);
                if (myPending) {
                    myPendingMinConfidence = minConfidence;
                    myHasPending = true;
                    mySubmitCount++;
                    myLastCookSeen = top->totalCooks;
                    lock.unlock();
                    myCond.notify_one();
                }
            }
        }

        std::vector<Animal> animals;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            animals = myAnimals;
        }
        constexpr int per = 5 + kNumJoints * 3;
        for (int a = 0; a < myMaxAnimals; ++a) {
            const bool valid = active && a < (int)animals.size();
            const Animal* animal = valid ? &animals[a] : nullptr;
            const int base = a * per;
            output->channels[base][0] = valid ? 1.0f : 0.0f;
            for (int i = 0; i < 4; ++i)
                output->channels[base + 1 + i][0] = valid ? animal->bbox[i] : 0.0f;
            for (int j = 0; j < kNumJoints; ++j)
                for (int f = 0; f < 3; ++f)
                    output->channels[base + 5 + j * 3 + f][0] =
                        valid ? animal->joints[j][f] : 0.0f;
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        OP_StringParameter top("Top"); top.label = "TOP"; top.page = "Vision Animal Pose";
        manager->appendTOP(top);
        OP_NumericParameter active("Active"); active.label = "Active"; active.page = "Vision Animal Pose";
        active.defaultValues[0] = 1; manager->appendToggle(active);
        OP_NumericParameter max("Maxanimals"); max.label = "Max Animals"; max.page = "Vision Animal Pose";
        max.defaultValues[0] = 4; max.minSliders[0] = 1; max.maxSliders[0] = 10;
        max.minValues[0] = 1; max.maxValues[0] = kMaxAnimals;
        max.clampMins[0] = true; max.clampMaxes[0] = true; manager->appendInt(max);
        OP_NumericParameter conf("Minconfidence"); conf.label = "Minimum Joint Confidence";
        conf.page = "Vision Animal Pose"; conf.defaultValues[0] = 0.1;
        conf.minSliders[0] = 0; conf.maxSliders[0] = 1; conf.minValues[0] = 0;
        conf.maxValues[0] = 1; conf.clampMins[0] = true; conf.clampMaxes[0] = true;
        manager->appendFloat(conf);
        OP_NumericParameter flip("Flip"); flip.label = "Flip Image Vertically";
        flip.page = "Vision Animal Pose"; flip.defaultValues[0] = 1; manager->appendToggle(flip);
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        const char* names[] = {"executes", "submits", "analyzes", "analyze_ms", "animals"};
        int count;
        { std::lock_guard<std::mutex> lock(myMutex); count = (int)myAnimals.size(); }
        float values[] = {(float)myExecCount.load(), (float)mySubmitCount.load(),
                          (float)myAnalyzeCount.load(), myAnalyzeMs.load(), (float)count};
        c->name->setString(names[i]); c->value = values[i];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (!myWarning.empty()) warning->setString(myWarning.c_str());
    }

private:
    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            float minConfidence;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit) return;
                download = std::move(myPending);
                minConfidence = myPendingMinConfidence;
                myHasPending = false; myBusy = true;
            }
            std::vector<Animal> result;
            std::string warning;
            const auto start = std::chrono::steady_clock::now();
            analyze(download, minConfidence, result, warning);
            myAnalyzeMs = std::chrono::duration<float, std::milli>(
                std::chrono::steady_clock::now() - start).count();
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                myAnimals = std::move(result); myWarning = std::move(warning); myBusy = false;
            }
        }
    }

    static void analyze(OP_SmartRef<OP_TOPDownloadResult>& download, float minConfidence,
                        std::vector<Animal>& result, std::string& warning)
    {
        if (!download) return;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width, h = download->textureDesc.height;
        if (!data || !w || !h) return;
        @autoreleasepool {
            if (@available(macOS 14.0, *)) {
                CVPixelBufferRef pixel = nullptr;
                CVPixelBufferCreateWithBytes(nullptr, w, h, kCVPixelFormatType_32BGRA, data,
                                             (size_t)w * 4, nullptr, nullptr, nullptr, &pixel);
                if (!pixel) return;
                VNDetectAnimalBodyPoseRequest* request = [VNDetectAnimalBodyPoseRequest new];
                request.revision = VNDetectAnimalBodyPoseRequestRevision1;
                VNImageRequestHandler* handler =
                    [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixel options:@{}];
                NSError* error = nil;
                if ([handler performRequests:@[request] error:&error]) {
                    for (VNAnimalBodyPoseObservation* observation in request.results) {
                        Animal animal;
                        float minU = 1, minV = 1, maxU = 0, maxV = 0;
                        int visible = 0;
                        for (int j = 0; j < kNumJoints; ++j) {
                            VNRecognizedPoint* point =
                                [observation recognizedPointForJointName:jointKey(j) error:nil];
                            if (!point || point.confidence < minConfidence) continue;
                            const float u = point.location.x, v = point.location.y;
                            animal.joints[j][0] = u; animal.joints[j][1] = v;
                            animal.joints[j][2] = point.confidence;
                            minU = std::min(minU, u); minV = std::min(minV, v);
                            maxU = std::max(maxU, u); maxV = std::max(maxV, v); visible++;
                        }
                        if (!visible) continue;
                        animal.bbox[0] = (minU + maxU) * 0.5f;
                        animal.bbox[1] = (minV + maxV) * 0.5f;
                        animal.bbox[2] = maxU - minU; animal.bbox[3] = maxV - minV;
                        result.push_back(animal);
                    }
                    std::stable_sort(result.begin(), result.end(), [](const Animal& a, const Animal& b) {
                        return a.bbox[0] < b.bbox[0];
                    });
                } else if (error) warning = error.localizedDescription.UTF8String ?: "Animal pose failed";
                CVPixelBufferRelease(pixel);
            } else warning = "Vision Animal Pose requires macOS 14 or later";
        }
    }

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false, myHasPending = false, myBusy = false;
    OP_SmartRef<OP_TOPDownloadResult> myPending;
    std::vector<Animal> myAnimals;
    std::string myWarning, mySignature;
    int64_t myLastCookSeen = -1;
    int myMaxAnimals = 4;
    float myPendingMinConfidence = 0.1f;
    std::atomic<uint64_t> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
    std::atomic<float> myAnalyzeMs{0};
};

} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    info->customOPInfo.opType->setString("Visionanimalpose");
    info->customOPInfo.opLabel->setString("Vision Animal Pose");
    info->customOPInfo.opIcon->setString("VAP");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/VisionAnimalPose/README.md");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.minInputs = 0; info->customOPInfo.maxInputs = 0;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* info)
{ return new VisionAnimalPoseCHOP(info); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{ delete static_cast<VisionAnimalPoseCHOP*>(instance); }
}
