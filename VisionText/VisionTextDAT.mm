// VisionText DAT — OCR / テキスト認識（macOS / Apple Vision）
//
// TOP パラメータで指定した映像から文字（VNRecognizeTextRequest）を認識し、
// テキスト領域ごとにテーブルで出力する。日本語・英語ほか多言語対応・オンデバイス。
//
// 出力テーブル:
//   text | confidence | u | v | width | height
//   1行 = 1テキスト領域。u,v は領域バウンディングボックスの中心（0〜1・左下原点）。
//   行は読み順（上→下、左→右）に並べる。
//
// 実装: cook のたびに TOP を非同期ダウンロードし、ワーカースレッドが Vision 推定 →
// 結果を保存。cook は最新結果を出すだけ（accurate は1解析 100ms 級なので
// 更新はその間隔になる。cook はブロックしない）。

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Vision/Vision.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

struct TextRegion
{
    std::string text;
    float confidence = 0;
    float bbox[4] = {};   // 中心u, 中心v, width, height
};

class VisionTextDAT : public DAT_CPlusPlusBase
{
public:
    explicit VisionTextDAT(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~VisionTextDAT() override
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
        {
            std::lock_guard<std::mutex> lock(myMutex);
            myFlip = inputs->getParInt("Flip") != 0;
            myAccurate = strcmp(inputs->getParString("Level"), "accurate") == 0;
            const char* langs = inputs->getParString("Languages");
            myLanguages = langs ? langs : "";
            myCorrection = inputs->getParInt("Correction") != 0;
            myMinConfidence = (float)inputs->getParDouble("Minconfidence");
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

        std::vector<TextRegion> regions;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            regions = myRegions;
        }
        if (!active)
            regions.clear();

        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize(1 + (int32_t)regions.size(), 6);
        const char* header[6] = {"text", "confidence", "u", "v", "width", "height"};
        for (int c = 0; c < 6; c++)
            output->setCellString(0, c, header[c]);
        for (size_t r = 0; r < regions.size(); r++) {
            const TextRegion& region = regions[r];
            char buf[32];
            output->setCellString((int32_t)r + 1, 0, region.text.c_str());
            snprintf(buf, sizeof(buf), "%.3f", region.confidence);
            output->setCellString((int32_t)r + 1, 1, buf);
            for (int c = 0; c < 4; c++) {
                snprintf(buf, sizeof(buf), "%.4f", region.bbox[c]);
                output->setCellString((int32_t)r + 1, 2 + c, buf);
            }
        }
        myRowCount = (int)regions.size();
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Top");
            p.label = "TOP";
            p.page = "Vision Text";
            manager->appendTOP(p);
        }
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Vision Text";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Level");
            p.label = "Recognition Level";
            p.page = "Vision Text";
            p.defaultValue = "accurate";
            const char* names[] = {"accurate", "fast"};
            const char* labels[] = {"Accurate", "Fast"};
            manager->appendMenu(p, 2, names, labels);
        }
        {
            OP_StringParameter p("Languages");
            p.label = "Languages";
            p.page = "Vision Text";
            p.defaultValue = "ja-JP en-US";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Correction");
            p.label = "Language Correction";
            p.page = "Vision Text";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Minconfidence");
            p.label = "Min Confidence";
            p.page = "Vision Text";
            p.defaultValues[0] = 0.3;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 1.0;
            manager->appendFloat(p);
        }
        {
            // TD の TOP ダウンロードは GL 系の上下逆（bottom-up）なので既定でフリップする
            OP_NumericParameter p("Flip");
            p.label = "Flip Image Vertically";
            p.page = "Vision Text";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[5] = {"executes", "submits", "analyzes", "regions", "analyze_ms"};
        float values[5] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           (float)myRowCount, (float)myAnalyzeMs};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

private:
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> download;
            bool accurate, correction;
            float minConf;
            std::string languages;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                download = std::move(myPending);
                myHasPending = false;
                myBusy = true;
                accurate = myAccurate;
                correction = myCorrection;
                minConf = myMinConfidence;
                languages = myLanguages;
            }
            const double t0 = CFAbsoluteTimeGetCurrent();
            std::vector<TextRegion> regions =
                analyze(download, accurate, correction, minConf, languages);
            myAnalyzeMs = (int)((CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                myRegions = std::move(regions);
                myBusy = false;
            }
        }
    }

    std::vector<TextRegion> analyze(OP_SmartRef<OP_TOPDownloadResult>& download,
                                    bool accurate, bool correction, float minConf,
                                    const std::string& languages)
    {
        std::vector<TextRegion> result;
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

            VNRecognizeTextRequest* request = [[VNRecognizeTextRequest alloc] init];
            request.recognitionLevel = accurate ? VNRequestTextRecognitionLevelAccurate
                                                : VNRequestTextRecognitionLevelFast;
            request.usesLanguageCorrection = correction;
            // 言語指定（空白区切り → NSArray）。空なら Vision の既定
            NSMutableArray<NSString*>* langs = [NSMutableArray array];
            std::istringstream ss(languages);
            std::string token;
            while (ss >> token)
                [langs addObject:[NSString stringWithUTF8String:token.c_str()]];
            if (langs.count > 0)
                request.recognitionLanguages = langs;

            VNImageRequestHandler* handler =
                [[VNImageRequestHandler alloc] initWithCVPixelBuffer:buffer options:@{}];
            [handler performRequests:@[request] error:nil];

            for (VNRecognizedTextObservation* obs in request.results) {
                VNRecognizedText* best = [obs topCandidates:1].firstObject;
                if (!best || best.confidence < minConf)
                    continue;
                TextRegion region;
                region.text = best.string.UTF8String;
                region.confidence = (float)best.confidence;
                const CGRect b = obs.boundingBox;
                region.bbox[0] = (float)(b.origin.x + b.size.width * 0.5);
                region.bbox[1] = (float)(b.origin.y + b.size.height * 0.5);
                region.bbox[2] = (float)b.size.width;
                region.bbox[3] = (float)b.size.height;
                result.push_back(region);
            }
            CVPixelBufferRelease(buffer);
        }
        // 読み順: 上→下（v 降順）、同じ高さなら左→右（u 昇順）
        std::stable_sort(result.begin(), result.end(),
                         [](const TextRegion& a, const TextRegion& b) {
                             if (std::abs(a.bbox[1] - b.bbox[1]) > 0.02f)
                                 return a.bbox[1] > b.bbox[1];
                             return a.bbox[0] < b.bbox[0];
                         });
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
    std::vector<TextRegion> myRegions;
    int64_t myLastCookSeen = -1;
    bool myFlip = true;
    bool myAccurate = true;
    bool myCorrection = true;
    float myMinConfidence = 0.3f;
    std::string myLanguages;

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
    std::atomic<int> myRowCount{0}, myAnalyzeMs{0};
};

}   // namespace

// ------------------------------------------------------------------ entry points

extern "C" {

DLLEXPORT void
FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Visiontext");
    info->customOPInfo.opLabel->setString("Vision Text");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("VTX");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/VisionText/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new VisionTextDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete (VisionTextDAT*)instance;
}

}   // extern "C"
