// Translate DAT — オンデバイス翻訳（macOS 15+ / Translation framework）
//
// 入力 DAT のテキストをオンデバイス翻訳してテーブル出力する TD カスタム DAT。
// SpeechText DAT（ライブ文字起こし）を入力に繋ぐと**リアルタイム字幕翻訳**になる。
//
// 動作:
//   入力 DAT あり: ヘッダに "text" 列があればその列、無ければ列0を翻訳し、
//                  同じ形のテーブルで出力（対象列を訳文に差し替え。翻訳中は空文字）。
//                  訳文はキャッシュされ、同じ原文を再翻訳しない
//   入力 DAT なし: Text パラメータを翻訳して 1 行（source | target）で出力
//
// 言語モデルが未導入のペアは初回にダウンロードが走る（Info DAT の status 参照）。

#import <Foundation/Foundation.h>

#include <atomic>
#include <cstring>
#include <string>
#include <vector>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

// libTrHelper.dylib（Swift）の C API
extern "C" {
void* tr_create(void);
void tr_set_languages(void* handle, const char* src, const char* tgt);
void tr_submit(void* handle, const char* text);
int32_t tr_get(void* handle, const char* text, char* buffer, int32_t capacity);
int32_t tr_status(void* handle, char* buffer, int32_t capacity);
void tr_clear(void* handle);
void tr_destroy(void* handle);
}

namespace {

// Apple Translation framework の対応言語（Apple翻訳アプリと同一セット）
static const char* kLangCodes[] = {
    "ja", "en", "en-GB", "zh-Hans", "zh-Hant", "ko", "es", "fr", "de", "it",
    "pt-BR", "ru", "ar", "nl", "th", "vi", "pl", "tr", "id", "hi", "uk",
};
static const char* kLangLabels[] = {
    "Japanese (ja)", "English US (en)", "English UK (en-GB)",
    "Chinese Simplified (zh-Hans)", "Chinese Traditional (zh-Hant)",
    "Korean (ko)", "Spanish (es)", "French (fr)", "German (de)", "Italian (it)",
    "Portuguese BR (pt-BR)", "Russian (ru)", "Arabic (ar)", "Dutch (nl)",
    "Thai (th)", "Vietnamese (vi)", "Polish (pl)", "Turkish (tr)",
    "Indonesian (id)", "Hindi (hi)", "Ukrainian (uk)",
};
constexpr int kNumLangs = sizeof(kLangCodes) / sizeof(kLangCodes[0]);

class TranslateDAT : public DAT_CPlusPlusBase
{
public:
    explicit TranslateDAT(const OP_NodeInfo*) {}

    ~TranslateDAT() override
    {
        if (mySession)
            tr_destroy(mySession);
    }

    void getGeneralInfo(DAT_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;

        if (!mySession)
            mySession = tr_create();
        if (mySession) {
            const char* src = inputs->getParString("Sourcelang");
            const char* tgt = inputs->getParString("Targetlang");
            tr_set_languages(mySession, src ? src : "ja", tgt ? tgt : "en");
        }
        if (myWantClear && mySession) {
            myWantClear = false;
            tr_clear(mySession);
        }

        // 状態
        {
            char buf[512] = "no session";
            if (mySession)
                tr_status(mySession, buf, sizeof(buf));
            myStatus = buf;
        }

        static thread_local std::vector<char> tbuf(65536);
        const OP_DATInput* in = inputs->getInputDAT(0);

        if (in && in->numRows > 0 && in->numCols > 0) {
            // ---- 入力 DAT モード: "text" 列（無ければ列0）を翻訳して同形出力
            int textCol = 0;
            bool hasHeader = false;
            for (int c = 0; c < in->numCols; c++) {
                if (strcmp(in->getCell(0, c), "text") == 0) {
                    textCol = c;
                    hasHeader = true;
                    break;
                }
            }
            output->setOutputDataType(DAT_OutDataType::Table);
            output->setTableSize(in->numRows, in->numCols);
            const int firstRow = hasHeader ? 1 : 0;
            for (int r = 0; r < in->numRows; r++) {
                for (int c = 0; c < in->numCols; c++) {
                    const char* cell = in->getCell(r, c);
                    if (active && mySession && r >= firstRow && c == textCol &&
                        cell && cell[0]) {
                        tr_submit(mySession, cell);
                        const int state = tr_get(mySession, cell, tbuf.data(),
                                                 (int32_t)tbuf.size());
                        output->setCellString(r, c, state == 2 ? tbuf.data() : "");
                    } else {
                        output->setCellString(r, c, cell ? cell : "");
                    }
                }
            }
        } else {
            // ---- パラメータモード: Text を翻訳して 1 行
            const char* text = inputs->getParString("Text");
            const std::string source = text ? text : "";
            std::string target;
            if (active && mySession && !source.empty()) {
                tr_submit(mySession, source.c_str());
                const int state = tr_get(mySession, source.c_str(), tbuf.data(),
                                         (int32_t)tbuf.size());
                if (state == 2)
                    target = tbuf.data();
            }
            output->setOutputDataType(DAT_OutDataType::Table);
            output->setTableSize(2, 2);
            output->setCellString(0, 0, "source");
            output->setCellString(0, 1, "target");
            output->setCellString(1, 0, source.c_str());
            output->setCellString(1, 1, target.c_str());
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Translate";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Sourcelang");
            p.label = "Source Language";
            p.page = "Translate";
            p.defaultValue = "ja";
            manager->appendMenu(p, kNumLangs, kLangCodes, kLangLabels);
        }
        {
            OP_StringParameter p("Targetlang");
            p.label = "Target Language";
            p.page = "Translate";
            p.defaultValue = "en";
            manager->appendMenu(p, kNumLangs, kLangCodes, kLangLabels);
        }
        {
            OP_StringParameter p("Text");
            p.label = "Text (No-Input Mode)";
            p.page = "Translate";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Clearcache");
            p.label = "Clear Cache";
            p.page = "Translate";
            manager->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Clearcache") == 0)
            myWantClear = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 1; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        chan->name->setString("executes");
        chan->value = (float)myExecCount;
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
    void* mySession = nullptr;
    std::atomic<bool> myWantClear{false};
    std::string myStatus = "no session";
    std::atomic<int> myExecCount{0};
};

}   // namespace

// ------------------------------------------------------------------ entry points

extern "C" {

DLLEXPORT void
FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Translate");
    info->customOPInfo.opLabel->setString("Translate");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.opIcon->setString("TRN");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/Translate/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new TranslateDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete (TranslateDAT*)instance;
}

}   // extern "C"
