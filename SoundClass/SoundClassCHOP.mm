// SoundClass CHOP — TouchDesigner カスタムオペレータ（macOS / Apple SoundAnalysis）
//
// オーディオ CHOP 入力（例: Audio Device In / Audio File In）をストリーム解析し、
// 音の分類（SNClassifySoundRequest・組込みモデルは笑い声/拍手/犬の鳴き声/警報音など
// 300種類以上）の信頼度をチャンネル出力する。独自の Core ML 音響分類モデル
// （.mlmodel / .mlmodelc）にも差し替え可能。
//
// 出力:
//   Classes パラメータに列挙したクラスID（空白区切り）ごとに1チャンネル（信頼度 0〜1）。
//   全クラスのランキング上位は Info DAT に出す（クラスIDを知らなくても Info DAT を
//   見ながら選べる）。
//
// 実装: execute() で入力オーディオを溜め、ワーカースレッドが AVAudioPCMBuffer に
// 詰めて SNAudioStreamAnalyzer へ流す。結果はウィンドウ間隔（既定1秒×overlap0.5=0.5秒毎）
// で更新され、チャンネルは最新値を保持する。cook はブロックしない。

#import <AVFAudio/AVFAudio.h>
#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>
#import <SoundAnalysis/SoundAnalysis.h>

#include <atomic>
#include <condition_variable>
#include <cstring>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

// SNResultsObserving の受け口（無名 namespace の C++ クラスへは void* で転送する）
@interface SoundClassObserverImpl : NSObject <SNResultsObserving>
@property (nonatomic, assign) void* owner;
@end

namespace {

struct Ranked
{
    std::string identifier;
    float confidence;
};

class SoundClassCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit SoundClassCHOP(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~SoundClassCHOP() override
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
        parseClasses(inputs->getParString("Classes"));
        info->numChannels = (int32_t)mySelected.size();
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t index, OP_String* name, const OP_Inputs*, void*) override
    {
        if (index < (int32_t)mySelected.size())
            name->setString(mySelected[index].c_str());
        else
            name->setString("class");
    }

    void execute(CHOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;

        // ワーカーへ渡す設定（変更検知はワーカー側）
        {
            std::lock_guard<std::mutex> lock(myMutex);
            myWindowSec = inputs->getParDouble("Windowsec");
            myOverlap = inputs->getParDouble("Overlap");
            const char* model = inputs->getParString("Model");
            myModelPath = model ? model : "";
        }

        // 入力オーディオ（ch0）を蓄積してワーカーへ
        const OP_CHOPInput* audio = inputs->getInputCHOP(0);
        if (active && audio && audio->numChannels > 0 && audio->numSamples > 0) {
            std::lock_guard<std::mutex> lock(myMutex);
            const float* src = audio->getChannelData(0);
            myPendingAudio.insert(myPendingAudio.end(), src, src + audio->numSamples);
            mySampleRate = audio->sampleRate;
            // 溜まりすぎ防止（解析が追いつかないときは古いものから捨てる）
            const size_t cap = (size_t)(mySampleRate * 10);
            if (myPendingAudio.size() > cap)
                myPendingAudio.erase(myPendingAudio.begin(),
                                     myPendingAudio.end() - cap);
            myCond.notify_one();
        }

        // 最新の信頼度を出力
        std::map<std::string, float> conf;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            conf = myConfidence;
        }
        for (size_t i = 0; i < mySelected.size(); i++) {
            auto it = conf.find(mySelected[i]);
            output->channels[i][0] = (active && it != conf.end()) ? it->second : 0.0f;
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Sound Class";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Classes");
            p.label = "Classes";
            p.page = "Sound Class";
            p.defaultValue = "applause cheering laughter music speech";
            manager->appendString(p);
        }
        {
            OP_StringParameter p("Model");
            p.label = "Custom Core ML Model";
            p.page = "Sound Class";
            manager->appendFile(p);
        }
        {
            OP_NumericParameter p("Windowsec");
            p.label = "Window (sec)";
            p.page = "Sound Class";
            p.defaultValues[0] = 1.0;
            p.minSliders[0] = 0.3;
            p.maxSliders[0] = 3.0;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Overlap");
            p.label = "Overlap Factor";
            p.page = "Sound Class";
            p.defaultValues[0] = 0.5;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 0.9;
            manager->appendFloat(p);
        }
    }

    // ---------------------------------------------------------- Info CHOP / DAT

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[3] = {"executes", "results", "samplerate"};
        float values[3] = {(float)myExecCount, (float)myResultCount, (float)mySampleRate};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    bool getInfoDATSize(OP_InfoDATSize* infoSize, void*) override
    {
        infoSize->rows = 1 + kRankRows;   // ヘッダ + 上位10クラス
        infoSize->cols = 2;
        infoSize->byColumn = false;
        return true;
    }

    void getInfoDATEntries(int32_t index, int32_t nEntries,
                           OP_InfoDATEntries* entries, void*) override
    {
        if (index == 0) {
            entries->values[0]->setString("identifier");
            entries->values[1]->setString("confidence");
            return;
        }
        std::lock_guard<std::mutex> lock(myMutex);
        const int r = index - 1;
        if (r < (int)myRanking.size()) {
            char buf[32];
            snprintf(buf, sizeof(buf), "%.3f", myRanking[r].confidence);
            entries->values[0]->setString(myRanking[r].identifier.c_str());
            entries->values[1]->setString(buf);
        } else {
            entries->values[0]->setString("");
            entries->values[1]->setString("");
        }
    }

    // 結果の受け口（observer から呼ばれる・解析スレッド上）
    void onResult(SNClassificationResult* result)
    {
        std::lock_guard<std::mutex> lock(myMutex);
        myRanking.clear();
        for (SNClassification* c in result.classifications) {
            const std::string id = c.identifier.UTF8String;
            const float conf = (float)c.confidence;
            myConfidence[id] = conf;
            if (myRanking.size() < kRankRows)
                myRanking.push_back({id, conf});
        }
        myResultCount++;
    }

private:
    static constexpr size_t kRankRows = 10;

    void parseClasses(const char* str)
    {
        mySelected.clear();
        if (!str)
            return;
        std::istringstream ss(str);
        std::string token;
        while (ss >> token)
            mySelected.push_back(token);
    }

    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        SNAudioStreamAnalyzer* analyzer = nil;
        SoundClassObserverImpl* observer = nil;
        AVAudioFormat* analyzerFormat = nil;
        double builtRate = 0, builtWindow = 0, builtOverlap = -1;
        std::string builtModel = "<none>";
        int64_t framePos = 0;

        while (true) {
            std::vector<float> chunk;
            double rate, window, overlap;
            std::string modelPath;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || !myPendingAudio.empty(); });
                if (myQuit)
                    return;
                chunk.swap(myPendingAudio);
                rate = mySampleRate;
                window = myWindowSec;
                overlap = myOverlap;
                modelPath = myModelPath;
            }
            if (rate <= 0 || chunk.empty())
                continue;

            @autoreleasepool {
                // 設定が変わったら解析器を作り直す
                if (!analyzer || rate != builtRate || window != builtWindow ||
                    overlap != builtOverlap || modelPath != builtModel) {
                    analyzer = nil;
                    SNClassifySoundRequest* request = makeRequest(modelPath);
                    if (request) {
                        request.windowDuration = CMTimeMakeWithSeconds(window, 48000);
                        request.overlapFactor = overlap;
                        AVAudioFormat* fmt = [[AVAudioFormat alloc]
                            initWithCommonFormat:AVAudioPCMFormatFloat32
                                      sampleRate:rate channels:1 interleaved:NO];
                        analyzerFormat = fmt;
                        analyzer = [[SNAudioStreamAnalyzer alloc] initWithFormat:fmt];
                        observer = [[SoundClassObserverImpl alloc] init];
                        observer.owner = this;
                        NSError* err = nil;
                        if (![analyzer addRequest:request withObserver:observer error:&err]) {
                            NSLog(@"SoundClassCHOP: addRequest failed: %@", err);
                            analyzer = nil;
                        }
                        builtRate = rate;
                        builtWindow = window;
                        builtOverlap = overlap;
                        builtModel = modelPath;
                        framePos = 0;
                    } else {
                        builtModel = modelPath;   // 失敗を繰り返さない
                    }
                }
                if (!analyzer)
                    continue;

                AVAudioPCMBuffer* buf =
                    [[AVAudioPCMBuffer alloc] initWithPCMFormat:analyzerFormat
                                                  frameCapacity:(AVAudioFrameCount)chunk.size()];
                if (!buf)
                    continue;
                memcpy(buf.floatChannelData[0], chunk.data(), chunk.size() * sizeof(float));
                buf.frameLength = (AVAudioFrameCount)chunk.size();
                [analyzer analyzeAudioBuffer:buf atAudioFramePosition:framePos];
                framePos += (int64_t)chunk.size();
            }
        }
    }

    SNClassifySoundRequest* makeRequest(const std::string& modelPath)
    {
        NSError* err = nil;
        if (!modelPath.empty()) {
            NSURL* url = [NSURL fileURLWithPath:
                          [NSString stringWithUTF8String:modelPath.c_str()]];
            // .mlmodel はその場でコンパイル（.mlmodelc はそのままロード）
            if ([url.pathExtension isEqualToString:@"mlmodel"]) {
                NSURL* compiled = [MLModel compileModelAtURL:url error:&err];
                if (!compiled) {
                    NSLog(@"SoundClassCHOP: model compile failed: %@", err);
                    return nil;
                }
                url = compiled;
            }
            MLModel* model = [MLModel modelWithContentsOfURL:url error:&err];
            if (!model) {
                NSLog(@"SoundClassCHOP: model load failed: %@", err);
                return nil;
            }
            SNClassifySoundRequest* request =
                [[SNClassifySoundRequest alloc] initWithMLModel:model error:&err];
            if (!request)
                NSLog(@"SoundClassCHOP: request(mlmodel) failed: %@", err);
            return request;
        }
        SNClassifySoundRequest* request = [[SNClassifySoundRequest alloc]
            initWithClassifierIdentifier:SNClassifierIdentifierVersion1 error:&err];
        if (!request)
            NSLog(@"SoundClassCHOP: request(v1) failed: %@", err);
        return request;
    }

    // ---------------------------------------------------------- state

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;

    std::vector<float> myPendingAudio;
    double mySampleRate = 0;
    double myWindowSec = 1.0;
    double myOverlap = 0.5;
    std::string myModelPath;

    std::vector<std::string> mySelected;
    std::map<std::string, float> myConfidence;
    std::vector<Ranked> myRanking;

    std::atomic<int> myExecCount{0}, myResultCount{0};
};

}   // namespace

@implementation SoundClassObserverImpl
- (void)request:(id<SNRequest>)request didProduceResult:(id<SNResult>)result
{
    if ([result isKindOfClass:[SNClassificationResult class]] && self.owner)
        ((SoundClassCHOP*)self.owner)->onResult((SNClassificationResult*)result);
}
- (void)request:(id<SNRequest>)request didFailWithError:(NSError*)error
{
    NSLog(@"SoundClassCHOP: analysis error: %@", error);
}
- (void)requestDidComplete:(id<SNRequest>)request
{
}
@end

// ------------------------------------------------------------------ entry points

extern "C" {

DLLEXPORT void
FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Soundclass");
    info->customOPInfo.opLabel->setString("Sound Class");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.opIcon->setString("SND");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/SoundClass/README.md");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT CHOP_CPlusPlusBase*
CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new SoundClassCHOP(info);
}

DLLEXPORT void
DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (SoundClassCHOP*)instance;
}

}   // extern "C"
