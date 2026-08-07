// Shortcuts DAT — TouchDesigner カスタムオペレータ(macOS)
//
// **macOSショートカット(Shortcuts.app)をTDから実行**する。
// HomeKit照明・Music再生・通知・家電・他アプリ連携など、ショートカットにできることは全て
// TD のイベント(パルス)から叩けるようになる。
//
// UX:
//   - Shortcut Name は**プルダウン(動的メニュー)**。起動時に一覧を自動取得して選べる。
//     Refresh List で再取得。
//   - DATの画面(出力テーブル)は**常に status/情報**を表示する
//     (status / shortcut / method / output / took_ms / shortcuts)。
//
// Run Method(重要):
//   - App (shortcuts://): `open shortcuts://run-shortcut` で **Shortcuts.app に委譲**して実行(既定)。
//     TD から `shortcuts run` CLI を直接叩くと TD のプロセス権限で走り、Music/HomeKit等を操作する
//     ショートカットは「見つかりません」エラーで失敗する。App方式なら権限を持つ Shortcuts.app 側で
//     走るので確実。ただし**出力テキストは受け取れない**(fire&forget)
//   - CLI (output): `shortcuts run` CLI。**出力テキストを受け取れる**が、外部アプリを操作する
//     ショートカットは TD に権限が無いと失敗する。純粋に値を返すだけのショートカット向け
//
// 実装: 実行/一覧取得はワーカースレッド(NSTask)。cook はブロックしない。

#import <Foundation/Foundation.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {

static std::string nsstr(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }

class ShortcutsDAT final : public DAT_CPlusPlusBase
{
public:
    explicit ShortcutsDAT(const OP_NodeInfo*)
    {
        myWorker = std::thread([this] { workerLoop(); });
        // 起動時に一覧を自動取得(プルダウンを埋める)
        std::lock_guard<std::mutex> lock(myMutex);
        myJob = Job{JobKind::List, "", "", true};
        myHasPending = true;
        myCond.notify_one();
    }

    ~ShortcutsDAT() override
    {
        { std::lock_guard<std::mutex> lock(myMutex); myQuit = true; }
        myCond.notify_all();
        if (myWorker.joinable()) myWorker.join();
    }

    void getGeneralInfo(DAT_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    { ginfo->cookEveryFrameIfAsked = true; }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        std::string name, text, method;
        if (const char* n = inputs->getParString("Shortcutname")) name = n;
        if (const char* t = inputs->getParString("Inputtext")) text = t;
        if (const char* m = inputs->getParString("Method")) method = m;
        // 入力DATがあれば cell(0,0) を優先
        const OP_DATInput* in = inputs->getInputDAT(0);
        if (in && in->numRows > 0 && in->numCols > 0) {
            const char* cell = in->getCell(0, 0);
            if (cell && *cell) text = cell;
        }

        {
            std::lock_guard<std::mutex> lock(myMutex);
            if (myRunRequested && !name.empty()) {
                myRunRequested = false;
                myJob = Job{JobKind::Run, name, text, method != "cli"};
                myHasPending = true;
                myCond.notify_one();
            } else if (myListRequested) {
                myListRequested = false;
                myJob = Job{JobKind::List, "", "", true};
                myHasPending = true;
                myCond.notify_one();
            } else {
                myRunRequested = false;
                myListRequested = false;
            }
        }

        // 画面は常に status/情報テーブルを表示
        std::string status, shortcut, out, mstr, took;
        int count;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            status = myStatus; shortcut = myLastShortcut; out = myLastOutput;
            mstr = myLastMethod; took = myTookMs; count = (int)myList.size();
        }
        struct KV { const char* k; std::string v; };
        std::vector<KV> rows = {
            {"status", status}, {"shortcut", shortcut}, {"method", mstr},
            {"output", out}, {"took_ms", took}, {"shortcuts", std::to_string(count)},
        };
        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize((int32_t)rows.size() + 1, 2);
        output->setCellString(0, 0, "key");
        output->setCellString(0, 1, "value");
        for (int i = 0; i < (int)rows.size(); i++) {
            output->setCellString(i + 1, 0, rows[i].k);
            output->setCellString(i + 1, 1, rows[i].v.c_str());
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        const char* P = "Shortcuts";
        {
            OP_StringParameter p("Shortcutname");
            p.label = "Shortcut";
            p.page = P;
            p.defaultValue = "(refresh list)";   // 動的メニューは非空の既定が必要
            manager->appendDynamicStringMenu(p);
        }
        { OP_StringParameter p("Inputtext"); p.label = "Input Text"; p.page = P; manager->appendString(p); }
        {
            OP_StringParameter p("Method"); p.label = "Run Method"; p.page = P; p.defaultValue = "app";
            const char* names[] = {"app", "cli"};
            const char* labels[] = {"App (shortcuts://, reliable)", "CLI (returns output)"};
            manager->appendMenu(p, 2, names, labels);
        }
        { OP_NumericParameter p("Run"); p.label = "Run"; p.page = P; manager->appendPulse(p); }
        { OP_NumericParameter p("Refreshlist"); p.label = "Refresh List"; p.page = P; manager->appendPulse(p); }
    }

    // Shortcut プルダウンの中身をキャッシュした一覧から作る
    void buildDynamicMenu(const OP_Inputs*, OP_BuildDynamicMenuInfo* info, void*) override
    {
        if (strcmp(info->name, "Shortcutname") != 0) return;
        std::vector<std::string> list;
        { std::lock_guard<std::mutex> lock(myMutex); list = myList; }
        if (list.empty())
            info->addMenuEntry("(refresh list)", "(press Refresh List)");
        for (const auto& s : list)
            info->addMenuEntry(s.c_str(), s.c_str());
    }

    void pulsePressed(const char* name, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (strcmp(name, "Run") == 0) myRunRequested = true;
        else if (strcmp(name, "Refreshlist") == 0) myListRequested = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[4] = {"executes", "runs", "running", "shortcuts"};
        int count; { std::lock_guard<std::mutex> l(myMutex); count = (int)myList.size(); }
        float values[4] = {(float)myExecCount, (float)myRunCount, myBusy ? 1.0f : 0.0f, (float)count};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (myBusy) warning->setString("running...");
    }

private:
    enum class JobKind { Run, List };
    struct Job { JobKind kind = JobKind::Run; std::string name, input; bool useApp = true; };

    void workerLoop()
    {
        while (true) {
            Job job;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit) return;
                job = myJob; myHasPending = false; myBusy = true;
                if (job.kind == JobKind::List) myStatus = "loading list...";
                else myStatus = "running...";
            }
            if (job.kind == JobKind::List)
                runList();
            else if (job.useApp)
                runShortcutApp(job.name, job.input);
            else
                runShortcut(job.name, job.input);
            if (job.kind == JobKind::Run) myRunCount++;
            { std::lock_guard<std::mutex> lock(myMutex); myBusy = false; }
        }
    }

    static int runTask(NSArray<NSString*>* args, std::string& out, std::string& err)
    {
        @autoreleasepool {
            NSTask* task = [[NSTask alloc] init];
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/shortcuts"];
            task.arguments = args;
            NSPipe* outPipe = [NSPipe pipe];
            NSPipe* errPipe = [NSPipe pipe];
            task.standardOutput = outPipe;
            task.standardError = errPipe;
            NSError* e = nil;
            if (![task launchAndReturnError:&e]) { err = nsstr(e.localizedDescription); return -1; }
            NSData* outData = [outPipe.fileHandleForReading readDataToEndOfFile];
            NSData* errData = [errPipe.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            out = nsstr([[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding]);
            err = nsstr([[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding]);
            return task.terminationStatus;
        }
    }

    void runList()
    {
        std::string out, err;
        const int code = runTask(@[@"list"], out, err);
        std::vector<std::string> list;
        if (code == 0) {
            size_t pos = 0;
            while (pos < out.size()) {
                size_t nl = out.find('\n', pos);
                if (nl == std::string::npos) nl = out.size();
                std::string line = out.substr(pos, nl - pos);
                while (!line.empty() && (line.back() == '\r')) line.pop_back();
                if (!line.empty()) list.push_back(line);
                pos = nl + 1;
            }
        }
        std::lock_guard<std::mutex> lock(myMutex);
        if (code == 0) { myList = std::move(list); myStatus = "ready"; }
        else myStatus = "list failed: " + err;
    }

    // App方式: `open -g shortcuts://run-shortcut?name=...&input=...` で Shortcuts.app に委譲。
    void runShortcutApp(const std::string& name, const std::string& input)
    {
        const auto t0 = std::chrono::steady_clock::now();
        std::string err; int code = -1;
        @autoreleasepool {
            NSURLComponents* comp = [NSURLComponents componentsWithString:@"shortcuts://run-shortcut"];
            NSMutableArray<NSURLQueryItem*>* items = [NSMutableArray array];
            [items addObject:[NSURLQueryItem queryItemWithName:@"name"
                                                         value:[NSString stringWithUTF8String:name.c_str()]]];
            if (!input.empty())
                [items addObject:[NSURLQueryItem queryItemWithName:@"input"
                                                             value:[NSString stringWithUTF8String:input.c_str()]]];
            comp.queryItems = items;
            NSURL* url = comp.URL;
            if (url) {
                NSTask* task = [[NSTask alloc] init];
                task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
                task.arguments = @[ @"-g", url.absoluteString ];
                NSError* e = nil;
                if ([task launchAndReturnError:&e]) { [task waitUntilExit]; code = task.terminationStatus; }
                else err = nsstr(e.localizedDescription);
            } else err = "bad url";
        }
        const float ms = std::chrono::duration<float, std::milli>(
                             std::chrono::steady_clock::now() - t0).count();
        char buf[32]; snprintf(buf, sizeof(buf), "%.0f", ms);
        std::lock_guard<std::mutex> lock(myMutex);
        myStatus = code == 0 ? "launched (Shortcuts app)" : ("error: " + err);
        myLastShortcut = name; myLastMethod = "app";
        myLastOutput = "(App method returns no output — use Method=CLI to capture output)";
        myTookMs = buf;
    }

    void runShortcut(const std::string& name, const std::string& input)
    {
        NSMutableArray* args = [NSMutableArray arrayWithObjects:@"run",
                                [NSString stringWithUTF8String:name.c_str()], nil];
        NSString* inFile = nil;
        if (!input.empty()) {
            inFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"td_shortcut_input.txt"];
            [[NSString stringWithUTF8String:input.c_str()] writeToFile:inFile atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
            [args addObject:@"-i"]; [args addObject:inFile];
        }
        const auto t0 = std::chrono::steady_clock::now();
        std::string out, err;
        const int code = runTask(args, out, err);
        const float ms = std::chrono::duration<float, std::milli>(
                             std::chrono::steady_clock::now() - t0).count();
        while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) out.pop_back();
        char buf[32]; snprintf(buf, sizeof(buf), "%.0f", ms);
        std::lock_guard<std::mutex> lock(myMutex);
        myStatus = code == 0 ? "ok" : ("error: " + err);
        myLastShortcut = name; myLastMethod = "cli"; myLastOutput = out; myTookMs = buf;
    }

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false, myHasPending = false, myBusy = false;
    bool myRunRequested = false, myListRequested = false;
    Job myJob;
    std::vector<std::string> myList;    // ショートカット名一覧(プルダウン用)
    std::string myStatus = "starting...", myLastShortcut, myLastOutput, myLastMethod, myTookMs;
    std::atomic<int> myExecCount{0}, myRunCount{0};
};

}   // namespace

extern "C" {

DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion)) return;
    info->customOPInfo.opType->setString("Shortcuts");
    info->customOPInfo.opLabel->setString("Shortcuts");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("SHC");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/Shortcuts/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 1;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* info) { return new ShortcutsDAT(info); }
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* instance) { delete static_cast<ShortcutsDAT*>(instance); }

}   // extern "C"
