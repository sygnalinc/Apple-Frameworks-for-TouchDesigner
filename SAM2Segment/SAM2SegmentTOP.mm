// SAM2Segment TOP — TouchDesigner カスタムオペレータ(macOS / Core ML)
//
// Apple 公式変換の SAM 2.1(Segment Anything Model 2)で、**指定した点にある
// 任意のオブジェクトのマスク**を生成する。VisionSubject(全被写体自動)と違い
// 「どれを抜くか」をプロンプト座標で指定できる。マウス/タッチ座標を
// Prompt Point に流せば「観客が触れたものを切り抜く」演出が作れる。
//
// モデル(3点セット・https://huggingface.co/apple/coreml-sam2.1-tiny 等):
//   *ImageEncoder*.mlpackage   入力画像(1024x1024)→ 画像埋め込み
//   *PromptEncoder*.mlpackage  プロンプト点 → 埋め込み
//   *MaskDecoder*.mlpackage    埋め込み → 3候補マスク(256x256)+スコア
// Model Folder に3つが入ったフォルダを指定する(名前パターンで自動発見)。
//
// 出力: 最高スコア候補のソフトマスク(sigmoid・Mono32Float・256x256)。
// 入力解像度に合わせるには Fit TOP。硬いマスクは Threshold TOP で。
//
// 実装: 画像エンコード(重い)はフレーム変化時のみ、プロンプトエンコード+デコード
// (軽い)はプロンプト変化時のみ実行。静止画なら点を動かすだけで即マスク更新。

#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <CoreVideo/CoreVideo.h>

#include <atomic>
#include <chrono>
#include <cmath>
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

constexpr uint32_t kEncSize = 1024;   // 画像エンコーダの入力辺
constexpr uint32_t kMaskSize = 256;   // デコーダのマスク出力辺

struct FrameResult
{
    std::vector<uint8_t> data;   // Mono32Float
    uint32_t width = 0;
    uint32_t height = 0;
    uint64_t serial = 0;
};

struct Prompt
{
    float u = 0.5f, v = 0.5f;       // 前景点(uv・左下原点)
    float bu = 0.0f, bv = 0.0f;     // 背景点
    bool useBg = false;
    bool operator!=(const Prompt& o) const
    {
        return u != o.u || v != o.v || bu != o.bu || bv != o.bv || useBg != o.useBg;
    }
};

static std::string nsstr(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }

class SAM2SegmentTOP : public TOP_CPlusPlusBase
{
public:
    SAM2SegmentTOP(const OP_NodeInfo*, TOP_Context* context) : myContext(context)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~SAM2SegmentTOP() override
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
        const bool flip = inputs->getParInt("Flip") != 0;
        Prompt prompt;
        prompt.u = (float)inputs->getParDouble("Promptpoint", 0);
        prompt.v = (float)inputs->getParDouble("Promptpoint", 1);
        prompt.bu = (float)inputs->getParDouble("Bgpoint", 0);
        prompt.bv = (float)inputs->getParDouble("Bgpoint", 1);
        prompt.useBg = inputs->getParInt("Usebgpoint") != 0;
        inputs->enablePar("Bgpoint", prompt.useBg);
        const bool largest = strcmp(inputs->getParString("Maskselect"), "largest") == 0;
        const bool selectChanged = (largest != myLastLargestSeen);
        myLastLargestSeen = largest;
        myLargest = largest;

        const bool cpuGPU = strcmp(inputs->getParString("Computeunits"), "cpugpu") == 0;
        std::string folder;
        if (const char* f = inputs->getParString("Modelfolder"))
            folder = f;

        {
            std::lock_guard<std::mutex> lock(myMutex);
            if ((folder != myRequestedFolder || cpuGPU != myRequestedCpuGPU || myForceReload)
                && !folder.empty()) {
                myRequestedFolder = folder;
                myRequestedCpuGPU = cpuGPU;
                myForceReload = false;
                myNeedLoad = true;
                myCond.notify_one();
            }
        }

        const OP_TOPInput* top = inputs->getInputTOP(0);
        const bool newFrame = top && top->totalCooks != myLastCookSeen;
        const bool newPrompt = (prompt != myLastPrompt) || selectChanged;
        if (active && myModelsLoaded && (newFrame || newPrompt)) {
            std::unique_lock<std::mutex> lock(myMutex, std::try_to_lock);
            if (lock.owns_lock() && !myHasPending && !myBusy) {
                bool submitted = false;
                if (newFrame && top) {
                    OP_TOPInputDownloadOptions opts;
                    opts.pixelFormat = OP_PixelFormat::BGRA8Fixed;
                    opts.verticalFlip = flip;
                    myPending = top->downloadTexture(opts, nullptr);
                    if (myPending) {
                        myLastCookSeen = top->totalCooks;
                        submitted = true;
                    }
                } else {
                    // プロンプトのみ更新(埋め込みは再利用)
                    myPending = OP_SmartRef<OP_TOPDownloadResult>();
                    submitted = myHasEmbedding;
                }
                if (submitted) {
                    myPendingPrompt = prompt;
                    myLastPrompt = prompt;
                    myHasPending = true;
                    mySubmitCount++;
                    lock.unlock();
                    myCond.notify_one();
                }
            }
        }

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
        info.textureDesc.pixelFormat = OP_PixelFormat::Mono32Float;
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
            p.page = "SAM2";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Modelfolder");
            p.label = "Model Folder";
            p.page = "SAM2";
            manager->appendFolder(p);
        }
        {
            OP_NumericParameter p("Reloadmodel");
            p.label = "Reload Models";
            p.page = "SAM2";
            manager->appendPulse(p);
        }
        {
            OP_StringParameter p("Computeunits");
            p.label = "Compute Units";
            p.page = "SAM2";
            p.defaultValue = "all";
            const char* names[] = {"all", "cpugpu"};
            const char* labels[] = {"All (ANE + GPU + CPU)", "CPU + GPU"};
            manager->appendMenu(p, 2, names, labels);
        }
        {
            OP_NumericParameter p("Promptpoint");
            p.label = "Prompt Point";
            p.page = "SAM2";
            p.defaultValues[0] = 0.5;
            p.defaultValues[1] = 0.5;
            for (int i = 0; i < 2; i++) {
                p.minSliders[i] = 0.0;
                p.maxSliders[i] = 1.0;
            }
            manager->appendXY(p);
        }
        {
            OP_StringParameter p("Maskselect");
            p.label = "Mask Select";
            p.page = "SAM2";
            p.defaultValue = "largest";
            const char* names[] = {"largest", "score"};
            const char* labels[] = {"Largest (Whole Object)", "Best Score (Part)"};
            manager->appendMenu(p, 2, names, labels);
        }
        {
            OP_NumericParameter p("Usebgpoint");
            p.label = "Use Background Point";
            p.page = "SAM2";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Bgpoint");
            p.label = "Background Point";
            p.page = "SAM2";
            p.defaultValues[0] = 0.1;
            p.defaultValues[1] = 0.1;
            for (int i = 0; i < 2; i++) {
                p.minSliders[i] = 0.0;
                p.maxSliders[i] = 1.0;
            }
            manager->appendXY(p);
        }
        {
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "SAM2";
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
        const char* names[7] = {"executes", "submits", "analyzes", "encode_ms",
                                "decode_ms", "score", "loaded"};
        float values[7] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           myEncodeMs.load(), myDecodeMs.load(), myScore.load(),
                           myModelsLoaded ? 1.0f : 0.0f};
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
        else if (myRequestedFolder.empty())
            warning->setString("Set Model Folder (3x SAM2 mlpackages: "
                               "ImageEncoder / PromptEncoder / MaskDecoder)");
    }

private:
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            Prompt prompt;
            bool doLoad = false;
            std::string folder;
            bool cpuGPU = false;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myNeedLoad || myHasPending; });
                if (myQuit)
                    return;
                if (myNeedLoad) {
                    doLoad = true;
                    myNeedLoad = false;
                    folder = myRequestedFolder;
                    cpuGPU = myRequestedCpuGPU;
                    myModelsLoaded = false;
                    myError.clear();
                    myWarning = "loading models...";
                } else {
                    download = std::move(myPending);
                    prompt = myPendingPrompt;
                    myHasPending = false;
                    myBusy = true;
                }
            }

            if (doLoad) {
                loadModels(folder, cpuGPU);
                continue;
            }

            std::string error;
            FrameResult result;
            process(download, prompt, result, error);
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                if (!result.data.empty()) {
                    result.serial = ++mySerial;
                    myResult = std::move(result);
                }
                if (!error.empty())
                    myError = error;
                myBusy = false;
            }
        }
    }

    // ---------------------------------------------------------- model loading

    static NSURL* compiledModelURL(NSString* path, NSError** err)
    {
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

    MLModel* loadOne(NSString* dir, NSString* pattern, MLModelConfiguration* cfg,
                     std::string& error)
    {
        NSFileManager* fm = [NSFileManager defaultManager];
        NSArray* items = [fm contentsOfDirectoryAtPath:dir error:nil];
        NSString* found = nil;
        for (NSString* item in items) {
            if ([item localizedCaseInsensitiveContainsString:pattern] &&
                ([item hasSuffix:@".mlpackage"] || [item hasSuffix:@".mlmodelc"] ||
                 [item hasSuffix:@".mlmodel"])) {
                found = [dir stringByAppendingPathComponent:item];
                break;
            }
        }
        if (!found) {
            error = "Model not found in folder: *" + nsstr(pattern) + "*";
            return nil;
        }
        NSError* err = nil;
        NSURL* compiled = [found hasSuffix:@".mlmodelc"]
                              ? [NSURL fileURLWithPath:found]
                              : compiledModelURL(found, &err);
        MLModel* m = compiled ? [MLModel modelWithContentsOfURL:compiled
                                                  configuration:cfg
                                                          error:&err]
                              : nil;
        if (!m)
            error = nsstr(pattern) + " load failed: " +
                    nsstr(err ? err.localizedDescription : @"unknown");
        return m;
    }

    void loadModels(const std::string& folder, bool cpuGPU)
    {
        @autoreleasepool {
            MLModelConfiguration* cfg = [[MLModelConfiguration alloc] init];
            cfg.computeUnits = cpuGPU ? MLComputeUnitsCPUAndGPU : MLComputeUnitsAll;
            NSString* dir = [NSString stringWithUTF8String:folder.c_str()];
            std::string error;
            MLModel* enc = loadOne(dir, @"ImageEncoder", cfg, error);
            MLModel* pe = enc ? loadOne(dir, @"PromptEncoder", cfg, error) : nil;
            MLModel* dec = pe ? loadOne(dir, @"MaskDecoder", cfg, error) : nil;

            std::lock_guard<std::mutex> lock(myMutex);
            myEncoder = enc;
            myPromptEncoder = pe;
            myDecoder = dec;
            myModelsLoaded = (enc && pe && dec);
            myError = myModelsLoaded ? "" : error;
            myWarning.clear();
            myHasEmbedding = false;
        }
    }

    // ---------------------------------------------------------- inference

    void process(OP_SmartRef<OP_TOPDownloadResult>& download, const Prompt& prompt,
                 FrameResult& out, std::string& error)
    {
        @autoreleasepool {
            // 1) 新フレームがあれば画像エンコード(埋め込みをキャッシュ)
            if (download) {
                void* data = download->getData();
                const uint32_t w = download->textureDesc.width;
                const uint32_t h = download->textureDesc.height;
                if (!data || w == 0 || h == 0)
                    return;
                const auto t0 = std::chrono::steady_clock::now();
                if (!encodeImage((const uint8_t*)data, w, h, error))
                    return;
                myEncodeMs = std::chrono::duration<float, std::milli>(
                                 std::chrono::steady_clock::now() - t0).count();
            }
            if (!myHasEmbedding)
                return;

            // 2) プロンプトエンコード+マスクデコード
            const auto t1 = std::chrono::steady_clock::now();
            decodeMask(prompt, out, error);
            myDecodeMs = std::chrono::duration<float, std::milli>(
                             std::chrono::steady_clock::now() - t1).count();
        }
    }

    // BGRA入力を 1024x1024 に squash リサイズして画像エンコーダへ
    bool encodeImage(const uint8_t* bgra, uint32_t w, uint32_t h, std::string& error)
    {
        CVPixelBufferRef pb = nullptr;
        NSDictionary* attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        CVPixelBufferCreate(nullptr, kEncSize, kEncSize, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb);
        if (!pb) {
            error = "pixel buffer allocation failed";
            return false;
        }
        CVPixelBufferLockBaseAddress(pb, 0);
        {
            vImage_Buffer src = {(void*)bgra, h, w, (size_t)w * 4};
            vImage_Buffer dst = {CVPixelBufferGetBaseAddress(pb), kEncSize, kEncSize,
                                 CVPixelBufferGetBytesPerRow(pb)};
            vImageScale_ARGB8888(&src, &dst, nullptr, kvImageHighQualityResampling);
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);

        NSError* err = nil;
        MLFeatureValue* fv = [MLFeatureValue featureValueWithPixelBuffer:pb];
        MLDictionaryFeatureProvider* in =
            [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"image": fv}
                                                              error:&err];
        id<MLFeatureProvider> outp = in ? [myEncoder predictionFromFeatures:in error:&err]
                                        : nil;
        CVPixelBufferRelease(pb);
        if (!outp) {
            error = "image encode failed: " +
                    nsstr(err ? err.localizedDescription : @"unknown");
            return false;
        }
        myImageEmbedding = [outp featureValueForName:@"image_embedding"].multiArrayValue;
        myFeatsS0 = [outp featureValueForName:@"feats_s0"].multiArrayValue;
        myFeatsS1 = [outp featureValueForName:@"feats_s1"].multiArrayValue;
        myHasEmbedding = (myImageEmbedding && myFeatsS0 && myFeatsS1);
        return myHasEmbedding;
    }

    void decodeMask(const Prompt& prompt, FrameResult& out, std::string& error)
    {
        NSError* err = nil;
        const int n = prompt.useBg ? 2 : 1;

        // 点は 0〜1 正規化・画像座標(上原点)。TD uv(下原点)から v を反転
        MLMultiArray* points = [[MLMultiArray alloc]
            initWithShape:@[@1, @(n), @2] dataType:MLMultiArrayDataTypeFloat16 error:&err];
        MLMultiArray* labels = [[MLMultiArray alloc]
            initWithShape:@[@1, @(n)] dataType:MLMultiArrayDataTypeFloat16 error:&err];
        if (!points || !labels) {
            error = "prompt array allocation failed";
            return;
        }
        // 点座標は 1024x1024 ピクセル空間・上原点(正規化0〜1ではない・実測)。
        // TD uv(下原点)から変換する
        __fp16* pp = (__fp16*)points.dataPointer;
        __fp16* pl = (__fp16*)labels.dataPointer;
        pp[0] = (__fp16)(prompt.u * (float)kEncSize);
        pp[1] = (__fp16)((1.0f - prompt.v) * (float)kEncSize);
        pl[0] = (__fp16)1.0f;
        if (prompt.useBg) {
            pp[2] = (__fp16)(prompt.bu * (float)kEncSize);
            pp[3] = (__fp16)((1.0f - prompt.bv) * (float)kEncSize);
            pl[1] = (__fp16)0.0f;
        }

        MLDictionaryFeatureProvider* pin = [[MLDictionaryFeatureProvider alloc]
            initWithDictionary:@{@"points": [MLFeatureValue featureValueWithMultiArray:points],
                                 @"labels": [MLFeatureValue featureValueWithMultiArray:labels]}
                         error:&err];
        id<MLFeatureProvider> pout =
            pin ? [myPromptEncoder predictionFromFeatures:pin error:&err] : nil;
        if (!pout) {
            error = "prompt encode failed: " +
                    nsstr(err ? err.localizedDescription : @"unknown");
            return;
        }
        MLMultiArray* sparse = [pout featureValueForName:@"sparse_embeddings"].multiArrayValue;
        MLMultiArray* dense = [pout featureValueForName:@"dense_embeddings"].multiArrayValue;

        MLDictionaryFeatureProvider* din = [[MLDictionaryFeatureProvider alloc]
            initWithDictionary:@{
                @"image_embedding":
                    [MLFeatureValue featureValueWithMultiArray:myImageEmbedding],
                @"sparse_embedding": [MLFeatureValue featureValueWithMultiArray:sparse],
                @"dense_embedding": [MLFeatureValue featureValueWithMultiArray:dense],
                @"feats_s0": [MLFeatureValue featureValueWithMultiArray:myFeatsS0],
                @"feats_s1": [MLFeatureValue featureValueWithMultiArray:myFeatsS1],
            } error:&err];
        id<MLFeatureProvider> dout =
            din ? [myDecoder predictionFromFeatures:din error:&err] : nil;
        if (!dout) {
            error = "mask decode failed: " +
                    nsstr(err ? err.localizedDescription : @"unknown");
            return;
        }
        MLMultiArray* masks = [dout featureValueForName:@"low_res_masks"].multiArrayValue;
        MLMultiArray* scores = [dout featureValueForName:@"scores"].multiArrayValue;
        if (!masks || masks.shape.count < 4) {
            error = "unexpected decoder output";
            return;
        }

        // 候補選択: Best Score(最高信頼度・部位が選ばれがち)/ Largest(最大面積・
        // 物体全体が選ばれがち)。SAMの3候補は部位→全体の粒度違いを表す
        const uint32_t cn = masks.shape[1].unsignedIntValue;
        int best = 0;
        if (myLargest && cn > 1) {
            const uint32_t wq = masks.shape[3].unsignedIntValue;
            const uint32_t hq = masks.shape[2].unsignedIntValue;
            const NSInteger cS = masks.strides[1].integerValue;
            const NSInteger hS = masks.strides[2].integerValue;
            const NSInteger wS = masks.strides[3].integerValue;
            const __fp16* mb = (const __fp16*)masks.dataPointer;
            long bestArea = -1;
            for (uint32_t ci = 0; ci < cn; ci++) {
                long area = 0;
                for (uint32_t y = 0; y < hq; y += 2)          // 1/4サンプリングで十分
                    for (uint32_t x = 0; x < wq; x += 2)
                        if ((float)mb[ci * cS + (NSInteger)y * hS + (NSInteger)x * wS] > 0)
                            area++;
                if (area > bestArea) {
                    bestArea = area;
                    best = (int)ci;
                }
            }
            if (scores && best < (int)scores.count)
                myScore = [scores objectAtIndexedSubscript:best].floatValue;
        } else if (scores) {
            float bestScore = -1e9f;
            const NSInteger sc = scores.count;
            for (NSInteger i = 0; i < sc; i++) {
                const float s = [scores objectAtIndexedSubscript:i].floatValue;
                if (s > bestScore) {
                    bestScore = s;
                    best = (int)i;
                }
            }
            myScore = bestScore;
        }

        // logit → sigmoid のソフトマスク。画像座標(上原点)なので行反転して TD へ
        const uint32_t mw = masks.shape[3].unsignedIntValue;
        const uint32_t mh = masks.shape[2].unsignedIntValue;
        const NSInteger sC = masks.strides[1].integerValue;
        const NSInteger sH = masks.strides[2].integerValue;
        const NSInteger sW = masks.strides[3].integerValue;
        const __fp16* base = (const __fp16*)masks.dataPointer;
        out.width = mw;
        out.height = mh;
        out.data.resize((size_t)mw * mh * sizeof(float));
        float* dst = (float*)out.data.data();
        for (uint32_t y = 0; y < mh; y++) {
            float* drow = dst + (size_t)(mh - 1 - y) * mw;
            for (uint32_t x = 0; x < mw; x++) {
                const float logit =
                    (float)base[best * sC + (NSInteger)y * sH + (NSInteger)x * sW];
                drow[x] = 1.0f / (1.0f + std::exp(-logit));
            }
        }
        error.clear();
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
    bool myModelsLoaded = false;
    OP_SmartRef<OP_TOPDownloadResult> myPending;
    Prompt myPendingPrompt, myLastPrompt{-1, -1, -1, -1, false};
    FrameResult myResult;
    std::string myRequestedFolder, myError, myWarning;
    bool myRequestedCpuGPU = false;
    uint64_t mySerial = 0;
    uint64_t myUploadedSerial = 0;
    int64_t myLastCookSeen = -1;

    // ワーカー専用(モデルと埋め込みキャッシュ)
    MLModel* myEncoder = nil;
    MLModel* myPromptEncoder = nil;
    MLModel* myDecoder = nil;
    MLMultiArray* myImageEmbedding = nil;
    MLMultiArray* myFeatsS0 = nil;
    MLMultiArray* myFeatsS1 = nil;
    std::atomic<bool> myHasEmbedding{false};
    std::atomic<bool> myLargest{true};
    bool myLastLargestSeen = true;

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
    std::atomic<float> myEncodeMs{0.0f}, myDecodeMs{0.0f}, myScore{0.0f};
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
    info->customOPInfo.opType->setString("Sam2segment");
    info->customOPInfo.opLabel->setString("CoreML SAM2");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("SAM");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT TOP_CPlusPlusBase*
CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context)
{
    return new SAM2SegmentTOP(info, context);
}

DLLEXPORT void
DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context*)
{
    delete (SAM2SegmentTOP*)instance;
}

}   // extern "C"
