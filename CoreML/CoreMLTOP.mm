// CoreML TOP — TouchDesigner カスタムオペレータ(macOS / Core ML)
//
// 任意の Core ML モデル(.mlpackage / .mlmodel / .mlmodelc)をロードし、
// 入力 TOP の映像に対して推論を実行する汎用オペレータ。
// 深度推定(Depth Anything 等)・スタイル変換・セグメンテーションなど、
// 「画像入力 → 画像/2D配列出力」のモデルをそのまま差し替えて使える。
//
// 出力の対応:
//   Image出力(グレースケール f16/f32/8bit, BGRA)      → TOP テクスチャ
//   MLMultiArray出力([...,H,W]=Mono / [...,3,H,W]=RGB) → TOP テクスチャ(32bit float)
//   分類出力(VNClassificationObservation)              → Info DAT に上位10クラス
//
// 深度モデルの生値は任意スケールなので Output Range(auto=フレーム毎min-max正規化 /
// raw / manual)で 0〜1 にマップする。Depth Anything は「近いほど大きい」disparity 系
// なので、遠=白にしたい場合は Invert を使う。
//
// 実装: モデルのロード(コンパイル込み)と推論はワーカースレッドで非同期に行い、
// cook はブロックしない(結果は1〜2フレーム遅れ)。.mlpackage/.mlmodel は初回に
// ~/Library/Caches/TDAppleML/ へコンパイル結果をキャッシュする。
// ANE 初回ロードは ANECompilerService のコンパイルが走るため数秒〜かかる(2回目以降は速い)。

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreML/CoreML.h>
#import <Vision/Vision.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

// ワーカーが作る最新の推論結果(CPU バッファ)
struct FrameResult
{
    std::vector<uint8_t> data;
    uint32_t width = 0;
    uint32_t height = 0;
    OP_PixelFormat format = OP_PixelFormat::Mono32Float;
    uint64_t serial = 0;
};

// ワーカーが更新するモデル状態(Info DAT / エラー表示用)
struct ModelState
{
    std::string status = "no model";    // no model / compiling / loading / ready / error
    std::string error;
    std::string inputDesc;
    std::string outputDesc;
    std::vector<std::pair<std::string, float>> classes;   // 分類モデルの上位クラス
};

static std::string nsstr(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }

class CoreMLTOP : public TOP_CPlusPlusBase
{
public:
    CoreMLTOP(const OP_NodeInfo*, TOP_Context* context) : myContext(context)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~CoreMLTOP() override
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
        myInvert = inputs->getParInt("Invert") != 0;
        myRangeMin = (float)inputs->getParDouble("Rangemin");
        myRangeMax = (float)inputs->getParDouble("Rangemax");

        const char* range = inputs->getParString("Outputrange");
        myRangeMode = (strcmp(range, "raw") == 0) ? 1 : (strcmp(range, "manual") == 0) ? 2 : 0;
        inputs->enablePar("Rangemin", myRangeMode == 2);
        inputs->enablePar("Rangemax", myRangeMode == 2);

        const char* scale = inputs->getParString("Scaling");
        myScaleOption = (strcmp(scale, "centercrop") == 0) ? 1
                      : (strcmp(scale, "scalefit") == 0)   ? 2 : 0;

        // 静止画入力でも処理系パラメータの変更で再解析させる
        if (myRangeMode != myLastRangeMode || myScaleOption != myLastScaleOption ||
            myInvert != myLastInvert || myRangeMin != myLastRangeMin ||
            myRangeMax != myLastRangeMax) {
            myLastRangeMode = myRangeMode;
            myLastScaleOption = myScaleOption;
            myLastInvert = myInvert;
            myLastRangeMin = myRangeMin;
            myLastRangeMax = myRangeMax;
            myLastCookSeen = -1;
        }

        const char* cu = inputs->getParString("Computeunits");
        const int computeUnits = (strcmp(cu, "cpugpu") == 0)  ? 1
                               : (strcmp(cu, "cpuonly") == 0) ? 2
                               : (strcmp(cu, "cpuane") == 0)  ? 3 : 0;

        std::string path;
        if (const char* p = inputs->getParString("Modelfile"))
            path = p;

        // モデルパス/計算ユニットが変わったらロードを依頼
        {
            std::lock_guard<std::mutex> lock(myMutex);
            if ((path != myRequestedPath || computeUnits != myRequestedUnits || myForceReload)
                && !path.empty()) {
                myRequestedPath = path;
                myRequestedUnits = computeUnits;
                myForceReload = false;
                myNeedLoad = true;
                myCond.notify_one();
            } else if (path.empty() && myState.status != "no model") {
                myState = ModelState();
            }
        }

        // 新しいフレームが来ていて、ワーカーが空いていればダウンロードを投入
        const OP_TOPInput* top = inputs->getInputTOP(0);
        if (active && top && top->totalCooks != myLastCookSeen) {
            std::unique_lock<std::mutex> lock(myMutex, std::try_to_lock);
            if (lock.owns_lock() && !myHasPending && !myBusy && myModelLoaded) {
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

        // 最新結果をアップロード(新しい結果が無ければ前回のテクスチャが残る)
        FrameResult frame;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            if (myResult.serial == myUploadedSerial || myResult.data.empty())
                return;
            frame = myResult;
            myUploadedSerial = myResult.serial;
        }

        TOP_UploadInfo info;
        info.textureDesc.texDim = OP_TexDim::e2D;
        info.textureDesc.width = frame.width;
        info.textureDesc.height = frame.height;
        info.textureDesc.pixelFormat = frame.format;
        OP_SmartRef<TOP_Buffer> buf =
            myContext->createOutputBuffer(frame.data.size(), TOP_BufferFlags::None, nullptr);
        if (!buf)
            return;
        memcpy(buf->data, frame.data.data(), frame.data.size());
        output->uploadBuffer(&buf, info, nullptr);
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "CoreML";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Modelfile");
            p.label = "Model File";
            p.page = "CoreML";
            manager->appendFile(p);
        }
        {
            OP_NumericParameter p("Reloadmodel");
            p.label = "Reload Model";
            p.page = "CoreML";
            manager->appendPulse(p);
        }
        {
            OP_StringParameter p("Computeunits");
            p.label = "Compute Units";
            p.page = "CoreML";
            p.defaultValue = "all";
            const char* names[] = {"all", "cpugpu", "cpuonly", "cpuane"};
            const char* labels[] = {"All (ANE + GPU + CPU)", "CPU + GPU", "CPU Only",
                                    "CPU + Neural Engine"};
            manager->appendMenu(p, 4, names, labels);
        }
        {
            OP_StringParameter p("Scaling");
            p.label = "Input Scaling";
            p.page = "CoreML";
            p.defaultValue = "scalefill";
            const char* names[] = {"scalefill", "centercrop", "scalefit"};
            const char* labels[] = {"Scale Fill", "Center Crop", "Scale Fit"};
            manager->appendMenu(p, 3, names, labels);
        }
        {
            OP_StringParameter p("Outputrange");
            p.label = "Output Range";
            p.page = "CoreML";
            p.defaultValue = "auto";
            const char* names[] = {"auto", "raw", "manual"};
            const char* labels[] = {"Auto Normalize (min-max)", "Raw Values", "Manual Range"};
            manager->appendMenu(p, 3, names, labels);
        }
        {
            OP_NumericParameter p("Rangemin");
            p.label = "Range Min";
            p.page = "CoreML";
            p.defaultValues[0] = 0.0;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 100.0;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Rangemax");
            p.label = "Range Max";
            p.page = "CoreML";
            p.defaultValues[0] = 1.0;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 100.0;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Invert");
            p.label = "Invert Output";
            p.page = "CoreML";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
        {
            // TD の TOP ダウンロードは GL 系の上下逆(bottom-up)なので既定でフリップする
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "CoreML";
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

    int32_t getNumInfoCHOPChans(void*) override { return 7; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[7] = {"executes",  "submits", "analyzes", "loaded",
                                "inference_ms", "out_w",   "out_h"};
        float values[7] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           myModelLoaded ? 1.0f : 0.0f, myInferenceMs.load(),
                           (float)myOutW, (float)myOutH};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    bool getInfoDATSize(OP_InfoDATSize* infoSize, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        infoSize->rows = 5 + (int32_t)myState.classes.size();
        infoSize->cols = 2;
        infoSize->byColumn = false;
        return true;
    }

    void getInfoDATEntries(int32_t index, int32_t, OP_InfoDATEntries* entries, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        static const char* keys[5] = {"status", "model", "input", "output", "inference_ms"};
        char tmp[64];
        if (index < 5) {
            entries->values[0]->setString(keys[index]);
            switch (index) {
                case 0:
                    entries->values[1]->setString(
                        myState.error.empty() ? myState.status.c_str() : myState.error.c_str());
                    break;
                case 1: entries->values[1]->setString(myRequestedPath.c_str()); break;
                case 2: entries->values[1]->setString(myState.inputDesc.c_str()); break;
                case 3: entries->values[1]->setString(myState.outputDesc.c_str()); break;
                case 4:
                    snprintf(tmp, sizeof(tmp), "%.1f", myInferenceMs.load());
                    entries->values[1]->setString(tmp);
                    break;
            }
        } else {
            const size_t ci = (size_t)(index - 5);
            if (ci < myState.classes.size()) {
                entries->values[0]->setString(myState.classes[ci].first.c_str());
                snprintf(tmp, sizeof(tmp), "%.4f", myState.classes[ci].second);
                entries->values[1]->setString(tmp);
            }
        }
    }

    void getErrorString(OP_String* error, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (!myState.error.empty())
            error->setString(myState.error.c_str());
    }

    void getWarningString(OP_String* warning, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (myState.status == "no model")
            warning->setString("Set a Core ML model file (.mlpackage / .mlmodel / .mlmodelc)");
        else if (myState.status == "compiling" || myState.status == "loading")
            warning->setString("Loading model... (first ANE compile can take a while)");
    }

    void getInfoPopupString(OP_String* info, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        std::string s = myState.status + " | " + myState.outputDesc;
        info->setString(s.c_str());
    }

private:
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            bool doLoad = false;
            std::string loadPath;
            int loadUnits = 0;
            bool flip, invert;
            int rangeMode, scaleOption;
            float rangeMin, rangeMax;
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
                    myState.error.clear();
                    myState.classes.clear();
                    myState.status = "compiling";
                } else {
                    download = std::move(myPending);
                    myHasPending = false;
                    myBusy = true;
                }
                flip = myFlip;
                invert = myInvert;
                rangeMode = myRangeMode;
                scaleOption = myScaleOption;
                rangeMin = myRangeMin;
                rangeMax = myRangeMax;
            }

            if (doLoad) {
                loadModel(loadPath, loadUnits);
                continue;
            }

            FrameResult result;
            std::vector<std::pair<std::string, float>> classes;
            analyze(download, scaleOption, flip, invert, rangeMode, rangeMin, rangeMax,
                    result, classes);
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                if (!result.data.empty()) {
                    result.serial = ++mySerial;
                    myResult = std::move(result);
                    myOutW = (int)myResult.width;
                    myOutH = (int)myResult.height;
                }
                if (!classes.empty())
                    myState.classes = std::move(classes);
                myBusy = false;
            }
        }
    }

    // ---------------------------------------------------------- model loading

    // .mlpackage/.mlmodel はコンパイルが必要。結果を
    // ~/Library/Caches/TDAppleML/ に「ファイル名+サイズ+更新時刻」キーでキャッシュする
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
        [fm createDirectoryAtURL:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
        if ([fm moveItemAtURL:tmp toURL:cached error:nil])
            return cached;
        return tmp;   // キャッシュ移動に失敗してもコンパイル結果はそのまま使える
    }

    static std::string describeFeatures(NSDictionary<NSString*, MLFeatureDescription*>* dict)
    {
        NSMutableArray* parts = [NSMutableArray array];
        for (NSString* name in dict) {
            MLFeatureDescription* d = dict[name];
            if (d.type == MLFeatureTypeImage && d.imageConstraint) {
                [parts addObject:[NSString stringWithFormat:@"%@: image %dx%d", name,
                                  (int)d.imageConstraint.pixelsWide,
                                  (int)d.imageConstraint.pixelsHigh]];
            } else if (d.type == MLFeatureTypeMultiArray && d.multiArrayConstraint) {
                NSMutableArray* dims = [NSMutableArray array];
                for (NSNumber* n in d.multiArrayConstraint.shape)
                    [dims addObject:n.stringValue];
                [parts addObject:[NSString stringWithFormat:@"%@: array [%@]", name,
                                  [dims componentsJoinedByString:@"x"]]];
            } else {
                [parts addObject:[NSString stringWithFormat:@"%@: type %d", name, (int)d.type]];
            }
        }
        return nsstr([parts componentsJoinedByString:@", "]);
    }

    void loadModel(const std::string& path, int units)
    {
        @autoreleasepool {
            NSError* err = nil;
            NSString* nspath = [NSString stringWithUTF8String:path.c_str()];
            NSURL* compiled = compiledModelURL(nspath, &err);

            VNCoreMLModel* vnModel = nil;
            std::string inputDesc, outputDesc, errorStr;
            if (compiled) {
                {
                    std::lock_guard<std::mutex> lock(myMutex);
                    myState.status = "loading";
                }
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
                if (model) {
                    inputDesc = describeFeatures(model.modelDescription.inputDescriptionsByName);
                    outputDesc = describeFeatures(model.modelDescription.outputDescriptionsByName);
                    vnModel = [VNCoreMLModel modelForMLModel:model error:&err];
                }
            }
            if (!vnModel)
                errorStr = "Model load failed: " +
                           nsstr(err ? err.localizedDescription : @"unknown error");

            std::lock_guard<std::mutex> lock(myMutex);
            myVNModel = vnModel;
            myModelLoaded = (vnModel != nil);
            myState.status = myModelLoaded ? "ready" : "error";
            myState.error = errorStr;
            myState.inputDesc = inputDesc;
            myState.outputDesc = outputDesc;
        }
    }

    // ---------------------------------------------------------- inference

    void analyze(OP_SmartRef<OP_TOPDownloadResult>& download, int scaleOption, bool flip,
                 bool invert, int rangeMode, float rangeMin, float rangeMax,
                 FrameResult& out, std::vector<std::pair<std::string, float>>& classes)
    {
        if (!download)
            return;
        void* data = download->getData();   // 完了までブロック(ワーカースレッドなのでOK)
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
                                         data, w * 4, nullptr, nullptr, nullptr, &input);
            if (!input)
                return;

            VNCoreMLRequest* request = [[VNCoreMLRequest alloc] initWithModel:model];
            request.imageCropAndScaleOption =
                (scaleOption == 1) ? VNImageCropAndScaleOptionCenterCrop
              : (scaleOption == 2) ? VNImageCropAndScaleOptionScaleFit
                                   : VNImageCropAndScaleOptionScaleFill;

            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCVPixelBuffer:input options:@{}];

            const auto t0 = std::chrono::steady_clock::now();
            NSError* err = nil;
            const bool ok = [handler performRequests:@[request] error:&err];
            const auto t1 = std::chrono::steady_clock::now();
            myInferenceMs = std::chrono::duration<float, std::milli>(t1 - t0).count();
            CVPixelBufferRelease(input);
            if (!ok)
                return;

            // 結果の種類ごとに変換(画像 / MultiArray / 分類)
            for (VNObservation* obs in request.results) {
                if ([obs isKindOfClass:[VNPixelBufferObservation class]]) {
                    convertPixelBuffer(((VNPixelBufferObservation*)obs).pixelBuffer, flip,
                                       invert, rangeMode, rangeMin, rangeMax, out);
                    return;
                }
            }
            for (VNObservation* obs in request.results) {
                if ([obs isKindOfClass:[VNCoreMLFeatureValueObservation class]]) {
                    MLFeatureValue* fv = ((VNCoreMLFeatureValueObservation*)obs).featureValue;
                    if (fv.type == MLFeatureTypeMultiArray && fv.multiArrayValue) {
                        convertMultiArray(fv.multiArrayValue, flip, invert, rangeMode,
                                          rangeMin, rangeMax, out);
                        return;
                    }
                }
            }
            for (VNObservation* obs in request.results) {
                if ([obs isKindOfClass:[VNClassificationObservation class]]) {
                    VNClassificationObservation* c = (VNClassificationObservation*)obs;
                    classes.push_back({nsstr(c.identifier), c.confidence});
                    if (classes.size() >= 10)
                        break;
                }
            }
        }
    }

    // 正規化(auto=min-max / manual=指定レンジ)と反転を float バッファに適用する
    static void normalizeFloats(std::vector<float>& v, bool invert, int rangeMode,
                                float rangeMin, float rangeMax)
    {
        if (v.empty())
            return;
        if (rangeMode == 0) {   // auto min-max
            float lo = v[0], hi = v[0];
            for (float f : v) {
                if (f < lo) lo = f;
                if (f > hi) hi = f;
            }
            const float scale = (hi > lo) ? 1.0f / (hi - lo) : 0.0f;
            for (float& f : v)
                f = (f - lo) * scale;
        } else if (rangeMode == 2) {   // manual
            const float scale = (rangeMax > rangeMin) ? 1.0f / (rangeMax - rangeMin) : 0.0f;
            for (float& f : v) {
                f = (f - rangeMin) * scale;
                f = f < 0.0f ? 0.0f : (f > 1.0f ? 1.0f : f);
            }
        }
        if (invert)
            for (float& f : v)
                f = 1.0f - f;
    }

    // float モノクロ平面を(必要なら行反転して)Mono32Float の出力バッファへ
    static void storeMonoFloat(const std::vector<float>& src, uint32_t w, uint32_t h,
                               bool flip, FrameResult& out)
    {
        out.width = w;
        out.height = h;
        out.format = OP_PixelFormat::Mono32Float;
        out.data.resize((size_t)w * h * sizeof(float));
        float* dst = (float*)out.data.data();
        for (uint32_t y = 0; y < h; y++) {
            const float* row = src.data() + (size_t)y * w;
            memcpy(dst + (size_t)(flip ? (h - 1 - y) : y) * w, row, w * sizeof(float));
        }
    }

    // Image 出力(深度マップのグレースケール f16/f32、スタイル変換の BGRA 等)を変換
    static void convertPixelBuffer(CVPixelBufferRef pb, bool flip, bool invert, int rangeMode,
                                   float rangeMin, float rangeMax, FrameResult& out)
    {
        if (!pb)
            return;
        CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        const uint32_t pw = (uint32_t)CVPixelBufferGetWidth(pb);
        const uint32_t ph = (uint32_t)CVPixelBufferGetHeight(pb);
        const size_t stride = CVPixelBufferGetBytesPerRow(pb);
        const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(pb);
        const OSType fmt = CVPixelBufferGetPixelFormatType(pb);

        if (base && pw && ph) {
            const bool half = (fmt == kCVPixelFormatType_OneComponent16Half ||
                               fmt == kCVPixelFormatType_DepthFloat16 ||
                               fmt == kCVPixelFormatType_DisparityFloat16);
            const bool flt = (fmt == kCVPixelFormatType_OneComponent32Float ||
                              fmt == kCVPixelFormatType_DepthFloat32 ||
                              fmt == kCVPixelFormatType_DisparityFloat32);
            if (half || flt) {
                std::vector<float> vals((size_t)pw * ph);
                for (uint32_t y = 0; y < ph; y++) {
                    const uint8_t* row = base + (size_t)y * stride;
                    float* dst = vals.data() + (size_t)y * pw;
                    if (half) {
                        const __fp16* s = (const __fp16*)row;
                        for (uint32_t x = 0; x < pw; x++)
                            dst[x] = (float)s[x];
                    } else {
                        memcpy(dst, row, pw * sizeof(float));
                    }
                }
                normalizeFloats(vals, invert, rangeMode, rangeMin, rangeMax);
                storeMonoFloat(vals, pw, ph, flip, out);
            } else if (fmt == kCVPixelFormatType_OneComponent8) {
                out.width = pw;
                out.height = ph;
                out.format = OP_PixelFormat::Mono8Fixed;
                out.data.resize((size_t)pw * ph);
                for (uint32_t y = 0; y < ph; y++)
                    memcpy(out.data.data() + (size_t)(flip ? (ph - 1 - y) : y) * pw,
                           base + (size_t)y * stride, pw);
            } else if (fmt == kCVPixelFormatType_32BGRA || fmt == kCVPixelFormatType_32ARGB) {
                // 32ARGB も BGRA として扱う(まれ。色順が狂う場合は Reorder TOP で対処)
                out.width = pw;
                out.height = ph;
                out.format = OP_PixelFormat::BGRA8Fixed;
                out.data.resize((size_t)pw * ph * 4);
                for (uint32_t y = 0; y < ph; y++)
                    memcpy(out.data.data() + (size_t)(flip ? (ph - 1 - y) : y) * pw * 4,
                           base + (size_t)y * stride, (size_t)pw * 4);
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    }

    // MLMultiArray 出力を変換。[...,H,W](モノクロ)と [...,3,H,W](RGB・CHW)に対応
    static void convertMultiArray(MLMultiArray* arr, bool flip, bool invert, int rangeMode,
                                  float rangeMin, float rangeMax, FrameResult& out)
    {
        const NSInteger n = arr.shape.count;
        if (n < 2)
            return;
        const uint32_t aw = arr.shape[n - 1].unsignedIntValue;
        const uint32_t ah = arr.shape[n - 2].unsignedIntValue;
        NSInteger leading = 1;
        for (NSInteger i = 0; i < n - 2; i++)
            leading *= arr.shape[i].integerValue;
        if (aw == 0 || ah == 0 || (leading != 1 && leading != 3))
            return;

        const NSInteger sW = arr.strides[n - 1].integerValue;
        const NSInteger sH = arr.strides[n - 2].integerValue;
        const NSInteger sC = (n >= 3) ? arr.strides[n - 3].integerValue : 0;
        const void* base = arr.dataPointer;
        const MLMultiArrayDataType dt = arr.dataType;

        auto fetch = [&](NSInteger c, uint32_t y, uint32_t x) -> float {
            const NSInteger idx = c * sC + (NSInteger)y * sH + (NSInteger)x * sW;
            switch (dt) {
                case MLMultiArrayDataTypeFloat32: return ((const float*)base)[idx];
                case MLMultiArrayDataTypeFloat16: return (float)((const __fp16*)base)[idx];
                case MLMultiArrayDataTypeDouble:  return (float)((const double*)base)[idx];
                case MLMultiArrayDataTypeInt32:   return (float)((const int32_t*)base)[idx];
                default: return 0.0f;
            }
        };

        if (leading == 1) {
            std::vector<float> vals((size_t)aw * ah);
            for (uint32_t y = 0; y < ah; y++)
                for (uint32_t x = 0; x < aw; x++)
                    vals[(size_t)y * aw + x] = fetch(0, y, x);
            normalizeFloats(vals, invert, rangeMode, rangeMin, rangeMax);
            storeMonoFloat(vals, aw, ah, flip, out);
        } else {   // leading == 3: CHW カラー → RGBA32Float
            std::vector<float> vals((size_t)aw * ah * 3);
            for (NSInteger c = 0; c < 3; c++)
                for (uint32_t y = 0; y < ah; y++)
                    for (uint32_t x = 0; x < aw; x++)
                        vals[(size_t)c * aw * ah + (size_t)y * aw + x] = fetch(c, y, x);
            normalizeFloats(vals, invert, rangeMode, rangeMin, rangeMax);
            out.width = aw;
            out.height = ah;
            out.format = OP_PixelFormat::RGBA32Float;
            out.data.resize((size_t)aw * ah * 4 * sizeof(float));
            float* dst = (float*)out.data.data();
            const size_t plane = (size_t)aw * ah;
            for (uint32_t y = 0; y < ah; y++) {
                float* drow = dst + (size_t)(flip ? (ah - 1 - y) : y) * aw * 4;
                for (uint32_t x = 0; x < aw; x++) {
                    const size_t si = (size_t)y * aw + x;
                    drow[x * 4 + 0] = vals[si];
                    drow[x * 4 + 1] = vals[plane + si];
                    drow[x * 4 + 2] = vals[plane * 2 + si];
                    drow[x * 4 + 3] = 1.0f;
                }
            }
        }
    }

    // ---------------------------------------------------------- state

    TOP_Context* myContext;
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
    FrameResult myResult;
    ModelState myState;
    VNCoreMLModel* myVNModel = nil;
    std::string myRequestedPath;
    int myRequestedUnits = 0;
    uint64_t mySerial = 0;
    uint64_t myUploadedSerial = 0;
    int64_t myLastCookSeen = -1;

    std::atomic<bool> myFlip{true}, myInvert{false};
    int myRangeMode = 0;
    int myScaleOption = 0;
    float myRangeMin = 0.0f, myRangeMax = 1.0f;
    int myLastRangeMode = -1, myLastScaleOption = -1;
    bool myLastInvert = false;
    float myLastRangeMin = -1.0f, myLastRangeMax = -1.0f;

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
    std::atomic<int> myOutW{0}, myOutH{0};
    std::atomic<float> myInferenceMs{0.0f};
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
    info->customOPInfo.opType->setString("Coreml");
    info->customOPInfo.opLabel->setString("CoreML");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.opIcon->setString("CML");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/CoreML/README.md");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT TOP_CPlusPlusBase*
CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new CoreMLTOP(info, context);
}

DLLEXPORT void
DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (CoreMLTOP*)instance;
}

}   // extern "C"
