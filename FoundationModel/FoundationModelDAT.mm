// FoundationModel DAT — Apple Intelligence オンデバイスLLM（macOS 26+）
//
// Apple の FoundationModels framework（Apple Intelligence の ~3B オンデバイスLLM）で
// テキスト生成する TD カスタム DAT。完全オンデバイス・API課金なし・ネットワーク不要。
// 実装は同梱の libFMHelper.dylib（Swift・FoundationModels は Swift 専用API）が担う。
//
// 出力テーブル（会話履歴）:
//   index | role | text
//   user / assistant の行が交互に並び、生成中は最後の assistant 行が
//   ストリーミングで伸びていく。
//
// 使い方: Instructions にシステム指示、Prompt に入力を書いて Submit をパルス。
// Keep Context オンで会話の文脈を保持（マルチターン）。
// 端末で Apple Intelligence が有効である必要がある（Info DAT の status を確認）。

#import <Foundation/Foundation.h>

#include <atomic>
#include <cstring>
#include <string>
#include <vector>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

// libFMHelper.dylib（Swift）の C API
extern "C" {
void* fm_create(const char* instructions);
bool fm_submit(void* handle, const char* prompt, double temperature, int32_t maxTokens,
               bool keepContext);
int32_t fm_poll(void* handle, char* buffer, int32_t capacity);
void fm_clear(void* handle);
void fm_destroy(void* handle);
}

namespace {

struct Turn
{
    std::string role;
    std::string text;
};

class FoundationModelDAT : public DAT_CPlusPlusBase
{
public:
    explicit FoundationModelDAT(const OP_NodeInfo*) {}

    ~FoundationModelDAT() override
    {
        if (mySession)
            fm_destroy(mySession);
    }

    void getGeneralInfo(DAT_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const char* instPar = inputs->getParString("Instructions");
        const std::string instructions = instPar ? instPar : "";

        // Instructions 変更（または初回）でセッションを作り直す
        if (!mySession || instructions != myInstructions) {
            if (mySession)
                fm_destroy(mySession);
            mySession = fm_create(instructions.c_str());
            myInstructions = instructions;
        }

        // Submit パルス
        if (myWantSubmit && mySession) {
            myWantSubmit = false;
            const char* prompt = inputs->getParString("Prompt");
            fm_submit(mySession, prompt ? prompt : "",
                      inputs->getParDouble("Temperature"),
                      (int32_t)inputs->getParInt("Maxtokens"),
                      inputs->getParInt("Keepcontext") != 0);
        }
        if (myWantClear && mySession) {
            myWantClear = false;
            fm_clear(mySession);
        }

        // 状態と履歴を取得
        myStatus = "no session";
        std::vector<Turn> history;
        if (mySession) {
            static thread_local std::vector<char> buf(262144);
            fm_poll(mySession, buf.data(), (int32_t)buf.size());
            parsePoll(buf.data(), history);
        }

        // テーブル出力
        const int maxRows = std::max(1, (int)inputs->getParInt("Maxrows"));
        const int begin = std::max(0, (int)history.size() - maxRows);
        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize(1 + (int32_t)(history.size() - begin), 3);
        output->setCellString(0, 0, "index");
        output->setCellString(0, 1, "role");
        output->setCellString(0, 2, "text");
        for (size_t r = begin; r < history.size(); r++) {
            char idx[16];
            snprintf(idx, sizeof(idx), "%d", (int)r);
            const int32_t row = (int32_t)(r - begin) + 1;
            output->setCellString(row, 0, idx);
            output->setCellString(row, 1, history[r].role.c_str());
            output->setCellString(row, 2, history[r].text.c_str());
        }
        myTurnCount = (int)history.size();
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Instructions");
            p.label = "Instructions (System)";
            p.page = "Foundation Model";
            manager->appendString(p);
        }
        {
            OP_StringParameter p("Prompt");
            p.label = "Prompt";
            p.page = "Foundation Model";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Temperature");
            p.label = "Temperature";
            p.page = "Foundation Model";
            p.defaultValues[0] = 0.7;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 2.0;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Maxtokens");
            p.label = "Max Tokens";
            p.page = "Foundation Model";
            p.defaultValues[0] = 512;
            p.minSliders[0] = 16;
            p.maxSliders[0] = 2048;
            p.minValues[0] = 1;
            p.clampMins[0] = true;
            manager->appendInt(p);
        }
        {
            OP_NumericParameter p("Keepcontext");
            p.label = "Keep Context (Multi-turn)";
            p.page = "Foundation Model";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Maxrows");
            p.label = "Max Rows";
            p.page = "Foundation Model";
            p.defaultValues[0] = 50;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 200;
            manager->appendInt(p);
        }
        {
            OP_NumericParameter p("Submit");
            p.label = "Submit";
            p.page = "Foundation Model";
            manager->appendPulse(p);
        }
        {
            OP_NumericParameter p("Clear");
            p.label = "Clear Conversation";
            p.page = "Foundation Model";
            manager->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Submit") == 0)
            myWantSubmit = true;
        else if (strcmp(name, "Clear") == 0)
            myWantClear = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[3] = {"executes", "busy", "turns"};
        float values[3] = {(float)myExecCount, (float)myBusy, (float)myTurnCount};
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
    void parsePoll(const char* json, std::vector<Turn>& history)
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
            myBusy = [dict[@"busy"] boolValue] ? 1 : 0;
            NSArray* hist = dict[@"history"];
            if ([hist isKindOfClass:[NSArray class]]) {
                for (NSDictionary* turn in hist) {
                    if (![turn isKindOfClass:[NSDictionary class]])
                        continue;
                    Turn t;
                    NSString* role = turn[@"role"];
                    NSString* text = turn[@"text"];
                    if ([role isKindOfClass:[NSString class]])
                        t.role = role.UTF8String;
                    if ([text isKindOfClass:[NSString class]])
                        t.text = text.UTF8String;
                    history.push_back(t);
                }
            }
        }
    }

    void* mySession = nullptr;
    std::string myInstructions = "\x01uninit";   // 初回に必ず作り直すための番兵
    std::atomic<bool> myWantSubmit{false};
    std::atomic<bool> myWantClear{false};
    std::string myStatus = "no session";
    int myBusy = 0;
    int myTurnCount = 0;
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
    info->customOPInfo.opType->setString("Foundationmodel");
    info->customOPInfo.opLabel->setString("Foundation Model");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("AFM");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new FoundationModelDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete (FoundationModelDAT*)instance;
}

}   // extern "C"
