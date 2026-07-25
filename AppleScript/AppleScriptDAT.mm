// AppleScript DAT — TouchDesigner カスタムオペレータ(macOS)
//
// **AppleScript / JavaScript(JXA)を TD から実行**する汎用オートメーションDAT。
// `osascript` 経由。他アプリ制御(Music/Finder/メール等)、システム情報取得、ワークフロー自動化など、
// macOS のスクリプティングで出来ることを TD のイベント(パルス)から叩ける。**結果テキストも受け取れる**。
//
// スクリプトの与え方:
//   - **入力DAT**を接続するとその中身(全セルを改行連結)がスクリプトになる(複数行に最適・優先)
//   - または **Script** パラメータ(短い1行スクリプト用)
//
// 画面(出力テーブル)は常に status/情報を表示: status / result / error / took_ms / language。
//
// 重要(権限):
//   他アプリを操作するスクリプト(`tell application "Music" ...` 等)は macOS の
//   **Automation権限(TCC)**が要る。TouchDesigner から実行するので、初回に
//   「TouchDesigner が <アプリ> を制御しようとしています」の許可ダイアログが出る(許可が必要)。
//   純粋な計算・システム情報取得は権限不要。権限が無いと error 列に理由が出る。
//
// 実装: 実行はワーカースレッド(NSTask osascript・スクリプトは stdin へ流す)。cook はブロックしない。

#import <Foundation/Foundation.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

static std::string nsstr(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }

class AppleScriptDAT final : public DAT_CPlusPlusBase
{
public:
    explicit AppleScriptDAT(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
    }
    ~AppleScriptDAT() override
    {
        { std::lock_guard<std::mutex> lock(myMutex); myQuit = true; }
        myCond.notify_all();
        if (myWorker.joinable()) myWorker.join();
    }

    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override
    { g->cookEveryFrameIfAsked = true; }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        // スクリプト: 入力DATがあればそれを優先(全セルを改行連結)、なければ Script パラメータ
        std::string script, lang;
        const OP_DATInput* in = inputs->getInputDAT(0);
        if (in && in->numRows > 0 && in->numCols > 0) {
            for (int r = 0; r < in->numRows; r++) {
                for (int c = 0; c < in->numCols; c++) {
                    const char* cell = in->getCell(r, c);
                    if (cell) script += cell;
                    if (c + 1 < in->numCols) script += '\t';
                }
                script += '\n';
            }
        } else if (const char* s = inputs->getParString("Script")) {
            script = s;
        }
        if (const char* l = inputs->getParString("Language")) lang = l;

        {
            std::lock_guard<std::mutex> lock(myMutex);
            if (myRunRequested && !script.empty()) {
                myRunRequested = false;
                myJob = Job{script, lang};
                myHasPending = true;
                myCond.notify_one();
            } else {
                myRunRequested = false;
            }
        }

        // 画面は常に status/情報テーブル
        std::string status, result, err, took, language;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            status = myStatus; result = myResult; err = myError; took = myTookMs; language = myLang;
        }
        struct KV { const char* k; std::string v; };
        KV rows[] = {
            {"status", status}, {"result", result}, {"error", err},
            {"took_ms", took}, {"language", language},
        };
        const int n = (int)(sizeof(rows) / sizeof(rows[0]));
        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize(n + 1, 2);
        output->setCellString(0, 0, "key");
        output->setCellString(0, 1, "value");
        for (int i = 0; i < n; i++) {
            output->setCellString(i + 1, 0, rows[i].k);
            output->setCellString(i + 1, 1, rows[i].v.c_str());
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        const char* P = "AppleScript";
        {
            OP_StringParameter p("Language"); p.label = "Language"; p.page = P; p.defaultValue = "applescript";
            const char* names[] = {"applescript", "javascript"};
            const char* labels[] = {"AppleScript", "JavaScript (JXA)"};
            manager->appendMenu(p, 2, names, labels);
        }
        {
            OP_StringParameter p("Script");
            p.label = "Script (or wire a DAT)";
            p.page = P;
            manager->appendString(p);
        }
        { OP_NumericParameter p("Run"); p.label = "Run"; p.page = P; manager->appendPulse(p); }
    }

    void pulsePressed(const char* name, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (strcmp(name, "Run") == 0) myRunRequested = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[3] = {"executes", "runs", "running"};
        float values[3] = {(float)myExecCount, (float)myRunCount, myBusy ? 1.0f : 0.0f};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* w, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (myBusy) w->setString("running script...");
    }

private:
    struct Job { std::string script, lang; };

    void workerLoop()
    {
        while (true) {
            Job job;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit) return;
                job = myJob; myHasPending = false; myBusy = true; myStatus = "running...";
            }
            runScript(job.script, job.lang);
            myRunCount++;
            { std::lock_guard<std::mutex> lock(myMutex); myBusy = false; }
        }
    }

    void runScript(const std::string& script, const std::string& lang)
    {
        const auto t0 = std::chrono::steady_clock::now();
        std::string out, err;
        int code = -1;
        @autoreleasepool {
            NSTask* task = [[NSTask alloc] init];
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
            // -l で言語指定。スクリプト本体は stdin から流す
            NSString* l = (lang == "javascript") ? @"JavaScript" : @"AppleScript";
            task.arguments = @[ @"-l", l ];
            NSPipe* inPipe = [NSPipe pipe];
            NSPipe* outPipe = [NSPipe pipe];
            NSPipe* errPipe = [NSPipe pipe];
            task.standardInput = inPipe;
            task.standardOutput = outPipe;
            task.standardError = errPipe;
            NSError* e = nil;
            if ([task launchAndReturnError:&e]) {
                @try {
                    [inPipe.fileHandleForWriting
                        writeData:[[NSString stringWithUTF8String:script.c_str()]
                                      dataUsingEncoding:NSUTF8StringEncoding]];
                    [inPipe.fileHandleForWriting closeFile];
                } @catch (NSException*) {}
                NSData* outData = [outPipe.fileHandleForReading readDataToEndOfFile];
                NSData* errData = [errPipe.fileHandleForReading readDataToEndOfFile];
                [task waitUntilExit];
                out = nsstr([[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding]);
                err = nsstr([[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding]);
                code = task.terminationStatus;
            } else {
                err = nsstr(e.localizedDescription);
            }
        }
        // 末尾改行を落とす
        while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) out.pop_back();
        while (!err.empty() && (err.back() == '\n' || err.back() == '\r')) err.pop_back();
        const float ms = std::chrono::duration<float, std::milli>(
                             std::chrono::steady_clock::now() - t0).count();
        char buf[32]; snprintf(buf, sizeof(buf), "%.0f", ms);
        std::lock_guard<std::mutex> lock(myMutex);
        myStatus = (code == 0) ? "ok" : "error";
        myResult = out;
        myError = (code == 0) ? "" : err;
        myTookMs = buf;
        myLang = (lang == "javascript") ? "javascript" : "applescript";
    }

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false, myHasPending = false, myBusy = false, myRunRequested = false;
    Job myJob;
    std::string myStatus = "ready", myResult, myError, myTookMs, myLang;
    std::atomic<int> myExecCount{0}, myRunCount{0};
};

}   // namespace

extern "C" {

DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion)) return;
    info->customOPInfo.opType->setString("Applescript");
    info->customOPInfo.opLabel->setString("AppleScript");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("ASC");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/AppleScript/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 1;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* info) { return new AppleScriptDAT(info); }
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* instance) { delete static_cast<AppleScriptDAT*>(instance); }

}   // extern "C"
