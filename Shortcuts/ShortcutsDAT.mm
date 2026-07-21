// Shortcuts DAT — TouchDesigner カスタムオペレータ(macOS)
//
// **macOSショートカット(Shortcuts.app)をTDから実行**する。`/usr/bin/shortcuts` CLI 経由。
// HomeKit照明・通知・家電・他アプリ連携など、ショートカットにできることは全てTDの
// イベントから叩けるようになる。入力テキストを渡し、出力テキストを受け取れる。
//
// 使い方: Shortcut Name に実行したいショートカット名 → Run をパルス。
// List Shortcuts をパルスすると利用可能な一覧をテーブルに出す。
// 入力DAT(任意)の cell(0,0) または Input Text がショートカットの入力になる。
//
// 出力テーブル: key/value(status / output / shortcut / took_ms)、一覧モードでは名前リスト。
//
// 実装: 実行はワーカースレッド(NSTask)。cook はブロックしない。

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
    }

    ~ShortcutsDAT() override
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
        std::string name, text;
        if (const char* n = inputs->getParString("Shortcutname"))
            name = n;
        if (const char* t = inputs->getParString("Inputtext"))
            text = t;
        // 入力DATがあれば cell(0,0) を優先
        const OP_DATInput* in = inputs->getInputDAT(0);
        if (in && in->numRows > 0 && in->numCols > 0) {
            const char* cell = in->getCell(0, 0);
            if (cell && *cell)
                text = cell;
        }

        {
            std::lock_guard<std::mutex> lock(myMutex);
            if (myRunRequested && !name.empty()) {
                myRunRequested = false;
                myJob = Job{JobKind::Run, name, text};
                myHasPending = true;
                myCond.notify_one();
            } else if (myListRequested) {
                myListRequested = false;
                myJob = Job{JobKind::List, "", ""};
                myHasPending = true;
                myCond.notify_one();
            } else {
                myRunRequested = false;
                myListRequested = false;
            }
        }

        std::vector<std::pair<std::string, std::string>> rows;
        {
            std::lock_guard<std::mutex> lock(myMutex);
            rows = myRows;
        }
        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize((int32_t)rows.size() + 1, 2);
        output->setCellString(0, 0, "key");
        output->setCellString(0, 1, "value");
        for (int i = 0; i < (int)rows.size(); i++) {
            output->setCellString(i + 1, 0, rows[i].first.c_str());
            output->setCellString(i + 1, 1, rows[i].second.c_str());
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Shortcutname");
            p.label = "Shortcut Name";
            p.page = "Shortcuts";
            manager->appendString(p);
        }
        {
            OP_StringParameter p("Inputtext");
            p.label = "Input Text";
            p.page = "Shortcuts";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Run");
            p.label = "Run";
            p.page = "Shortcuts";
            manager->appendPulse(p);
        }
        {
            OP_NumericParameter p("Listshortcuts");
            p.label = "List Shortcuts";
            p.page = "Shortcuts";
            manager->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (strcmp(name, "Run") == 0)
            myRunRequested = true;
        else if (strcmp(name, "Listshortcuts") == 0)
            myListRequested = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[3] = {"executes", "runs", "running"};
        float values[3] = {(float)myExecCount, (float)myRunCount, myBusy ? 1.0f : 0.0f};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        std::lock_guard<std::mutex> lock(myMutex);
        if (myBusy)
            warning->setString("running shortcut...");
    }

private:
    enum class JobKind { Run, List };
    struct Job
    {
        JobKind kind = JobKind::Run;
        std::string name, input;
    };

    void workerLoop()
    {
        while (true) {
            Job job;
            {
                std::unique_lock<std::mutex> lock(myMutex);
                myCond.wait(lock, [this] { return myQuit || myHasPending; });
                if (myQuit)
                    return;
                job = myJob;
                myHasPending = false;
                myBusy = true;
            }
            std::vector<std::pair<std::string, std::string>> rows;
            if (job.kind == JobKind::List)
                runList(rows);
            else
                runShortcut(job.name, job.input, rows);
            myRunCount++;
            {
                std::lock_guard<std::mutex> lock(myMutex);
                myRows = std::move(rows);
                myBusy = false;
            }
        }
    }

    // NSTask で CLI 実行(ワーカースレッドなのでブロックOK)
    static int runTask(NSArray<NSString*>* args, NSString* stdinText, std::string& out,
                       std::string& err)
    {
        @autoreleasepool {
            NSTask* task = [[NSTask alloc] init];
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/shortcuts"];
            task.arguments = args;
            NSPipe* outPipe = [NSPipe pipe];
            NSPipe* errPipe = [NSPipe pipe];
            task.standardOutput = outPipe;
            task.standardError = errPipe;
            if (stdinText) {
                NSPipe* inPipe = [NSPipe pipe];
                task.standardInput = inPipe;
                [inPipe.fileHandleForWriting
                    writeData:[stdinText dataUsingEncoding:NSUTF8StringEncoding]];
                [inPipe.fileHandleForWriting closeFile];
            }
            NSError* e = nil;
            if (![task launchAndReturnError:&e]) {
                err = nsstr(e.localizedDescription);
                return -1;
            }
            NSData* outData = [outPipe.fileHandleForReading readDataToEndOfFile];
            NSData* errData = [errPipe.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            out = nsstr([[NSString alloc] initWithData:outData
                                              encoding:NSUTF8StringEncoding]);
            err = nsstr([[NSString alloc] initWithData:errData
                                              encoding:NSUTF8StringEncoding]);
            return task.terminationStatus;
        }
    }

    static void runList(std::vector<std::pair<std::string, std::string>>& rows)
    {
        std::string out, err;
        const int code = runTask(@[@"list"], nil, out, err);
        if (code != 0) {
            rows.push_back({"status", "list failed: " + err});
            return;
        }
        rows.push_back({"status", "list"});
        int i = 1;
        size_t pos = 0;
        while (pos < out.size()) {
            size_t nl = out.find('\n', pos);
            if (nl == std::string::npos)
                nl = out.size();
            std::string line = out.substr(pos, nl - pos);
            if (!line.empty())
                rows.push_back({"shortcut" + std::to_string(i++), line});
            pos = nl + 1;
        }
    }

    static void runShortcut(const std::string& name, const std::string& input,
                            std::vector<std::pair<std::string, std::string>>& rows)
    {
        // 入力は一時ファイル経由(-i)。出力は stdout に出る
        NSString* inFile = nil;
        NSMutableArray* args =
            [NSMutableArray arrayWithObjects:@"run",
                            [NSString stringWithUTF8String:name.c_str()], nil];
        if (!input.empty()) {
            inFile = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"td_shortcut_input.txt"];
            [[NSString stringWithUTF8String:input.c_str()]
                writeToFile:inFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [args addObject:@"-i"];
            [args addObject:inFile];
        }
        const auto t0 = std::chrono::steady_clock::now();
        std::string out, err;
        const int code = runTask(args, nil, out, err);
        const float ms = std::chrono::duration<float, std::milli>(
                             std::chrono::steady_clock::now() - t0).count();
        // 末尾改行を落とす
        while (!out.empty() && (out.back() == '\n' || out.back() == '\r'))
            out.pop_back();
        char buf[32];
        snprintf(buf, sizeof(buf), "%.0f", ms);
        rows.push_back({"status", code == 0 ? "ok" : ("error: " + err)});
        rows.push_back({"shortcut", name});
        rows.push_back({"output", out});
        rows.push_back({"took_ms", buf});
    }

    std::thread myWorker;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false;
    bool myHasPending = false;
    bool myBusy = false;
    bool myRunRequested = false;
    bool myListRequested = false;
    Job myJob;
    std::vector<std::pair<std::string, std::string>> myRows;

    std::atomic<int> myExecCount{0}, myRunCount{0};
};

}   // namespace

extern "C" {

DLLEXPORT void
FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Shortcuts");
    info->customOPInfo.opLabel->setString("Shortcuts");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.opIcon->setString("SHC");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new ShortcutsDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete static_cast<ShortcutsDAT*>(instance);
}

}   // extern "C"
