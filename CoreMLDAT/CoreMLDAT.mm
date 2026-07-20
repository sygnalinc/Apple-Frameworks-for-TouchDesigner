// CoreML DAT — TouchDesigner カスタムオペレータ(macOS / Core ML + Vision)
//
// 任意の物体検出 Core ML モデル(YOLOv3 等)をロードし、入力 TOP の映像から
// 「何が・どこに」を検出してテーブル出力する汎用オペレータ。
// CoreML TOP は画像/配列出力モデル担当、本DATは検出モデル
// (VNRecognizedObjectObservation を返すもの)担当。
//
// 出力テーブル: rank / label / confidence / u / v / w / h
//   (u,v = bbox中心・w,h = サイズ。uv座標・左下原点 = VisionTrack と同じ規約)
//
// モデル入手例: https://huggingface.co/apple/coreml-YOLOv3 (YOLOv3Int8LUT.mlmodel 62MB)
//
// 実装: モデルロード(コンパイル込み)と推論はワーカースレッドで非同期。
// コンパイル結果は CoreML TOP と同じ ~/Library/Caches/TDAppleML/ に共有キャッシュ。

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreML/CoreML.h>
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

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

struct Detection
{
    std::string label;
    float confidence = 0;
    float u = 0, v = 0, w = 0, h = 0;   // 中心+サイズ(uv)
};

static std::string nsstr(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }

class CoreMLDAT final : public DAT_CPlusPlusBase
{
public:
    explicit CoreMLDAT(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~CoreMLDAT() override
    {
        {
            std::lock_guard<std::mutex> lock(myMutex);
            myQuit = true;
        }
        myCond.notify_all();
        if (myWorker.joinable())
            myWorker.join();
    }

    void getGeneralInfo(DAT_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        const bool flip = inputs->getParInt("Flip") != 0;
        const int maxDet = std::clamp((int)inputs->getParInt("Maxdetections"), 1, 100);
        const float minConf =
            std::clamp((float)inputs->getParDouble("Minconfidence"), 0.0f, 1.0f);

        const char* scale = inputs->getParString("Scaling");
        const int scaleOption = (strcmp(scale, "centercrop") == 0) ? 1
                              : (strcmp(scale, "scalefit") == 0)   ? 2 : 0;
        const char* cu = inputs->getParString("Computeunits");
        const int units = (strcmp(cu, "cpugpu") == 0)  ? 1
                        : (strcmp(cu, "cpuonly") == 0) ? 2
                        : (strcmp(cu, "cpuane") == 0)  ? 3 : 0;
        std::string path;
        if (const char* p = inputs->getParString("Modelfile"))
            path = p;

        // モデルパス/計算ユニット変更でロード依頼、処理系パラメータ変更で再解析
        {
            std::lock_guard<std::mutex> lock(myMutex);
            if ((path != myRequestedPath || units != myRequestedUnits || myForceReload)
                && !path.empty()) {
                myRequestedPath = path;
                myRequestedUnits = units;
                myForceReload = false;
                myNeedLoad = true;
                myCond.notify_one();
            }
        }
        char sigbuf[64];
        snprintf(sigbuf, sizeof(sigbuf), "%d:%.3f:%d:%d", maxDet, minConf, scaleOption,
                 flip ? 1 : 0);
        if (mySignature != sigbuf) {
            mySignature = sigbuf;
            myLastCookSeen = -1;
        }

        const OP_TOPInput* top = inputs->getParTOP("Top");
        if (active && top && top->totalCooks != myLastCookSeen) {
            std::unique_lock<std::mutex> lock(myMutex, std::try_to_lock);
            if (lock.owns_lock() && !myHasPending && !myBusy && myModelLoaded) {
                OP_TOPInputDownloadOptions opts;
                opts.pixelFormat = OP_PixelFormat::BGRA8Fixed;
                opts.verticalFlip = flip;
                myPending = top->downloadTexture(opts, nullptr);
                if (myPending) {
                    myHasPending = true;
                    myPendingMax = maxDet;
                    myPendingMin = minConf;
                    myPendingScale = scaleOption;
                    mySubmitCount++;
                    myLastCookSeen = top->totalCooks;
                    lock.unlock();
                    myCond.notify_one();
                }
            }
        }

        std::vector<Detection> rows;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            rows = myRows;
        }
        if (!active)
            rows.clear();

        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize((int32_t)rows.size() + 1, 7);
        const char* hdr[7] = {"rank", "label", "confidence", "u", "v", "w", "h"};
        for (int c = 0; c < 7; c++)
            output->setCellString(0, c, hdr[c]);
        for (int i = 0; i < (int)rows.size(); i++) {
            char buf[48];
            snprintf(buf, sizeof(buf), "%d", i + 1);
            output->setCellString(i + 1, 0, buf);
            output->setCellString(i + 1, 1, rows[i].label.c_str());
            snprintf(buf, sizeof(buf), "%.4f", rows[i].confidence);
            output->setCellString(i + 1, 2, buf);
            const float vals[4] = {rows[i].u, rows[i].v, rows[i].w, rows[i].h};
            for (int c = 0; c < 4; c++) {
                snprintf(buf, sizeof(buf), "%.4f", vals[c]);
                output->setCellString(i + 1, 3 + c, buf);
            }
        }
        myDetCount = (int)rows.size();
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Top");
            p.label = "TOP";
            p.page = "CoreML Detect";
            manager->appendTOP(p);
        }
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "CoreML Detect";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Modelfile");
            p.label = "Model File";
            p.page = "CoreML Detect";
            manager->appendFile(p);
        }
        {
            OP_NumericParameter p("Reloadmodel");
            p.label = "Reload Model";
            p.page = "CoreML Detect";
            manager->appendPulse(p);
        }
        {
            OP_StringParameter p("Computeunits");
            p.label = "Compute Units";
            p.page = "CoreML Detect";
            p.defaultValue = "all";
            const char* names[] = {"all", "cpugpu", "cpuonly", "cpuane"};
            const char* labels[] = {"All (ANE + GPU + CPU)", "CPU + GPU", "CPU Only",
                                    "CPU + Neural Engine"};
            manager->appendMenu(p, 4, names, labels);
        }
        {
            OP_StringParameter p("Scaling");
            p.label = "Input Scaling";
            p.page = "CoreML Detect";
            p.defaultValue = "scalefill";
            const char* names[] = {"scalefill", "centercrop", "scalefit"};
            const char* labels[] = {"Scale Fill", "Center Crop", "Scale Fit"};
            manager->appendMenu(p, 3, names, labels);
        }
        {
            OP_NumericParameter p("Maxdetections");
            p.label = "Max Detections";
            p.page = "CoreML Detect";
            p.defaultValues[0] = 20;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 20;
            p.minValues[0] = 1;
            p.maxValues[0] = 100;
            p.clampMins[0] = true;
            p.clampMaxes[0] = true;
            manager->appendInt(p);
        }
        {
            OP_NumericParameter p("Minconfidence");
            p.label = "Min Confidence";
            p.page = "CoreML Detect";
            p.defaultValues[0] = 0.25;
            p.minSliders[0] = 0;
            p.maxSliders[0] = 1;
            p.minValues[0] = 0;
            p.maxValues[0] = 1;
            p.clampMins[0] = true;
            p.clampMaxes[0] = true;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "CoreML Detect";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Reloadmodel") == 0) {
            std::lock_guard<std::mutex> lock(myMutex);
            myForceReload = true;
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 6; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[6] = {"executes", "submits", "analyzes", "analyze_ms",
                                "detections", "loaded"};
        float values[6] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           myAnalyzeMs.load(), (float)myDetCount,
                           myModelLoaded ? 1.0f : 0.0f};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getErrorString(OP_String* error, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (!myError.empty())
            error->setString(myError.c_str());
    }

    void getWarningString(OP_String* warning, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (!myWarning.empty())
            warning->setString(myWarning.c_str());
        else if (myRequestedPath.empty())
            warning->setString("Set a detection Core ML model (.mlmodel / .mlpackage)");
    }

private:
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            bool doLoad = false;
            std::string loadPath;
            int loadUnits = 0, maxDet = 20, scaleOption = 0;
            float minConf = 0.25f;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myNeedLoad || myHasPending; });
                if (myQuit)
                    return;
                if (myNeedLoad) {
                    doLoad = true;
                    myNeedLoad = false;
                    loadPath = myRequestedPath;
                    loadUnits = myRequestedUnits;
                    myModelLoaded = false;
                    myError.clear();
                    myWarning = "loading model...";
                } else {
                    download = std::move(myPending);
                    myHasPending = false;
                    myBusy = true;
                    maxDet = myPendingMax;
                    minConf = myPendingMin;
                    scaleOption = myPendingScale;
                }
            }

            if (doLoad) {
                loadModel(loadPath, loadUnits);
                continue;
            }

            std::vector<Detection> rows;
            std::string warning;
            const auto t0 = std::chrono::steady_clock::now();
            analyze(download, maxDet, minConf, scaleOption, rows, warning);
            myAnalyzeMs = std::chrono::duration<float, std::milli>(
                              std::chrono::steady_clock::now() - t0).count();
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                myRows = std::move(rows);
                myWarning = std::move(warning);
                myBusy = false;
            }
        }
    }

    // .mlpackage/.mlmodel のコンパイル結果を CoreML TOP と同じ場所にキャッシュ
    static NSURL* compiledModelURL(NSString* path, NSError** err)
    {
        if ([path hasSuffix:@".mlmodelc"])
            return [NSURL fileURLWithPath:path];

        NSFileManager* fm = [NSFileManager defaultManager];
        NSDictionary* attrs = [fm attributesOfItemAtPath:path error:nil];
        NSString* key = [NSString stringWithFormat:@"%@_%llu_%.0f",
                         [[path lastPathComponent] stringByDeletingPathExtension],
                         (unsigned long long)[attrs fileSize],
                         [[attrs fileModificationDate] timeIntervalSince1970]];
        NSURL* cacheDir = [[fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask]
                              .firstObject URLByAppendingPathComponent:@"TDAppleML"];
        NSURL* cached = [[cacheDir URLByAppendingPathComponent:key]
                            URLByAppendingPathExtension:@"mlmodelc"];
        if ([fm fileExistsAtPath:cached.path])
            return cached;

        NSURL* tmp = [MLModel compileModelAtURL:[NSURL fileURLWithPath:path] error:err];
        if (!tmp)
            return nil;
        [fm createDirectoryAtURL:cacheDir withIntermediateDirectories:YES attributes:nil
                           error:nil];
        if ([fm moveItemAtURL:tmp toURL:cached error:nil])
            return cached;
        return tmp;
    }

    void loadModel(const std::string& path, int units)
    {
        @autoreleasepool {
            NSError* err = nil;
            NSString* nspath = [NSString stringWithUTF8String:path.c_str()];
            NSURL* compiled = compiledModelURL(nspath, &err);

            VNCoreMLModel* vnModel = nil;
            std::string errorStr;
            if (compiled) {
                MLModelConfiguration* cfg = [[MLModelConfiguration alloc] init];
                cfg.computeUnits = (units == 1) ? MLComputeUnitsCPUAndGPU
                                 : (units == 2) ? MLComputeUnitsCPUOnly
                                                : MLComputeUnitsAll;
                if (units == 3) {
                    if (@available(macOS 13.0, *))
                        cfg.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
                }
                MLModel* model = [MLModel modelWithContentsOfURL:compiled
                                                   configuration:cfg
                                                           error:&err];
                if (model)
                    vnModel = [VNCoreMLModel modelForMLModel:model error:&err];
            }
            if (!vnModel)
                errorStr = "Model load failed: " +
                           nsstr(err ? err.localizedDescription : @"unknown error");

            std::lock_guard<std::mutex> lock(myMutex);
            myVNModel = vnModel;
            myModelLoaded = (vnModel != nil);
            myError = errorStr;
            myWarning.clear();
        }
    }

    void analyze(OP_SmartRef<OP_TOPDownloadResult>& download, int maxDet, float minConf,
                 int scaleOption, std::vector<Detection>& rows, std::string& warning)
    {
        if (!download)
            return;
        void* data = download->getData();
        const uint32_t w = download->textureDesc.width;
        const uint32_t h = download->textureDesc.height;
        if (!data || w == 0 || h == 0)
            return;

        VNCoreMLModel* model;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            model = myVNModel;
        }
        if (!model)
            return;

        @autoreleasepool {
            CVPixelBufferRef input = nullptr;
            CVPixelBufferCreateWithBytes(nullptr, w, h, kCVPixelFormatType_32BGRA,
                                         data, (size_t)w * 4, nullptr, nullptr, nullptr,
                                         &input);
            if (!input)
                return;

            VNCoreMLRequest* request = [[VNCoreMLRequest alloc] initWithModel:model];
            request.imageCropAndScaleOption =
                (scaleOption == 1) ? VNImageCropAndScaleOptionCenterCrop
              : (scaleOption == 2) ? VNImageCropAndScaleOptionScaleFit
                                   : VNImageCropAndScaleOptionScaleFill;

            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCVPixelBuffer:input options:@{}];
            NSError* err = nil;
            if ([handler performRequests:@[request] error:&err]) {
                bool sawRecognized = false;
                for (VNObservation* obs in request.results) {
                    if (![obs isKindOfClass:[VNRecognizedObjectObservation class]])
                        continue;
                    sawRecognized = true;
                    if ((int)rows.size() >= maxDet)
                        break;
                    VNRecognizedObjectObservation* r = (VNRecognizedObjectObservation*)obs;
                    VNClassificationObservation* top = r.labels.firstObject;
                    const float conf = top ? top.confidence : r.confidence;
                    if (conf < minConf)
                        continue;
                    const CGRect b = r.boundingBox;
                    Detection d;
                    d.label = top ? nsstr(top.identifier) : "object";
                    d.confidence = conf;
                    d.u = (float)(b.origin.x + b.size.width * 0.5);
                    d.v = (float)(b.origin.y + b.size.height * 0.5);
                    d.w = (float)b.size.width;
                    d.h = (float)b.size.height;
                    rows.push_back(std::move(d));
                }
                if (!sawRecognized && request.results.count > 0)
                    warning = "Model did not return detections "
                              "(not an object detection model? use CoreML TOP/CHOP)";
            } else if (err) {
                warning = nsstr(err.localizedDescription);
            }
            CVPixelBufferRelease(input);
        }
    }

    // ---------------------------------------------------------- state

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;
    bool myHasPending = false;
    bool myBusy = false;
    bool myNeedLoad = false;
    bool myForceReload = false;
    bool myModelLoaded = false;
    OP_SmartRef<OP_TOPDownloadResult> myPending;
    int myPendingMax = 20, myPendingScale = 0;
    float myPendingMin = 0.25f;
    std::vector<Detection> myRows;
    VNCoreMLModel* myVNModel = nil;
    std::string myRequestedPath, myError, myWarning, mySignature;
    int myRequestedUnits = 0;
    int64_t myLastCookSeen = -1;

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0}, myDetCount{0};
    std::atomic<float> myAnalyzeMs{0.0f};
};

}   // namespace

// ------------------------------------------------------------------ entry points

extern "C" {

DLLEXPORT void
FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Coreml");
    info->customOPInfo.opLabel->setString("CoreML");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("CML");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new CoreMLDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete static_cast<CoreMLDAT*>(instance);
}

}   // extern "C"
