// MLX LLM DAT — ローカルLLM推論（Apple MLX・Apple Silicon）
//
// Apple の MLX フレームワーク（mlx-swift-lm）で Gemma / Qwen / Llama 等の量子化LLMを
// 完全ローカル・オンデバイスで走らせる TD カスタム DAT。API課金なし・オフライン動作
//（モデル初回のみ Hugging Face からダウンロード）。
//
// AFM Core（Apple Intelligence）との違い: AFM Core は端末付属の固定 ~3B モデルのみだが、
// MLX LLM は任意の mlx-community モデル（Gemma 4 等）を Model パラメータで選べる。
//
// アーキテクチャ: 重い推論（Metal・多GBモデル）は同梱ヘルパ実行ファイル mlxllm-helper を
// 別プロセスとして起動し、JSON-lines プロトコルで通信する（dylib同梱だと MLX の Metal
// リソースバンドル解決や rpath が壊れやすい + プロセス隔離でTDを巻き込まない）。
// cook は絶対にブロックしない: ヘルパの stdout はワーカースレッドで読み、最新状態を出す。
//
// 出力テーブル（会話履歴）: index | role | text
//   user / assistant が交互。生成中は最後の assistant 行がトークンで伸びる。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <dlfcn.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

extern char** environ;

namespace {

struct Turn
{
    std::string role;
    std::string text;
};

// ヘルパ実行ファイルの起動・JSON-lines通信・状態管理を担う。
class HelperProcess
{
public:
    ~HelperProcess() { stop(); }

    bool running() const { return myPid > 0; }

    // .plugin/Contents/Helpers/mlxllm-helper を起動
    bool start(const std::string& exePath)
    {
        if (myPid > 0)
            return true;

        int inPipe[2];   // 親→子 stdin
        int outPipe[2];  // 子→親 stdout
        if (pipe(inPipe) != 0)
            return false;
        if (pipe(outPipe) != 0) {
            close(inPipe[0]);
            close(inPipe[1]);
            return false;
        }

        posix_spawn_file_actions_t fa;
        posix_spawn_file_actions_init(&fa);
        posix_spawn_file_actions_adddup2(&fa, inPipe[0], STDIN_FILENO);
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], STDOUT_FILENO);
        posix_spawn_file_actions_addclose(&fa, inPipe[1]);
        posix_spawn_file_actions_addclose(&fa, outPipe[0]);
        posix_spawn_file_actions_addclose(&fa, inPipe[0]);
        posix_spawn_file_actions_addclose(&fa, outPipe[1]);

        // 子プロセスに DYLD_FRAMEWORK_PATH / DYLD_LIBRARY_PATH を注入する。
        // xcodebuild は MLX を動的フレームワークとして Helpers/PackageFrameworks に置くため、
        // ヘルパ実行時にそこを検索させる必要がある（metallib バンドルは実行ファイルの隣）。
        std::string dir = exePath;
        size_t slash = dir.rfind('/');
        if (slash != std::string::npos)
            dir = dir.substr(0, slash);
        std::string fwPath = dir + "/PackageFrameworks:" + dir;
        std::string dyfw = "DYLD_FRAMEWORK_PATH=" + fwPath;
        std::string dylib = "DYLD_LIBRARY_PATH=" + fwPath;
        std::vector<std::string> envStore;
        for (char** e = environ; e && *e; e++) {
            if (strncmp(*e, "DYLD_FRAMEWORK_PATH=", 20) == 0 ||
                strncmp(*e, "DYLD_LIBRARY_PATH=", 18) == 0)
                continue;   // 上書き
            envStore.push_back(*e);
        }
        envStore.push_back(dyfw);
        envStore.push_back(dylib);
        std::vector<char*> envp;
        for (auto& s : envStore)
            envp.push_back(const_cast<char*>(s.c_str()));
        envp.push_back(nullptr);

        const char* argv[] = {exePath.c_str(), "--serve", nullptr};
        pid_t pid = 0;
        int rc = posix_spawn(&pid, exePath.c_str(), &fa, nullptr,
                             const_cast<char* const*>(argv), envp.data());
        posix_spawn_file_actions_destroy(&fa);
        close(inPipe[0]);
        close(outPipe[1]);
        if (rc != 0) {
            close(inPipe[1]);
            close(outPipe[0]);
            return false;
        }

        myPid = pid;
        myWriteFd = inPipe[1];
        myReadFd = outPipe[0];
        {
            std::lock_guard<std::mutex> l(myMutex);
            myStatus = "starting helper";
        }
        myAlive = true;
        myReader = std::thread([this] { readLoop(); });
        return true;
    }

    void stop()
    {
        if (myPid <= 0)
            return;
        sendLine("{\"cmd\":\"quit\"}");
        myAlive = false;
        if (myWriteFd >= 0) {
            close(myWriteFd);
            myWriteFd = -1;
        }
        // 子の終了を少し待ってから強制終了
        for (int i = 0; i < 20 && myPid > 0; i++) {
            int st = 0;
            pid_t r = waitpid(myPid, &st, WNOHANG);
            if (r == myPid) {
                myPid = 0;
                break;
            }
            usleep(10000);
        }
        if (myPid > 0) {
            kill(myPid, SIGTERM);
            int st = 0;
            waitpid(myPid, &st, 0);
            myPid = 0;
        }
        if (myReadFd >= 0) {
            close(myReadFd);
            myReadFd = -1;
        }
        if (myReader.joinable())
            myReader.join();
    }

    void sendLine(const std::string& line)
    {
        if (myWriteFd < 0)
            return;
        std::string out = line + "\n";
        ssize_t n = write(myWriteFd, out.data(), out.size());
        (void)n;
    }

    // ---- スナップショット取得 ----
    void snapshot(std::string& status, int& progress, bool& busy, bool& ready,
                  std::vector<Turn>& history)
    {
        std::lock_guard<std::mutex> l(myMutex);
        status = myStatus;
        progress = myProgress;
        busy = myBusy;
        ready = myReady;
        history = myHistory;
    }

    // gen コマンド送信時に user + 空 assistant 行をローカルに積む
    void beginTurn(const std::string& prompt)
    {
        std::lock_guard<std::mutex> l(myMutex);
        myHistory.push_back({"user", prompt});
        myHistory.push_back({"assistant", ""});
        myBusy = true;
    }

    void resetHistory()
    {
        std::lock_guard<std::mutex> l(myMutex);
        myHistory.clear();
        myBusy = false;
    }

private:
    void readLoop()
    {
        std::string acc;
        char buf[4096];
        while (myAlive) {
            ssize_t n = read(myReadFd, buf, sizeof(buf));
            if (n <= 0)
                break;
            acc.append(buf, buf + n);
            size_t pos;
            while ((pos = acc.find('\n')) != std::string::npos) {
                std::string line = acc.substr(0, pos);
                acc.erase(0, pos + 1);
                if (!line.empty())
                    handleEvent(line);
            }
        }
        std::lock_guard<std::mutex> l(myMutex);
        if (myAlive)
            myStatus = "helper exited";
    }

    void handleEvent(const std::string& line)
    {
        @autoreleasepool {
            NSData* data = [NSData dataWithBytes:line.data() length:line.size()];
            NSDictionary* d = [NSJSONSerialization JSONObjectWithData:data
                                                             options:0
                                                               error:nil];
            if (![d isKindOfClass:[NSDictionary class]])
                return;
            NSString* type = d[@"type"];
            if (![type isKindOfClass:[NSString class]])
                return;
            std::lock_guard<std::mutex> l(myMutex);
            if ([type isEqualToString:@"progress"]) {
                myProgress = [d[@"pct"] intValue];
                myStatus = "downloading model";
            } else if ([type isEqualToString:@"ready"]) {
                myReady = true;
                myProgress = 100;
                myStatus = "ready";
            } else if ([type isEqualToString:@"status"]) {
                NSString* t = d[@"text"];
                if ([t isKindOfClass:[NSString class]])
                    myStatus = t.UTF8String ?: "";
            } else if ([type isEqualToString:@"token"]) {
                NSString* t = d[@"text"];
                if ([t isKindOfClass:[NSString class]] && !myHistory.empty() &&
                    myHistory.back().role == "assistant")
                    myHistory.back().text += (t.UTF8String ?: "");
                myStatus = "generating";
            } else if ([type isEqualToString:@"done"]) {
                myBusy = false;
                myStatus = "ready";
            } else if ([type isEqualToString:@"error"]) {
                NSString* t = d[@"text"];
                myBusy = false;
                myStatus = std::string("error: ") +
                           ([t isKindOfClass:[NSString class]] ? (t.UTF8String ?: "") : "");
            }
        }
    }

    pid_t myPid = 0;
    int myWriteFd = -1;
    int myReadFd = -1;
    std::atomic<bool> myAlive{false};
    std::thread myReader;

    std::mutex myMutex;
    std::string myStatus = "idle";
    int myProgress = 0;
    bool myBusy = false;
    bool myReady = false;
    std::vector<Turn> myHistory;
};

// この .plugin バンドル内の Helpers/mlxllm-helper の絶対パスを得る
std::string helperExecutablePath()
{
    Dl_info info;
    if (dladdr(reinterpret_cast<const void*>(&helperExecutablePath), &info) && info.dli_fname) {
        // .../Contents/MacOS/<bin> → .../Contents/Helpers/mlxllm-helper
        std::string p = info.dli_fname;
        size_t macos = p.rfind("/MacOS/");
        if (macos != std::string::npos) {
            std::string contents = p.substr(0, macos);
            return contents + "/Helpers/mlxllm-helper";
        }
    }
    return "";
}

class MLXLLMDAT : public DAT_CPlusPlusBase
{
public:
    explicit MLXLLMDAT(const OP_NodeInfo*) {}

    ~MLXLLMDAT() override { myHelper.stop(); }

    void getGeneralInfo(DAT_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;

        const char* modelPar = inputs->getParString("Model");
        const std::string model = modelPar ? modelPar : "";

        // Load パルス、または初回 Submit で必要ならヘルパ起動 + モデルロード
        if (myWantLoad.exchange(false))
            ensureLoaded(model);

        if (myWantSubmit.exchange(false)) {
            if (!myHelper.running())
                ensureLoaded(model);
            if (myHelper.running()) {
                const char* prompt = inputs->getParString("Prompt");
                const char* sys = inputs->getParString("System");
                const std::string p = prompt ? prompt : "";
                const std::string image = captureImage(inputs);   // 画像入力ONなら一時PNGパス
                myHelper.beginTurn(p);
                myHelper.sendLine(buildGenCommand(
                    p, sys ? sys : "", inputs->getParDouble("Temperature"),
                    (int)inputs->getParInt("Maxtokens"),
                    inputs->getParInt("Keepcontext") != 0, image));
            }
        }

        if (myWantReset.exchange(false)) {
            if (myHelper.running())
                myHelper.sendLine("{\"cmd\":\"reset\"}");
            myHelper.resetHistory();
        }

        // 状態スナップショット → テーブル出力
        std::string status;
        int progress = 0;
        bool busy = false, ready = false;
        std::vector<Turn> history;
        myHelper.snapshot(status, progress, busy, ready, history);
        myStatus = status;
        myProgress = progress;
        myBusy = busy ? 1 : 0;
        myReady = ready ? 1 : 0;
        myTurnCount = (int)history.size();

        const int maxRows = std::max(1, (int)inputs->getParInt("Maxrows"));
        const int begin = std::max(0, (int)history.size() - maxRows);
        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize(1 + (int32_t)(history.size() - begin), 3);
        output->setCellString(0, 0, "index");
        output->setCellString(0, 1, "role");
        output->setCellString(0, 2, "text");
        int32_t row = 1;
        for (size_t r = begin; r < history.size(); r++) {
            char idx[16];
            snprintf(idx, sizeof(idx), "%d", (int)r);
            output->setCellString(row, 0, idx);
            output->setCellString(row, 1, history[r].role.c_str());
            output->setCellString(row, 2, history[r].text.c_str());
            row++;
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_StringParameter p("Model");
            p.label = "Model (mlx-community repo)";
            p.page = "LLM MLX";
            p.defaultValue = "mlx-community/gemma-4-e2b-it-4bit";
            manager->appendString(p);
        }
        {
            OP_StringParameter p("System");
            p.label = "System Instructions";
            p.page = "LLM MLX";
            manager->appendString(p);
        }
        {
            OP_StringParameter p("Prompt");
            p.label = "Prompt";
            p.page = "LLM MLX";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Temperature");
            p.label = "Temperature";
            p.page = "LLM MLX";
            p.defaultValues[0] = 0.7;
            p.minSliders[0] = 0.0;
            p.maxSliders[0] = 2.0;
            manager->appendFloat(p);
        }
        {
            OP_NumericParameter p("Maxtokens");
            p.label = "Max Tokens";
            p.page = "LLM MLX";
            p.defaultValues[0] = 512;
            p.minSliders[0] = 16;
            p.maxSliders[0] = 4096;
            p.minValues[0] = 1;
            p.clampMins[0] = true;
            manager->appendInt(p);
        }
        {
            OP_NumericParameter p("Keepcontext");
            p.label = "Keep Context (Multi-turn)";
            p.page = "LLM MLX";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Maxrows");
            p.label = "Max Rows";
            p.page = "LLM MLX";
            p.defaultValues[0] = 50;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 200;
            manager->appendInt(p);
        }
        // ---- Vision（画像入力・VLMモデル使用時）----
        {
            OP_NumericParameter p("Useimage");
            p.label = "Use Image Input";
            p.page = "Vision";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
        {
            // 画像を渡す TOP。VLM モデル(Gemma 4 / Qwen-VL 等)使用時に有効
            OP_StringParameter p("Image");
            p.label = "Image TOP";
            p.page = "Vision";
            manager->appendTOP(p);
        }
        {
            OP_NumericParameter p("Load");
            p.label = "Load Model";
            p.page = "LLM MLX";
            manager->appendPulse(p);
        }
        {
            OP_NumericParameter p("Submit");
            p.label = "Submit";
            p.page = "LLM MLX";
            manager->appendPulse(p);
        }
        {
            OP_NumericParameter p("Reset");
            p.label = "Reset Conversation";
            p.page = "LLM MLX";
            manager->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Submit") == 0)
            myWantSubmit = true;
        else if (strcmp(name, "Load") == 0)
            myWantLoad = true;
        else if (strcmp(name, "Reset") == 0)
            myWantReset = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[5] = {"executes", "busy", "ready", "progress", "turns"};
        float values[5] = {(float)myExecCount, (float)myBusy, (float)myReady,
                           (float)myProgress, (float)myTurnCount};
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
    void ensureLoaded(const std::string& model)
    {
        if (!myHelper.running()) {
            std::string exe = helperExecutablePath();
            if (exe.empty() || access(exe.c_str(), X_OK) != 0) {
                myStatus = "helper not found";
                return;
            }
            if (!myHelper.start(exe)) {
                myStatus = "helper start failed";
                return;
            }
        }
        if (model != myLoadedModel) {
            myLoadedModel = model;
            myHelper.sendLine(buildLoadCommand(model));
        }
    }

    static std::string jsonEscape(const std::string& s)
    {
        std::string o;
        o.reserve(s.size() + 8);
        for (char c : s) {
            switch (c) {
                case '"': o += "\\\""; break;
                case '\\': o += "\\\\"; break;
                case '\n': o += "\\n"; break;
                case '\r': o += "\\r"; break;
                case '\t': o += "\\t"; break;
                default:
                    if ((unsigned char)c < 0x20) {
                        char b[8];
                        snprintf(b, sizeof(b), "\\u%04x", c);
                        o += b;
                    } else {
                        o += c;
                    }
            }
        }
        return o;
    }

    static std::string buildLoadCommand(const std::string& model)
    {
        return "{\"cmd\":\"load\",\"model\":\"" + jsonEscape(model) + "\"}";
    }

    static std::string buildGenCommand(const std::string& prompt, const std::string& sys,
                                       double temp, int maxTok, bool keep,
                                       const std::string& image)
    {
        char nums[128];
        snprintf(nums, sizeof(nums), ",\"temp\":%.4f,\"max\":%d,\"keep\":%s", temp,
                 maxTok, keep ? "true" : "false");
        std::string cmd = "{\"cmd\":\"gen\",\"prompt\":\"" + jsonEscape(prompt) +
                          "\",\"system\":\"" + jsonEscape(sys) + "\"" + nums;
        if (!image.empty())
            cmd += ",\"image\":\"" + jsonEscape(image) + "\"";
        cmd += "}";
        return cmd;
    }

    // 画像入力ON時、Image TOP パラメータのテクスチャを一時PNGに書き出しパスを返す。
    // ヘルパは .url(そのパス) で VLM に渡す。cook上の一時的な stall は Submit 時のみで許容。
    std::string captureImage(const OP_Inputs* inputs)
    {
        if (inputs->getParInt("Useimage") == 0)
            return "";
        const OP_TOPInput* top = inputs->getParTOP("Image");
        if (!top)
            return "";
        OP_TOPInputDownloadOptions opts;
        opts.pixelFormat = OP_PixelFormat::BGRA8Fixed;
        opts.verticalFlip = true;   // TDは bottom-up。正立画像にして意味処理系(VLM)へ
        OP_SmartRef<OP_TOPDownloadResult> res = top->downloadTexture(opts, nullptr);
        if (!res)
            return "";
        const uint8_t* data = (const uint8_t*)res->getData();   // 準備できるまで stall
        int w = (int)res->textureDesc.width;
        int h = (int)res->textureDesc.height;
        if (!data || w <= 0 || h <= 0)
            return "";
        return writePNG(data, w, h);
    }

    std::string writePNG(const uint8_t* bgra, int w, int h)
    {
        @autoreleasepool {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            // BGRA8 を little-endian の XRGB(=メモリ上 B,G,R,X)として解釈。アルファは無視
            CGContextRef ctx = CGBitmapContextCreate(
                (void*)bgra, w, h, 8, (size_t)w * 4, cs,
                kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
            CGColorSpaceRelease(cs);
            if (!ctx)
                return "";
            CGImageRef img = CGBitmapContextCreateImage(ctx);
            CGContextRelease(ctx);
            if (!img)
                return "";
            if (myTempImagePath.empty()) {
                NSString* tmp = [NSTemporaryDirectory()
                    stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"mlxllm_%p.png", (void*)this]];
                myTempImagePath = tmp.UTF8String ?: "";
            }
            NSURL* url = [NSURL fileURLWithPath:
                [NSString stringWithUTF8String:myTempImagePath.c_str()]];
            CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
                (__bridge CFURLRef)url, (CFStringRef)@"public.png", 1, nullptr);
            std::string result;
            if (dst) {
                CGImageDestinationAddImage(dst, img, nullptr);
                if (CGImageDestinationFinalize(dst))
                    result = myTempImagePath;
                CFRelease(dst);
            }
            CGImageRelease(img);
            return result;
        }
    }

    HelperProcess myHelper;
    std::string myLoadedModel;
    std::string myTempImagePath;   // 画像入力用の一時PNG
    std::string myStatus = "idle";
    std::atomic<bool> myWantSubmit{false};
    std::atomic<bool> myWantLoad{false};
    std::atomic<bool> myWantReset{false};
    int myProgress = 0;
    int myBusy = 0;
    int myReady = 0;
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
    info->customOPInfo.opType->setString("Llmmlx");
    info->customOPInfo.opLabel->setString("LLM MLX");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("MLX");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/LLMMLX/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new MLXLLMDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete (MLXLLMDAT*)instance;
}

}   // extern "C"
