// VisionContours SOP — TouchDesigner custom operator (macOS / Apple Vision)
// Detects image contours asynchronously and emits one closed line primitive per contour.

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
#include <unordered_map>
#include <vector>

#include "SOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

struct ContourLine
{
    std::vector<simd_float2> points;
    int contourId = 0;
    int parentId = -1;
    int depth = 0;
};

struct ContourResult
{
    std::vector<ContourLine> lines;
    uint64_t serial = 0;
    int detected = 0;
};

struct AnalyzeSettings
{
    int maxContours = 100;
    int minPoints = 3;
    int maxPoints = 512;
    int maxDimension = 512;
    float contrast = 2.0f;
    float simplify = 0.0f;
    bool darkOnLight = true;
};

static std::string indexPathKey(NSIndexPath* path)
{
    std::string key;
    for (NSUInteger i = 0; i < path.length; ++i) {
        if (i)
            key += '/';
        key += std::to_string([path indexAtPosition:i]);
    }
    return key;
}

class VisionContoursSOP final : public SOP_CPlusPlusBase
{
public:
    VisionContoursSOP(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionContoursSOP() override
    {
        {
            std::lock_guard<std::mutex> lock(myMutex);
            myQuit = true;
        }
        myCond.notify_all();
        if (myWorker.joinable())
            myWorker.join();
    }

    void getGeneralInfo(SOP_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
        ginfo->directToGPU = false;
        ginfo->winding = SOP_Winding::CCW;
    }

    void execute(SOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        const bool flip = inputs->getParInt("Flip") != 0;
        AnalyzeSettings settings;
        settings.maxContours = std::clamp(inputs->getParInt("Maxcontours"), 1, 100);
        settings.minPoints = std::max(2, inputs->getParInt("Minpoints"));
        settings.maxPoints = std::max(2, inputs->getParInt("Maxpoints"));
        settings.maxDimension = std::max(64, inputs->getParInt("Maxdimension"));
        settings.contrast = std::max(0.0f, (float)inputs->getParDouble("Contrast"));
        settings.simplify = std::max(0.0f, (float)inputs->getParDouble("Simplify"));
        settings.darkOnLight = inputs->getParInt("Darkonlight") != 0;

        const std::string signature = std::to_string(settings.maxContours) + ":" +
            std::to_string(settings.minPoints) + ":" + std::to_string(settings.maxPoints) + ":" +
            std::to_string(settings.maxDimension) + ":" + std::to_string(settings.contrast) + ":" +
            std::to_string(settings.simplify) + ":" + (settings.darkOnLight ? "1" : "0") +
            (flip ? ":1" : ":0");
        if (signature != myParameterSignature) {
            myParameterSignature = signature;
            myLastCookSeen = -1;
        }

        const OP_TOPInput* top = inputs->getParTOP("Top");
        if (active && top && (int64_t)top->totalCooks != myLastCookSeen) {
            std::unique_lock<std::mutex> lock(myMutex, std::try_to_lock);
            if (lock.owns_lock() && !myHasPending && !myBusy) {
                OP_TOPInputDownloadOptions opts;
                opts.pixelFormat = OP_PixelFormat::BGRA8Fixed;
                opts.verticalFlip = flip;
                myPending = top->downloadTexture(opts, nullptr);
                if (myPending) {
                    myPendingSettings = settings;
                    myHasPending = true;
                    mySubmitCount++;
                    myLastCookSeen = top->totalCooks;
                    lock.unlock();
                    myCond.notify_one();
                }
            }
        }

        ContourResult result;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            result = myResult;
        }
        emitGeometry(output, result);
    }

    void executeVBO(SOP_VBOOutput*, const OP_Inputs*, void*) override {}

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        OP_StringParameter top("Top");
        top.label = "TOP";
        top.page = "Vision Contours";
        manager->appendTOP(top);

        OP_NumericParameter active("Active");
        active.label = "Active";
        active.page = "Vision Contours";
        active.defaultValues[0] = 1;
        manager->appendToggle(active);

        OP_NumericParameter maxc("Maxcontours");
        maxc.label = "Max Contours";
        maxc.page = "Vision Contours";
        maxc.defaultValues[0] = 100;
        maxc.minSliders[0] = 1;
        maxc.maxSliders[0] = 10;
        maxc.minValues[0] = 1;
        maxc.maxValues[0] = 100;
        maxc.clampMins[0] = true;
        maxc.clampMaxes[0] = true;
        manager->appendInt(maxc);

        OP_NumericParameter minp("Minpoints");
        minp.label = "Minimum Points";
        minp.page = "Vision Contours";
        minp.defaultValues[0] = 3;
        minp.minSliders[0] = 2;
        minp.maxSliders[0] = 50;
        minp.minValues[0] = 2;
        minp.clampMins[0] = true;
        manager->appendInt(minp);

        OP_NumericParameter maxp("Maxpoints");
        maxp.label = "Maximum Points per Contour";
        maxp.page = "Vision Contours";
        maxp.defaultValues[0] = 512;
        maxp.minSliders[0] = 8;
        maxp.maxSliders[0] = 1024;
        maxp.minValues[0] = 2;
        maxp.clampMins[0] = true;
        manager->appendInt(maxp);

        OP_NumericParameter dim("Maxdimension");
        dim.label = "Maximum Image Dimension";
        dim.page = "Vision Contours";
        dim.defaultValues[0] = 512;
        dim.minSliders[0] = 64;
        dim.maxSliders[0] = 2048;
        dim.minValues[0] = 64;
        dim.clampMins[0] = true;
        manager->appendInt(dim);

        OP_NumericParameter contrast("Contrast");
        contrast.label = "Contrast Adjustment";
        contrast.page = "Vision Contours";
        contrast.defaultValues[0] = 2.0;
        contrast.minSliders[0] = 0.0;
        contrast.maxSliders[0] = 4.0;
        contrast.minValues[0] = 0.0;
        contrast.clampMins[0] = true;
        manager->appendFloat(contrast);

        OP_NumericParameter simplify("Simplify");
        simplify.label = "Simplify Epsilon";
        simplify.page = "Vision Contours";
        simplify.defaultValues[0] = 0.0;
        simplify.minSliders[0] = 0.0;
        simplify.maxSliders[0] = 0.05;
        simplify.minValues[0] = 0.0;
        simplify.clampMins[0] = true;
        manager->appendFloat(simplify);

        OP_NumericParameter dark("Darkonlight");
        dark.label = "Detect Dark on Light";
        dark.page = "Vision Contours";
        dark.defaultValues[0] = 1;
        manager->appendToggle(dark);

        OP_NumericParameter flip("Flip");
        flip.label = "Flip Image Vertically";
        flip.page = "Vision Contours";
        flip.defaultValues[0] = 1;
        manager->appendToggle(flip);
    }

    int32_t getNumInfoCHOPChans(void*) override { return 7; }

    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[] = {"executes", "submits", "analyzes", "analyze_ms",
                               "detected", "contours", "points"};
        int contours = 0, points = 0, detected = 0;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            contours = (int)myResult.lines.size();
            detected = myResult.detected;
            for (const auto& line : myResult.lines)
                points += (int)line.points.size() + 1;
        }
        float values[] = {(float)myExecCount.load(), (float)mySubmitCount.load(),
                          (float)myAnalyzeCount.load(), myAnalyzeMs.load(), (float)detected,
                          (float)contours, (float)points};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (!myWarning.empty())
            warning->setString(myWarning.c_str());
    }

private:
    void emitGeometry(SOP_Output* output, const ContourResult& result)
    {
        std::vector<Position> positions;
        std::vector<int32_t> indices;
        std::vector<int32_t> sizes;
        std::vector<float> contourIds, parentIds, depths, closed;
        for (const auto& line : result.lines) {
            if (line.points.size() < 2)
                continue;
            const int32_t start = (int32_t)positions.size();
            for (const auto& p : line.points) {
                positions.emplace_back(p.x, p.y, 0.0f);
                contourIds.push_back((float)line.contourId);
                parentIds.push_back((float)line.parentId);
                depths.push_back((float)line.depth);
                closed.push_back(1.0f);
            }
            positions.emplace_back(line.points.front().x, line.points.front().y, 0.0f);
            contourIds.push_back((float)line.contourId);
            parentIds.push_back((float)line.parentId);
            depths.push_back((float)line.depth);
            closed.push_back(1.0f);
            const int32_t count = (int32_t)line.points.size() + 1;
            for (int32_t i = 0; i < count; ++i)
                indices.push_back(start + i);
            sizes.push_back(count);
        }
        if (positions.empty())
            return;
        output->addPoints(positions.data(), (int32_t)positions.size());
        SOP_CustomAttribData attr;
        attr.attribType = AttribType::Float;
        attr.numComponents = 1;
        attr.name = "contourid"; attr.floatData = contourIds.data();
        output->setCustomAttribute(&attr, (int32_t)positions.size());
        attr.name = "parentid"; attr.floatData = parentIds.data();
        output->setCustomAttribute(&attr, (int32_t)positions.size());
        attr.name = "depth"; attr.floatData = depths.data();
        output->setCustomAttribute(&attr, (int32_t)positions.size());
        attr.name = "closed"; attr.floatData = closed.data();
        output->setCustomAttribute(&attr, (int32_t)positions.size());
        output->addLines(indices.data(), sizes.data(), (int32_t)sizes.size());
        BoundingBox box(0.0f, 0.0f, 0.0f, 1.0f, 1.0f, 0.0f);
        output->setBoundingBox(box);
    }

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            AnalyzeSettings settings;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                download = std::move(myPending);
                settings = myPendingSettings;
                myHasPending = false;
                myBusy = true;
            }
            ContourResult result;
            std::string warning;
            const auto t0 = std::chrono::steady_clock::now();
            analyze(download, settings, result, warning);
            myAnalyzeMs = std::chrono::duration<float, std::milli>(
                std::chrono::steady_clock::now() - t0).count();
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                result.serial = ++mySerial;
                myResult = std::move(result);
                myWarning = std::move(warning);
                myBusy = false;
            }
        }
    }

    static void analyze(OP_SmartRef<OP_TOPDownloadResult>& download,
                        const AnalyzeSettings& settings, ContourResult& out,
                        std::string& warning)
    {
        if (!download)
            return;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || !w || !h)
            return;
        @autoreleasepool {
            CVPixelBufferRef pixel = nullptr;
            CVPixelBufferCreateWithBytes(nullptr, w, h, kCVPixelFormatType_32BGRA, data,
                                         (size_t)w * 4, nullptr, nullptr, nullptr, &pixel);
            if (!pixel) {
                warning = "Could not create input pixel buffer";
                return;
            }
            VNDetectContoursRequest* request = [VNDetectContoursRequest new];
            request.maximumImageDimension = (NSUInteger)settings.maxDimension;
            request.contrastAdjustment = settings.contrast;
            request.detectsDarkOnLight = settings.darkOnLight;
            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixel options:@{}];
            NSError* error = nil;
            const bool ok = [handler performRequests:@[request] error:&error];
            if (ok && request.results.count) {
                VNContoursObservation* observation = request.results.firstObject;
                out.detected = (int)observation.contourCount;
                const int count = std::min(settings.maxContours, (int)observation.contourCount);
                std::unordered_map<std::string, int> idsByPath;
                for (int i = 0; i < count; ++i) {
                    VNContour* contour = [observation contourAtIndex:i error:nil];
                    if (!contour)
                        continue;
                    if (settings.simplify > 0.0f) {
                        VNContour* simplified = [contour polygonApproximationWithEpsilon:settings.simplify
                                                                                    error:nil];
                        if (simplified)
                            contour = simplified;
                    }
                    const int pointCount = (int)contour.pointCount;
                    if (pointCount < settings.minPoints)
                        continue;
                    ContourLine line;
                    line.contourId = i;
                    line.depth = (int)contour.indexPath.length - 1;
                    std::string path = indexPathKey(contour.indexPath);
                    idsByPath[path] = i;
                    if (line.depth > 0) {
                        const size_t slash = path.rfind('/');
                        auto found = idsByPath.find(path.substr(0, slash));
                        if (found != idsByPath.end())
                            line.parentId = found->second;
                    }
                    const int kept = std::min(pointCount, settings.maxPoints);
                    line.points.reserve(kept);
                    const simd_float2* points = contour.normalizedPoints;
                    for (int j = 0; j < kept; ++j) {
                        const int source = (kept == pointCount) ? j
                            : std::min(pointCount - 1, (int)((int64_t)j * pointCount / kept));
                        line.points.push_back(points[source]);
                    }
                    out.lines.push_back(std::move(line));
                }
            } else if (error) {
                warning = error.localizedDescription.UTF8String ?: "Vision contour detection failed";
            }
            CVPixelBufferRelease(pixel);
        }
    }

    std::thread myWorker;
    std::condition_variable myCond;
    mutable std::mutex myMutex;
    bool myQuit = false, myHasPending = false, myBusy = false;
    OP_SmartRef<OP_TOPDownloadResult> myPending;
    AnalyzeSettings myPendingSettings;
    ContourResult myResult;
    std::string myWarning, myParameterSignature;
    int64_t myLastCookSeen = -1;
    uint64_t mySerial = 0;
    std::atomic<uint64_t> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
    std::atomic<float> myAnalyzeMs{0.0f};
};

} // namespace

extern "C" {

DLLEXPORT void FillSOPPluginInfo(SOP_PluginInfo* info)
{
    if (!info->setAPIVersion(SOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Visioncontours");
    info->customOPInfo.opLabel->setString("Apple Vision Contours");
    info->customOPInfo.opIcon->setString("VCS");
    info->customOPInfo.authorName->setString("TDAppleML");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT SOP_CPlusPlusBase* CreateSOPInstance(const OP_NodeInfo* info)
{
    return new VisionContoursSOP(info);
}

DLLEXPORT void DestroySOPInstance(SOP_CPlusPlusBase* instance)
{
    delete instance;
}

}
