// CoreAI 系プラグイン共通: ヘルパ実行ファイルを別プロセスで spawn して JSON-lines で通信する。
// LLMCoreAIDAT.mm の HelperProcess から、LLM 固有の状態を外して汎用化したもの。
// - 子が死んだ後の write で SIGPIPE が TouchDesigner ごと落とす → F_SETNOSIGPIPE
// - パイプ EOF で子を回収して running() を false に → 次の start() で作り直せる
// - joinable な読み取りスレッドを残したまま破棄すると std::terminate → stop() が必ず join
// 使い方: onEvent / onExit を設定 → start(exe) → sendLine(json) → デストラクタで stop()
#pragma once
#import <Foundation/Foundation.h>
#include <atomic>
#include <functional>
#include <string>
#include <thread>
#include <vector>
#include <dlfcn.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

namespace tdcoreai {

class HelperProcess
{
public:
    ~HelperProcess() { stop(); }

    bool running() const { return myPid > 0; }
    // 直前のヘルパが自分で死んだか(次の start() で古い fd/スレッドを片付けるため)
    std::atomic<bool> myDied{false};

    // .plugin/Contents/Helpers/coreai-llm-helper を起動
    bool start(const std::string& exePath)
    {
        if (myPid > 0)
            return true;
        if (myDied) {
            // 前のヘルパの残骸(書き込み fd・読み取り fd・読み取りスレッド)を片付ける
            myAlive = false;
            if (myWriteFd >= 0) { close(myWriteFd); myWriteFd = -1; }
            if (myReadFd >= 0) { close(myReadFd); myReadFd = -1; }
            if (myReader.joinable()) myReader.join();
            myDied = false;
        }

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
        // ヘルパが落ちた後に書くと SIGPIPE で TouchDesigner ごと死ぬ(実測: 非対応バンドルで
        // ヘルパが LLVM ERROR 終了 → 次の Load で TD が無言で消えた。クラッシュレポートも出ない)。
        // このパイプでは SIGPIPE を発生させず EPIPE を返させる
        fcntl(myWriteFd, F_SETNOSIGPIPE, 1);
        myAlive = true;
        myReader = std::thread([this] { readLoop(); });
        return true;
    }

    void stop()
    {
        if (myPid <= 0) {
            // ヘルパが自分で死んだ後でも、読み取りスレッドと fd は残っている。
            // joinable なスレッドを持ったまま破棄すると std::terminate で TD ごと落ちる
            // (実測: ヘルパ死亡後にノードを削除して TD がクラッシュした)
            myAlive = false;
            if (myWriteFd >= 0) { close(myWriteFd); myWriteFd = -1; }
            if (myReadFd >= 0) { close(myReadFd); myReadFd = -1; }
            if (myReader.joinable()) myReader.join();
            return;
        }
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

    // イベントの受け口。読み取りスレッドから呼ばれる(呼び出し側でロックすること)
    std::function<void(NSDictionary*)> onEvent;
    // 子が死んだ(パイプ EOF)ときに呼ばれる
    std::function<void()> onExit;

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
        // 子が死んだ(パイプ EOF)。ここで回収して myPid を 0 に戻さないと running() が
        // true のままになり、次の Load が死んだパイプへ書いてしまう(=再起動できない)
        if (myAlive && myPid > 0) {
            int st = 0;
            waitpid(myPid, &st, 0);
            myPid = 0;
            myDied = true;
        }
        if (myAlive && onExit)
            onExit();
    }

    void handleEvent(const std::string& line)
    {
        @autoreleasepool {
            NSData* data = [NSData dataWithBytes:line.data() length:line.size()];
            NSDictionary* d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([d isKindOfClass:[NSDictionary class]] && onEvent)
                onEvent(d);
        }
    }

    pid_t myPid = 0;
    int myWriteFd = -1;
    int myReadFd = -1;
    std::atomic<bool> myAlive{false};
    std::thread myReader;
};

// .../Contents/MacOS/<bin> → .../Contents/Helpers/<name>
inline std::string helperPath(const char* name)
{
    Dl_info info;
    if (dladdr(reinterpret_cast<const void*>(&helperPath), &info) && info.dli_fname) {
        std::string p = info.dli_fname;
        size_t macos = p.rfind("/MacOS/");
        if (macos != std::string::npos)
            return p.substr(0, macos) + "/Helpers/" + name;
    }
    return "";
}

}  // namespace tdcoreai
