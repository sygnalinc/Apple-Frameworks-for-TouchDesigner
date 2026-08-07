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
bool fm_submit_structured(void* handle, const char* prompt, const char* schema,
                          double temperature, int32_t maxTokens, bool keepContext);
bool fm_submit(void* handle, const char* prompt, double temperature, int32_t maxTokens,
               bool keepContext);
bool fm_submit_tool(void* handle, const char* prompt, const char* toolName,
                    const char* toolDesc, const char* toolParams, double temperature,
                    int32_t maxTokens);
void fm_tool_result(void* handle, const char* resultJSON);
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

class AFMCoreDAT : public DAT_CPlusPlusBase
{
public:
    explicit AFMCoreDAT(const OP_NodeInfo*) {}

    ~AFMCoreDAT() override
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
            const char* schema = inputs->getParString("Schema");
            const bool useTools = inputs->getParInt("Enabletools") != 0;
            if (useTools) {
                // ツール呼び出し: LLM がツールを要求 → TD がツールを実行して結果を返す
                const char* tn = inputs->getParString("Toolname");
                const char* td = inputs->getParString("Tooldesc");
                const char* tp = inputs->getParString("Toolparams");
                fm_submit_tool(mySession, prompt ? prompt : "", tn ? tn : "",
                               td ? td : "", tp ? tp : "",
                               inputs->getParDouble("Temperature"),
                               (int32_t)inputs->getParInt("Maxtokens"));
            } else if (schema && *schema) {
                // 構造化出力: "name:type" 改行区切りのスキーマでJSONを生成させる
                fm_submit_structured(mySession, prompt ? prompt : "", schema,
                                     inputs->getParDouble("Temperature"),
                                     (int32_t)inputs->getParInt("Maxtokens"),
                                     inputs->getParInt("Keepcontext") != 0);
            } else {
                fm_submit(mySession, prompt ? prompt : "",
                          inputs->getParDouble("Temperature"),
                          (int32_t)inputs->getParInt("Maxtokens"),
                          inputs->getParInt("Keepcontext") != 0);
            }
        }
        // ツール結果の返却(Return Tool Result パルス、または Auto Tool Result 中で
        // pending_tool を検知したら Tool Result パラメータの内容を返す)
        if (myWantToolResult && mySession) {
            myWantToolResult = false;
            const char* tr = inputs->getParString("Toolresult");
            fm_tool_result(mySession, tr ? tr : "{}");
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

        // テーブル出力(構造化フィールド行 → 会話履歴の順)
        const int maxRows = std::max(1, (int)inputs->getParInt("Maxrows"));
        const int begin = std::max(0, (int)history.size() - maxRows);
        const int toolRows = myPendingTool.empty() ? 0 : 2;
        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize(
            1 + toolRows + (int32_t)myStructured.size() +
                (int32_t)(history.size() - begin), 3);
        output->setCellString(0, 0, "index");
        output->setCellString(0, 1, "role");
        output->setCellString(0, 2, "text");
        int32_t row = 1;
        if (toolRows) {
            // LLM がツール呼び出し待ち。TD 側はこの引数を見て Tool Result を返す
            output->setCellString(row, 0, "pending_tool");
            output->setCellString(row, 1, "tool");
            output->setCellString(row, 2, myPendingTool.c_str());
            row++;
            output->setCellString(row, 0, "pending_tool_args");
            output->setCellString(row, 1, "tool");
            output->setCellString(row, 2, myPendingToolArgs.c_str());
            row++;
        }
        for (auto& kv : myStructured) {
            output->setCellString(row, 0, kv.first.c_str());
            output->setCellString(row, 1, "field");
            output->setCellString(row, 2, kv.second.c_str());
            row++;
        }
        for (size_t r = begin; r < history.size(); r++) {
            char idx[16];
            snprintf(idx, sizeof(idx), "%d", (int)r);
            output->setCellString(row, 0, idx);
            output->setCellString(row, 1, history[r].role.c_str());
            output->setCellString(row, 2, history[r].text.c_str());
            row++;
        }
        myTurnCount = (int)history.size();
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Instructions");
            p.label = "Instructions (System)";
            p.page = "LLM AFM";
            manager->appendString(p);
        }
        {
            OP_StringParameter p("Prompt");
            p.label = "Prompt";
            p.page = "LLM AFM";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Temperature");
            p.label = "Temperature";
            p.page = "LLM AFM";
            p.defaultValues[0] = 0.7;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 2.0;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Maxtokens");
            p.label = "Max Tokens";
            p.page = "LLM AFM";
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
            p.page = "LLM AFM";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            // 構造化出力スキーマ("name:type" 改行区切り。type: string|number|int|bool)。
            // 空なら通常のテキスト生成
            OP_StringParameter p("Schema");
            p.label = "Output Schema (name:type)";
            p.page = "LLM AFM";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Maxrows");
            p.label = "Max Rows";
            p.page = "LLM AFM";
            p.defaultValues[0] = 50;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 200;
            manager->appendInt(p);
        }
        // ---- Tool Calling(TDがツール実行系になる)----
        {
            OP_NumericParameter p("Enabletools");
            p.label = "Enable Tool Calling";
            p.page = "Tools";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Toolname");
            p.label = "Tool Name";
            p.page = "Tools";
            p.defaultValue = "get_td_value";
            manager->appendString(p);
        }
        {
            OP_StringParameter p("Tooldesc");
            p.label = "Tool Description";
            p.page = "Tools";
            p.defaultValue = "Get a live value from the TouchDesigner project.";
            manager->appendString(p);
        }
        {
            // ツールの引数スキーマ("name:type" 改行/カンマ区切り)
            OP_StringParameter p("Toolparams");
            p.label = "Tool Params (name:type)";
            p.page = "Tools";
            p.defaultValue = "query:string";
            manager->appendString(p);
        }
        {
            // LLM がツールを呼んだとき、この文字列(JSON等)を結果として返す。
            // pending_tool_args を見て TD 側(Python等)が算出してこのパラメータに書く
            OP_StringParameter p("Toolresult");
            p.label = "Tool Result";
            p.page = "Tools";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Returntoolresult");
            p.label = "Return Tool Result";
            p.page = "Tools";
            manager->appendPulse(p);
        }
        {
            OP_NumericParameter p("Submit");
            p.label = "Submit";
            p.page = "LLM AFM";
            manager->appendPulse(p);
        }
        {
            OP_NumericParameter p("Clear");
            p.label = "Clear Conversation";
            p.page = "LLM AFM";
            manager->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Submit") == 0)
            myWantSubmit = true;
        else if (strcmp(name, "Clear") == 0)
            myWantClear = true;
        else if (strcmp(name, "Returntoolresult") == 0)
            myWantToolResult = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[4] = {"executes", "busy", "turns", "tool_pending"};
        float values[4] = {(float)myExecCount, (float)myBusy, (float)myTurnCount,
                           (float)(myPendingTool.empty() ? 0 : 1)};
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
            // ツール呼び出し待ち(pending_tool)を取り出す
            myPendingTool.clear();
            myPendingToolArgs.clear();
            NSString* pt = dict[@"pending_tool"];
            NSString* pa = dict[@"pending_tool_args"];
            if ([pt isKindOfClass:[NSString class]] && pt.length > 0)
                myPendingTool = pt.UTF8String ?: "";
            if ([pa isKindOfClass:[NSString class]])
                myPendingToolArgs = pa.UTF8String ?: "";
            // 構造化出力(key/value)を取り出してキー順で保持
            myStructured.clear();
            NSDictionary* st = dict[@"structured"];
            if ([st isKindOfClass:[NSDictionary class]]) {
                NSArray* keys =
                    [st.allKeys sortedArrayUsingSelector:@selector(compare:)];
                for (NSString* k in keys) {
                    NSString* v = [NSString stringWithFormat:@"%@", st[k]];
                    myStructured.push_back(
                        {k.UTF8String ?: "", v.UTF8String ?: ""});
                }
            }
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
    std::vector<std::pair<std::string, std::string>> myStructured;
    std::atomic<bool> myWantSubmit{false};
    std::atomic<bool> myWantClear{false};
    std::atomic<bool> myWantToolResult{false};
    std::string myStatus = "no session";
    std::string myPendingTool, myPendingToolArgs;
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
    info->customOPInfo.opType->setString("Llmafm");
    info->customOPInfo.opLabel->setString("LLM AFM");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("AFM");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/LLMAFM/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new AFMCoreDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete (AFMCoreDAT*)instance;
}

}   // extern "C"
