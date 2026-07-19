// TextAnalyze DAT — TouchDesigner カスタムオペレータ(macOS / NaturalLanguage)
//
// 入力 DAT のテキストをオンデバイスで解析する:
//   感情スコア(NLTagSchemeSentimentScore・-1〜+1)
//   言語判定(NLLanguageRecognizer)
//   固有表現(人名/地名/組織名・NLTagSchemeNameType)
//   参照テキストとの意味的類似度(NLEmbedding 文埋め込み・コサイン距離)
//
// SpeechText(文字起こし)→ TextAnalyze で「発話の感情・話題でビジュアル制御」、
// Reference Text との類似度で「特定の話題に近づいたら発火」ができる。
// VisionSimilarity(画像の類似トリガー)のテキスト版。
//
// 出力テーブル: key / value(language, sentiment, similarity, words + 固有表現の行)
// 数値は Info CHOP(sentiment / similarity / entities)からも取れる。
//
// 実装: 解析はワーカースレッドで非同期(埋め込みの初回ロードがあるため)。
// テキスト内容が変わったときだけ再解析する。

#import <Foundation/Foundation.h>
#import <NaturalLanguage/NaturalLanguage.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

struct AnalysisResult
{
    std::vector<std::pair<std::string, std::string>> rows;   // key / value
    float sentiment = 0;
    float similarity = 0;
    int entities = 0;
    bool valid = false;
};

static std::string nsstr(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }

class TextAnalyzeDAT final : public DAT_CPlusPlusBase
{
public:
    explicit TextAnalyzeDAT(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }

    ~TextAnalyzeDAT() override
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
        const bool lastRow = strcmp(inputs->getParString("Textsource"), "lastrow") == 0;
        std::string ref;
        if (const char* r = inputs->getParString("Referencetext"))
            ref = r;

        // 入力 DAT からテキストを取り出す("text"列があればその列、無ければ最終列)
        std::string text;
        const OP_DATInput* in = inputs->getInputDAT(0);
        if (in && in->numRows > 0 && in->numCols > 0) {
            int col = in->numCols - 1;
            for (int c = 0; c < in->numCols; c++) {
                if (strcmp(in->getCell(0, c), "text") == 0) {
                    col = c;
                    break;
                }
            }
            const int startRow = (in->numRows > 1 && in->isTable) ? 1 : 0;   // ヘッダ行を飛ばす
            if (lastRow) {
                if (in->numRows > startRow)
                    text = in->getCell(in->numRows - 1, col);
            } else {
                for (int r = startRow; r < in->numRows; r++) {
                    const char* cell = in->getCell(r, col);
                    if (cell && *cell) {
                        if (!text.empty())
                            text += "\n";
                        text += cell;
                    }
                }
            }
        }

        // テキスト/参照/取り出し方が変わったときだけ再解析
        if (active) {
            std::unique_lock<std::mutex> lock(myMutex, std::try_to_lock);
            if (lock.owns_lock() && !myBusy &&
                (text != myLastText || ref != myLastRef)) {
                myLastText = text;
                myLastRef = ref;
                myPendingText = text;
                myPendingRef = ref;
                myHasPending = true;
                mySubmitCount++;
                lock.unlock();
                myCond.notify_one();
            }
        }

        AnalysisResult res;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            res = myResult;
        }
        if (!active)
            res.rows.clear();

        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize((int32_t)res.rows.size() + 1, 2);
        output->setCellString(0, 0, "key");
        output->setCellString(0, 1, "value");
        for (int i = 0; i < (int)res.rows.size(); i++) {
            output->setCellString(i + 1, 0, res.rows[i].first.c_str());
            output->setCellString(i + 1, 1, res.rows[i].second.c_str());
        }
        mySentiment = res.sentiment;
        mySimilarity = res.similarity;
        myEntities = res.entities;
        myValid = res.valid ? 1 : 0;
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Text Analyze";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Textsource");
            p.label = "Text Source";
            p.page = "Text Analyze";
            p.defaultValue = "lastrow";
            const char* names[] = {"lastrow", "allrows"};
            const char* labels[] = {"Last Row (Live Captions)", "All Rows"};
            manager->appendMenu(p, 2, names, labels);
        }
        {
            OP_StringParameter p("Referencetext");
            p.label = "Reference Text";
            p.page = "Text Analyze";
            manager->appendString(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 7; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[7] = {"executes", "submits", "analyzes", "analyze_ms",
                                "sentiment", "similarity", "entities"};
        float values[7] = {(float)myExecCount, (float)mySubmitCount, (float)myAnalyzeCount,
                           myAnalyzeMs.load(), mySentiment.load(), mySimilarity.load(),
                           (float)myEntities.load()};
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
    // ---------------------------------------------------------- worker

    void workerLoop()
    {
        while (true) {
            std::string text, ref;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                text = std::move(myPendingText);
                ref = std::move(myPendingRef);
                myHasPending = false;
                myBusy = true;
            }
            AnalysisResult res;
            std::string warning;
            const auto t0 = std::chrono::steady_clock::now();
            analyze(text, ref, res, warning);
            myAnalyzeMs = std::chrono::duration<float, std::milli>(
                              std::chrono::steady_clock::now() - t0).count();
            myAnalyzeCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                myResult = std::move(res);
                myWarning = std::move(warning);
                myBusy = false;
            }
        }
    }

    void analyze(const std::string& text, const std::string& ref, AnalysisResult& res,
                 std::string& warning)
    {
        if (text.empty())
            return;
        @autoreleasepool {
            NSString* nstext = [NSString stringWithUTF8String:text.c_str()];
            if (!nstext)
                return;

            // 言語判定
            NLLanguageRecognizer* rec = [[NLLanguageRecognizer alloc] init];
            [rec processString:nstext];
            NLLanguage lang = rec.dominantLanguage;
            res.rows.push_back({"language", lang ? nsstr(lang) : "unknown"});

            // 感情スコア(段落ごとの平均。日本語など未対応言語は 0 のまま)
            NLTagger* tagger = [[NLTagger alloc]
                initWithTagSchemes:@[NLTagSchemeSentimentScore, NLTagSchemeNameType,
                                     NLTagSchemeTokenType]];
            tagger.string = nstext;
            __block double sum = 0;
            __block int cnt = 0;
            [tagger enumerateTagsInRange:NSMakeRange(0, nstext.length)
                                    unit:NLTokenUnitParagraph
                                  scheme:NLTagSchemeSentimentScore
                                 options:0
                              usingBlock:^(NLTag tag, NSRange, BOOL*) {
                                  if (tag) {
                                      sum += tag.doubleValue;
                                      cnt++;
                                  }
                              }];
            res.sentiment = cnt ? (float)(sum / cnt) : 0.0f;
            char buf[32];
            snprintf(buf, sizeof(buf), "%.4f", res.sentiment);
            res.rows.push_back({"sentiment", buf});

            // 参照テキストとの意味的類似度。
            // 第一候補: NLContextualEmbedding(BERT系・macOS 14+・日本語対応)。
            // 使えない言語/OSでは NLEmbedding の文埋め込み(英語等)へフォールバック
            if (!ref.empty()) {
                NSString* nsref = [NSString stringWithUTF8String:ref.c_str()];
                bool done = false;
                if (@available(macOS 14.0, *)) {
                    double sim = 0;
                    std::string ctxWarn;
                    if (nsref && contextualSimilarity(nstext, nsref, lang, sim, ctxWarn)) {
                        res.similarity = (float)sim;
                        snprintf(buf, sizeof(buf), "%.4f", res.similarity);
                        res.rows.push_back({"similarity", buf});
                        done = true;
                    } else if (!ctxWarn.empty()) {
                        warning = ctxWarn;   // アセットDL中など。次回以降に成立する
                        done = true;
                    }
                }
                if (!done) {
                    NLEmbedding* emb = embeddingForLanguage(lang);
                    if (emb && nsref) {
                        const double dist =
                            [emb distanceBetweenString:nstext
                                             andString:nsref
                                          distanceType:NLDistanceTypeCosine];
                        res.similarity = (float)(1.0 - dist / 2.0);
                        snprintf(buf, sizeof(buf), "%.4f", res.similarity);
                        res.rows.push_back({"similarity", buf});
                    } else {
                        warning = "Embedding unavailable for language: " +
                                  (lang ? nsstr(lang) : "unknown");
                    }
                }
            }

            // 語数
            __block int words = 0;
            [tagger enumerateTagsInRange:NSMakeRange(0, nstext.length)
                                    unit:NLTokenUnitWord
                                  scheme:NLTagSchemeTokenType
                                 options:NLTaggerOmitWhitespace | NLTaggerOmitPunctuation
                              usingBlock:^(NLTag, NSRange, BOOL*) { words++; }];
            snprintf(buf, sizeof(buf), "%d", words);
            res.rows.push_back({"words", buf});

            // 固有表現(人名/地名/組織名)
            __block std::vector<std::pair<std::string, std::string>> ents;
            [tagger enumerateTagsInRange:NSMakeRange(0, nstext.length)
                                    unit:NLTokenUnitWord
                                  scheme:NLTagSchemeNameType
                                 options:NLTaggerOmitWhitespace | NLTaggerOmitPunctuation |
                                         NLTaggerJoinNames
                              usingBlock:^(NLTag tag, NSRange range, BOOL*) {
                                  if (!tag)
                                      return;
                                  const char* kind = nullptr;
                                  if ([tag isEqualToString:NLTagPersonalName])
                                      kind = "person";
                                  else if ([tag isEqualToString:NLTagPlaceName])
                                      kind = "place";
                                  else if ([tag isEqualToString:NLTagOrganizationName])
                                      kind = "organization";
                                  if (kind)
                                      ents.push_back(
                                          {kind, nsstr([nstext substringWithRange:range])});
                              }];
            res.entities = (int)ents.size();
            for (auto& e : ents)
                res.rows.push_back(std::move(e));

            res.valid = true;
        }
    }

    // NLContextualEmbedding(BERT系)で平均プーリング→コサイン類似度。
    // 戻り値 true=計算成功。アセット未取得時は warning を入れて true(DL開始済み)
    API_AVAILABLE(macos(14.0))
    bool contextualSimilarity(NSString* a, NSString* b, NLLanguage lang, double& simOut,
                              std::string& warn)
    {
        NLLanguage use = lang ?: NLLanguageEnglish;
        if (!myCtxEmb || ![myCtxLang isEqualToString:use]) {
            NLContextualEmbedding* e =
                [NLContextualEmbedding contextualEmbeddingWithLanguage:use];
            if (!e)
                return false;   // 言語非対応 → フォールバックへ
            if (!e.hasAvailableAssets) {
                [e requestEmbeddingAssetsWithCompletionHandler:^(
                     NLContextualEmbeddingAssetsResult, NSError*) {}];
                warn = "Downloading embedding assets for " + nsstr(use) + "...";
                return true;    // DL開始。次回以降のテキスト変化で成立する
            }
            if (![e loadWithError:nil])
                return false;
            myCtxEmb = e;
            myCtxLang = use;
        }
        std::vector<double> va, vb;
        if (!meanVector(a, va) || !meanVector(b, vb) || va.size() != vb.size() ||
            va.empty())
            return false;
        double dot = 0, na = 0, nb = 0;
        for (size_t i = 0; i < va.size(); i++) {
            dot += va[i] * vb[i];
            na += va[i] * va[i];
            nb += vb[i] * vb[i];
        }
        if (na <= 0 || nb <= 0)
            return false;
        simOut = dot / (sqrt(na) * sqrt(nb));   // コサイン類似度 -1〜1
        return true;
    }

    API_AVAILABLE(macos(14.0))
    bool meanVector(NSString* text, std::vector<double>& out)
    {
        NSError* err = nil;
        NLContextualEmbeddingResult* r =
            [myCtxEmb embeddingResultForString:text language:myCtxLang error:&err];
        if (!r)
            return false;
        out.assign((size_t)myCtxEmb.dimension, 0.0);
        __block int count = 0;
        std::vector<double>* acc = &out;
        [r enumerateTokenVectorsInRange:NSMakeRange(0, text.length)
                             usingBlock:^(NSArray<NSNumber*>* vec, NSRange, BOOL*) {
                                 const size_t n =
                                     std::min((size_t)vec.count, acc->size());
                                 for (size_t i = 0; i < n; i++)
                                     (*acc)[i] += vec[i].doubleValue;
                                 count++;
                             }];
        if (count == 0)
            return false;
        for (auto& v : out)
            v /= count;
        return true;
    }

    // 言語ごとの文埋め込みをキャッシュ(初回ロードが重い)
    NLEmbedding* embeddingForLanguage(NLLanguage lang)
    {
        NLLanguage use = lang ?: NLLanguageEnglish;
        if (myEmbedding && [myEmbeddingLang isEqualToString:use])
            return myEmbedding;
        NLEmbedding* e = [NLEmbedding sentenceEmbeddingForLanguage:use];
        if (!e && ![use isEqualToString:NLLanguageEnglish])
            e = [NLEmbedding sentenceEmbeddingForLanguage:NLLanguageEnglish];
        myEmbedding = e;
        myEmbeddingLang = use;
        return e;
    }

    // ---------------------------------------------------------- state

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;
    bool myHasPending = false;
    bool myBusy = false;
    std::string myPendingText, myPendingRef;
    std::string myLastText = "\x01";   // 初回必ず不一致にする
    std::string myLastRef;
    AnalysisResult myResult;
    std::string myWarning;

    // ワーカー専用
    NLEmbedding* myEmbedding = nil;
    NLLanguage myEmbeddingLang = nil;
    NLContextualEmbedding* myCtxEmb API_AVAILABLE(macos(14.0)) = nil;
    NLLanguage myCtxLang = nil;

    std::atomic<int> myExecCount{0}, mySubmitCount{0}, myAnalyzeCount{0};
    std::atomic<int> myEntities{0}, myValid{0};
    std::atomic<float> myAnalyzeMs{0.0f}, mySentiment{0.0f}, mySimilarity{0.0f};
};

}   // namespace

// ------------------------------------------------------------------ entry points

extern "C" {

DLLEXPORT void
FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Textanalyze");
    info->customOPInfo.opLabel->setString("Apple Text Analyze");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("TXA");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new TextAnalyzeDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete static_cast<TextAnalyzeDAT*>(instance);
}

}   // extern "C"
