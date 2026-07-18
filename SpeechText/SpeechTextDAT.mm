// SpeechText DAT — TouchDesigner カスタムオペレータ（macOS / Speech）
//
// Audio パラメータで指定したオーディオ CHOP をライブ文字起こしし、テーブルで出力する。
// 認識エンジンは新しい SpeechAnalyzer / SpeechTranscriber（macOS 26+・完全オンデバイス・
// 音声認識の TCC 許可不要）。実装は同梱の libSpeechHelper.dylib（Swift）が担う。
//
// 出力テーブル:
//   index | text | final
//   確定したセグメントが1行ずつ並び、最終行に認識途中のテキスト（final=0）が出る。
//   Max Rows を超えた古い確定行は捨てる。
//
// 初回はロケールの言語モデルダウンロードが走る（Info DAT の status に "downloading model"）。

#import <Foundation/Foundation.h>

#include <atomic>
#include <string>
#include <vector>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

// libSpeechHelper.dylib（Swift）の C API
extern "C" {
void* sp_create(const char* locale);
void sp_feed(void* handle, const float* samples, int32_t count, double rate);
int32_t sp_poll(void* handle, char* buffer, int32_t capacity);
void sp_clear(void* handle);
void sp_destroy(void* handle);
}

namespace {

class SpeechTextDAT : public DAT_CPlusPlusBase
{
public:
    explicit SpeechTextDAT(const OP_NodeInfo*) {}

    ~SpeechTextDAT() override
    {
        if (mySession)
            sp_destroy(mySession);
    }

    void getGeneralInfo(DAT_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        const char* localePar = inputs->getParString("Locale");
        const std::string locale = localePar ? localePar : "ja-JP";
        const int maxRows = std::max(1, (int)inputs->getParInt("Maxrows"));

        // ロケール変更（または初回）でセッションを作り直す
        if (active && (!mySession || locale != myLocale)) {
            if (mySession)
                sp_destroy(mySession);
            mySession = sp_create(locale.c_str());
            myLocale = locale;
        }

        // 入力オーディオ（ch0）を流し込む
        const OP_CHOPInput* audio = inputs->getParCHOP("Audio");
        if (active && mySession && audio && audio->numChannels > 0 && audio->numSamples > 0) {
            sp_feed(mySession, audio->getChannelData(0), audio->numSamples,
                    audio->sampleRate);
        }

        // 最新の認識結果を取得
        myStatus = "inactive";
        std::vector<std::string> finalized;
        std::string volatileText;
        if (mySession) {
            char buf[65536];
            sp_poll(mySession, buf, sizeof(buf));
            parsePoll(buf, finalized, volatileText);
        }

        // テーブル出力: header + 確定行(最大 maxRows) + 認識途中行
        const int begin = std::max(0, (int)finalized.size() - maxRows);
        const int nFinal = (int)finalized.size() - begin;
        const bool hasVolatile = !volatileText.empty();
        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize(1 + nFinal + (hasVolatile ? 1 : 0), 3);
        output->setCellString(0, 0, "index");
        output->setCellString(0, 1, "text");
        output->setCellString(0, 2, "final");
        for (int i = 0; i < nFinal; i++) {
            char idx[16];
            snprintf(idx, sizeof(idx), "%d", begin + i);
            output->setCellString(1 + i, 0, idx);
            output->setCellString(1 + i, 1, finalized[begin + i].c_str());
            output->setCellString(1 + i, 2, "1");
        }
        if (hasVolatile) {
            char idx[16];
            snprintf(idx, sizeof(idx), "%d", (int)finalized.size());
            const int r = 1 + nFinal;
            output->setCellString(r, 0, idx);
            output->setCellString(r, 1, volatileText.c_str());
            output->setCellString(r, 2, "0");
        }
        myFinalCount = (int)finalized.size();
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Audio");
            p.label = "Audio CHOP";
            p.page = "Speech";
            manager->appendCHOP(p);
        }
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Speech";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Locale");
            p.label = "Locale";
            p.page = "Speech";
            p.defaultValue = "ja-JP";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Maxrows");
            p.label = "Max Rows";
            p.page = "Speech";
            p.defaultValues[0] = 50;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 500;
            manager->appendInt(p);
        }
        {
            OP_NumericParameter p("Clear");
            p.label = "Clear Transcript";
            p.page = "Speech";
            manager->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Clear") == 0 && mySession)
            sp_clear(mySession);
    }

    int32_t getNumInfoCHOPChans(void*) override { return 2; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[2] = {"executes", "finalized"};
        float values[2] = {(float)myExecCount, (float)myFinalCount};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    bool getInfoDATSize(OP_InfoDATSize* infoSize, void*) override
    {
        infoSize->rows = 1;
        infoSize->cols = 2;
        infoSize->byColumn = false;
        return true;
    }

    void getInfoDATEntries(int32_t, int32_t, OP_InfoDATEntries* entries, void*) override
    {
        entries->values[0]->setString("status");
        entries->values[1]->setString(myStatus.c_str());
    }

private:
    // sp_poll の JSON（{status, volatile, finalized:[...]}）をほどく
    void parsePoll(const char* json, std::vector<std::string>& finalized,
                   std::string& volatileText)
    {
        @autoreleasepool {
            NSData* data = [NSData dataWithBytes:json length:strlen(json)];
            NSDictionary* dict = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0 error:nil];
            if (![dict isKindOfClass:[NSDictionary class]])
                return;
            NSString* status = dict[@"status"];
            if ([status isKindOfClass:[NSString class]])
                myStatus = status.UTF8String;
            NSString* vol = dict[@"volatile"];
            if ([vol isKindOfClass:[NSString class]])
                volatileText = vol.UTF8String;
            NSArray* fin = dict[@"finalized"];
            if ([fin isKindOfClass:[NSArray class]]) {
                for (NSString* s in fin) {
                    if ([s isKindOfClass:[NSString class]])
                        finalized.push_back(s.UTF8String);
                }
            }
        }
    }

    void* mySession = nullptr;
    std::string myLocale;
    std::string myStatus = "inactive";
    std::atomic<int> myExecCount{0};
    int myFinalCount = 0;
};

}   // namespace

// ------------------------------------------------------------------ entry points

extern "C" {

DLLEXPORT void
FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Speechtext");
    info->customOPInfo.opLabel->setString("Speech Text");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("SPT");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new SpeechTextDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete (SpeechTextDAT*)instance;
}

}   // extern "C"
