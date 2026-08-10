// CoreWLAN Scan CHOP — 周辺のWi-Fiをスキャンし、チャンネル別の混雑度・AP数・最大RSSIを出す。
// 「電波が混んでいる/空いているチャンネルはどこか」を数値化する電波環境ツール。
//
// SSID名/BSSID は macOS 14+ の privacy で伏せられる(Location権限が要り、プラグインからは
// 実質取得不可)。**ネットワーク名は出さないが**、AP数・RSSI・帯域(2.4/5GHz)・チャンネル幅は
// 取れるので、混雑状況とチャンネル選定には十分。
//
//   混雑度モデル: 各APの占有帯域(中心周波数 ± チャンネル幅/2)を、各20MHzチャンネル枠との
//   重なり割合で按分し、線形強度(10^(rssi/10))を加算する。40/80MHz幅のAPが隣接chへ与える
//   干渉も反映される。best channel = そのバンドで最も混雑度が低いチャンネル。
//
//   scanForNetworks はブロックする(数秒)ので**ワーカースレッドで実行**し、cook は最新の
//   集計スナップショットを読むだけ(非ブロック)。Scan Interval 秒ごと、または Rescan パルスで実行。
#import <Foundation/Foundation.h>
#import <CoreWLAN/CoreWLAN.h>
#include <dlfcn.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <Python.h>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {

// 出力する 2.4GHz / 5GHz チャンネル(20MHz枠)
static const int kCh24[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14};
static const int kCh5[] = {36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120,
                           124, 128, 132, 136, 140, 144, 149, 153, 157, 161, 165};
static const int kN24 = (int)(sizeof(kCh24) / sizeof(int));
static const int kN5 = (int)(sizeof(kCh5) / sizeof(int));

// チャンネル番号 → 中心周波数(MHz)
static double centerFreq(int ch, bool band5)
{
    if (band5)
        return 5000.0 + ch * 5.0;
    if (ch == 14)
        return 2484.0;
    return 2412.0 + (ch - 1) * 5.0;
}

// 集計スナップショット(worker が書き、cook が読む)
struct Snapshot {
    int networks = 0, n24 = 0, n5 = 0;
    float aps24[kN24] = {}, rssi24[kN24] = {}, cong24[kN24] = {};   // congは0-1正規化
    float aps5[kN5] = {}, rssi5[kN5] = {}, cong5[kN5] = {};
    int bestCh24 = 0, bestCh5 = 0;
    float bestCong24 = 0, bestCong5 = 0;
};

// Callbacks DAT の雛形。Get SSID Names を on にすると onGetSSID が呼ばれ、
// 隣に SSID 一覧を映す Info DAT を自動生成する（二重生成ガード付き）。
// 初回 cook 時に本体がこの雛形入り Callbacks DAT を自動生成・接続する（配置するだけで使える）。
static const char* PythonCallbacksDATStubs =
"# CoreWLAN Scan CHOP callbacks\n"
"#\n"
"# onGetSSID: 'Get SSID Names' を on にした瞬間に呼ばれる。\n"
"# 隣に SSID 一覧を表示する Info DAT を自動生成する（既にあれば何もしない）。\n"
"def onGetSSID(op, enabled):\n"
"\tif not enabled:\n"
"\t\treturn\n"
"\tp = op.parent()\n"
"\tname = op.name + '_ssid'\n"
"\tif p.op(name):\n"
"\t\treturn\n"
"\td = p.create(infoDAT, name)\n"
"\td.par.op = op.name\n"
"\td.nodeX = op.nodeX + 160\n"
"\td.nodeY = op.nodeY\n"
"\td.viewer = True\n"
"\treturn\n";

class CoreWLANScanCHOP final : public CHOP_CPlusPlusBase {
public:
    CoreWLANScanCHOP(const OP_NodeInfo* ni) : myNode(ni) { myThread = std::thread([this] { worker(); }); }
    ~CoreWLANScanCHOP() override
    {
        { std::lock_guard<std::mutex> l(myMx); myQuit = true; }
        myCv.notify_all();
        if (myThread.joinable()) myThread.join();
    }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override
    { g->cookEveryFrame = false; g->cookEveryFrameIfAsked = true; g->timeslice = false; }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override
    { info->numChannels = kTotal; info->numSamples = 1; info->sampleRate = 60; return true; }

    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override
    { name->setString(chanName(i).c_str()); }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        double interval = in->getParDouble("Scaninterval");
        bool getSsid = in->getParInt("Getssid") != 0;
        // 配置後の cook で雛形入り Callbacks DAT を自動生成・接続（配置するだけで使える）。
        // 生成直後はカスタムパラメータ未生成で失敗するため、成功するまで毎 cook リトライ
        if (!myBootstrapped) myBootstrapped = bootstrapCallbacksDAT();
        // Get SSID が off→on になった瞬間に、隣に SSID 一覧 Info DAT を自動生成する
        // (Callbacks DAT の onGetSSID を発火。二重生成ガードは Python 側)
        if (getSsid && !myPrevGetSsid && myNode && myNode->context) {
            bootstrapCallbacksDAT();   // ユーザーが Callbacks DAT を消していたら再生成
            PyObject* args = myNode->context->createArgumentsTuple(1, nullptr); // [0]=op
            if (args) {
                PyTuple_SET_ITEM(args, 1, PyBool_FromLong(getSsid ? 1 : 0));
                PyObject* r = myNode->context->callPythonCallback("onGetSSID", args, nullptr, nullptr);
                Py_DECREF(args);
                if (r) Py_DECREF(r);
            }
        }
        myPrevGetSsid = getSsid;
        // 設定を worker へ渡す + 起動トリガ判定
        {
            std::lock_guard<std::mutex> l(myMx);
            myInterval = interval;
            myGetSsid = getSsid;
            if (myRescan) { myRescan = false; myPending = true; myCv.notify_all(); }
        }

        Snapshot s;
        { std::lock_guard<std::mutex> l(myMx); s = mySnap; }

        int k = 0;
        out->channels[k++][0] = (float)myScans.load();
        out->channels[k++][0] = (float)(myScanning.load() ? 1 : 0);
        out->channels[k++][0] = (float)s.networks;
        out->channels[k++][0] = (float)s.n24;
        out->channels[k++][0] = (float)s.n5;
        for (int j = 0; j < kN24; j++) {
            out->channels[k++][0] = s.aps24[j];
            out->channels[k++][0] = s.rssi24[j];
            out->channels[k++][0] = s.cong24[j];
        }
        for (int j = 0; j < kN5; j++) {
            out->channels[k++][0] = s.aps5[j];
            out->channels[k++][0] = s.rssi5[j];
            out->channels[k++][0] = s.cong5[j];
        }
        out->channels[k++][0] = (float)s.bestCh24;
        out->channels[k++][0] = s.bestCong24;
        out->channels[k++][0] = (float)s.bestCh5;
        out->channels[k++][0] = s.bestCong5;
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "CoreWLAN Scan";
        { OP_NumericParameter p("Scaninterval"); p.label = "Scan Interval (s)"; p.page = P;
          p.defaultValues[0] = 10; p.minSliders[0] = 0; p.maxSliders[0] = 60; p.minValues[0] = 0;
          p.clampMins[0] = true; m->appendFloat(p); }
        { OP_NumericParameter p("Rescan"); p.label = "Rescan Now"; p.page = P; m->appendPulse(p); }
        { OP_NumericParameter p("Getssid"); p.label = "Get SSID Names (Location)"; p.page = P;
          p.defaultValues[0] = 0; m->appendToggle(p); }
    }
    void pulsePressed(const char* name, void*) override
    { if (strcmp(name, "Rescan") == 0) { std::lock_guard<std::mutex> l(myMx); myRescan = true; } }

    // SSID一覧を Info DAT で出す(ヘルパー経由・Location許可時のみ中身が入る)
    bool getInfoDATSize(OP_InfoDATSize* s, void*) override
    {
        std::lock_guard<std::mutex> l(myMx);
        s->rows = (int32_t)mySsidRows.size() + 1;   // +ヘッダ
        s->cols = 5;
        s->byColumn = false;
        return true;
    }
    void getInfoDATEntries(int32_t index, int32_t nEntries, OP_InfoDATEntries* e, void*) override
    {
        if (nEntries < 5) return;
        if (index == 0) {
            const char* h[] = {"ssid", "bssid", "rssi", "channel", "band"};
            for (int c = 0; c < 5; c++) e->values[c]->setString(h[c]);
            return;
        }
        std::lock_guard<std::mutex> l(myMx);
        int i = index - 1;
        if (i < 0 || i >= (int)mySsidRows.size()) return;
        for (int c = 0; c < 5; c++)
            e->values[c]->setString(c < (int)mySsidRows[i].size() ? mySsidRows[i][c].c_str() : "");
    }

    void getWarningString(OP_String* s, void*) override
    {
        // SSID 一覧が空のとき、ヘルパーが返した理由をそのまま伝える。
        // 黙って空の表を出すと「取れない」としか分からない(実際に詰まった)
        {
            std::lock_guard<std::mutex> l(myMx);
            if (!mySsidStatus.empty() && mySsidStatus != "ok") {
                if (mySsidStatus == "denied" || mySsidStatus == "timeout") {
                    s->setString("SSID names need Location permission for the bundled helper. "
                                 "System Settings > Privacy & Security > Location Services > "
                                 "turn on \"wifiscan-helper\". (Congestion channels work without it.)");
                    return;
                }
                if (mySsidStatus == "no_interface") { s->setString("No Wi-Fi interface found."); return; }
                s->setString(("Wi-Fi scan helper: " + mySsidStatus).c_str());
                return;
            }
        }
        if (myScans.load() > 0 && mySnap.networks == 0)
            s->setString("Scan returned 0 networks (Wi-Fi off, or no interface).");
    }
    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        const char* n[] = {"executes", "scans", "networks"};
        float v[] = {(float)myExec.load(), (float)myScans.load(), (float)mySnap.networks};
        c->name->setString(n[i]); c->value = v[i];
    }

private:
    static constexpr int kTotal = 5 + 14 * 3 + 25 * 3 + 4;   // = 126

    static std::string chanName(int i)
    {
        static const char* head[] = {"scans", "scanning", "networks", "networks_24", "networks_5"};
        if (i < 5) return head[i];
        int r = i - 5;
        if (r < kN24 * 3) {
            int ci = r / 3, f = r % 3;
            const char* fn[] = {"aps", "rssi", "congestion"};
            char b[32]; snprintf(b, sizeof b, "ch%d_24/%s", kCh24[ci], fn[f]); return b;
        }
        r -= kN24 * 3;
        if (r < kN5 * 3) {
            int ci = r / 3, f = r % 3;
            const char* fn[] = {"aps", "rssi", "congestion"};
            char b[32]; snprintf(b, sizeof b, "ch%d_5/%s", kCh5[ci], fn[f]); return b;
        }
        const char* tail[] = {"best_ch_24", "best_congestion_24", "best_ch_5", "best_congestion_5"};
        return tail[r - kN5 * 3];
    }

    void worker()
    {
        // 初回は即スキャン
        auto lastScan = std::chrono::steady_clock::now() - std::chrono::hours(1);
        for (;;) {
            {
                std::unique_lock<std::mutex> l(myMx);
                double iv = myInterval;
                // interval>0 なら定期、pending(Rescan) or quit で即起床
                auto wait = iv > 0 ? std::chrono::milliseconds((long)(iv * 1000))
                                   : std::chrono::milliseconds(500);
                myCv.wait_for(l, wait, [this] { return myQuit || myPending; });
                if (myQuit) return;
                bool due = myInterval > 0 &&
                           std::chrono::steady_clock::now() - lastScan >=
                               std::chrono::milliseconds((long)(myInterval * 1000));
                if (!myPending && !due) continue;
                myPending = false;
            }
            myScanning = true;
            Snapshot s = doScan();
            bool getSsid; { std::lock_guard<std::mutex> l(myMx); getSsid = myGetSsid; }
            if (getSsid) runSsidHelper();   // ヘルパーを起動して前回結果を読む(Location許可時のみ中身)
            lastScan = std::chrono::steady_clock::now();
            { std::lock_guard<std::mutex> l(myMx); mySnap = s; }
            myScanning = false;
            myScans++;
        }
    }

    // 同梱ヘルパー.appのパス(Contents/Resources/Helpers/wifiscan-helper.app)を dladdr で求める
    static std::string helperAppPath()
    {
        Dl_info info;
        if (dladdr((const void*)&helperAppPath, &info) && info.dli_fname) {
            std::string exe = info.dli_fname;   // .../Contents/MacOS/CoreWLANScanCHOP
            size_t pos = exe.rfind("/MacOS/");
            if (pos != std::string::npos)
                return exe.substr(0, pos) + "/Resources/Helpers/wifiscan-helper.app";
        }
        return "";
    }
    static std::string cachePath()
    {
        return std::string(NSHomeDirectory().UTF8String) + "/Library/Caches/TDAppleML/wifiscan.json";
    }

    // ヘルパーapp(独自Info.plist・Location用途文字列あり)を open で起動し、前回のJSON結果を読む。
    // 初回は Location 許可ダイアログが出る(ヘルパーapp宛)。許可後はSSIDが入る。
    void runSsidHelper()
    {
        @autoreleasepool {
            std::string app = helperAppPath();
            std::string cache = cachePath();
            if (app.empty()) return;
            // 起動(-g:前面に出さない -j:非表示。--args で出力先を渡す)
            NSTask* task = [[NSTask alloc] init];
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
            task.arguments = @[ @"-g", @"-j", [NSString stringWithUTF8String:app.c_str()],
                                @"--args", [NSString stringWithUTF8String:cache.c_str()] ];
            @try { [task launchAndReturnError:nil]; } @catch (NSException*) {}
            // 前回の結果を読む(今起動したものは数秒後に書く。次のcookで反映)
            NSData* d = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:cache.c_str()]];
            if (!d) return;
            NSDictionary* o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if (![o isKindOfClass:[NSDictionary class]]) return;
            std::string st;
            if ([o[@"status"] isKindOfClass:[NSString class]]) st = [o[@"status"] UTF8String];
            std::vector<std::vector<std::string>> rows;
            NSArray* nets = o[@"networks"];
            if ([nets isKindOfClass:[NSArray class]]) {
                for (NSDictionary* n in nets) {
                    if (![n isKindOfClass:[NSDictionary class]]) continue;
                    std::string ssid = n[@"ssid"] ? [[n[@"ssid"] description] UTF8String] : "";
                    if (ssid.empty()) continue;   // 名前が取れないものは出さない
                    std::string bssid = n[@"bssid"] ? [[n[@"bssid"] description] UTF8String] : "";
                    char rb[16]; snprintf(rb, sizeof rb, "%d", [n[@"rssi"] intValue]);
                    char cb[16]; snprintf(cb, sizeof cb, "%d", [n[@"channel"] intValue]);
                    std::string band = n[@"band"] ? [[n[@"band"] description] UTF8String] : "";
                    rows.push_back({ssid, bssid, rb, cb, band});
                }
            }
            std::lock_guard<std::mutex> l(myMx);
            mySsidRows = std::move(rows);
            mySsidStatus = st;
        }
    }

    Snapshot doScan()
    {
        Snapshot s;
        // 各20MHzチャンネル枠の生の混雑度(線形強度和)
        std::vector<double> raw24(kN24, 0.0), raw5(kN5, 0.0);
        @autoreleasepool {
            CWInterface* itf = [[CWWiFiClient sharedWiFiClient] interface];
            if (!itf) return s;
            NSError* err = nil;
            NSSet<CWNetwork*>* nets = [itf scanForNetworksWithName:nil error:&err];
            if (!nets) return s;
            s.networks = (int)nets.count;
            for (CWNetwork* n in nets) {
                CWChannel* c = n.wlanChannel;
                if (!c) continue;
                bool band5 = (c.channelBand == kCWChannelBand5GHz);
                int chNum = (int)c.channelNumber;
                double rssi = (double)n.rssiValue;
                double lin = pow(10.0, rssi / 10.0);
                // チャンネル幅(MHz)
                double width = 20;
                switch (c.channelWidth) {
                    case kCWChannelWidth40MHz: width = 40; break;
                    case kCWChannelWidth80MHz: width = 80; break;
                    case kCWChannelWidth160MHz: width = 160; break;
                    default: width = 20; break;
                }
                double fc = centerFreq(chNum, band5);
                double loA = fc - width / 2, hiA = fc + width / 2;
                if (band5) s.n5++; else s.n24++;

                // 占有帯域を各出力20MHz枠へ按分加算
                const int* chs = band5 ? kCh5 : kCh24;
                int nch = band5 ? kN5 : kN24;
                std::vector<double>& raw = band5 ? raw5 : raw24;
                float* apsArr = band5 ? s.aps5 : s.aps24;
                float* rssiArr = band5 ? s.rssi5 : s.rssi24;
                for (int j = 0; j < nch; j++) {
                    double oc = centerFreq(chs[j], band5);
                    double loO = oc - 10, hiO = oc + 10;
                    double ov = std::min(hiA, hiO) - std::max(loA, loO);
                    if (ov > 0) raw[j] += (ov / 20.0) * lin;
                    // 中心chが一致するものを AP数/最大RSSI に計上
                    if (chs[j] == chNum) {
                        apsArr[j] += 1;
                        if (rssiArr[j] == 0 || rssi > rssiArr[j]) rssiArr[j] = (float)rssi;
                    }
                }
            }
        }
        // 正規化 + best 選定(バンドごと)
        finalizeBand(raw24, s.cong24, kCh24, kN24, s.bestCh24, s.bestCong24);
        finalizeBand(raw5, s.cong5, kCh5, kN5, s.bestCh5, s.bestCong5);
        return s;
    }

    static void finalizeBand(std::vector<double>& raw, float* cong, const int* chs, int n,
                             int& bestCh, float& bestCong)
    {
        double mx = 0;
        for (int j = 0; j < n; j++) mx = std::max(mx, raw[j]);
        int bi = 0; double bmin = 1e300;
        for (int j = 0; j < n; j++) {
            cong[j] = mx > 0 ? (float)(raw[j] / mx) : 0.f;
            if (raw[j] < bmin) { bmin = raw[j]; bi = j; }
        }
        bestCh = chs[bi];
        bestCong = mx > 0 ? (float)(raw[bi] / mx) : 0.f;
    }

    // Callbacks DAT が未接続なら、雛形入り Text DAT を自分の下に生成して接続する。
    // cook(メインスレッド)から呼ぶ。TD 組み込み Python を直接実行(PyRun_String)。
    // 生成直後の cook ではカスタムパラメータ(callbacks)がまだ無いことがある(既知のTD挙動)
    // → 成功(=callbacks 接続済み)を __cwlan_ok で読み戻し、成功するまで毎 cook リトライする。
    bool bootstrapCallbacksDAT()
    {
        if (!myNode || !myNode->context) return false;
        PyGILState_STATE g = PyGILState_Ensure();
        // opPath は空のことがある(実測)→ createArgumentsTuple の args[0](=自ノードの
        // PyObject)を __main__ に渡してパス非依存で自ノードを参照する
        // __main__ グローバルには op/textDAT が無いことがある → import td で明示参照
        std::string py;
        py += "__cwlan_ok = False\n";
        py += "try:\n";
        py += "\timport td\n";
        py += "\tn = __cwlan_node\n";
        py += "\tif n and hasattr(n.par, 'callbacks'):\n";
        py += "\t\tif not n.par.callbacks.eval():\n";
        py += "\t\t\tp = n.parent()\n";
        py += "\t\t\tnm = n.name + '_callbacks'\n";
        py += "\t\t\td = p.op(nm)\n";
        py += "\t\t\tif not d:\n";
        py += "\t\t\t\td = p.create(td.textDAT, nm)\n";
        py += "\t\t\t\td.nodeX = n.nodeX\n";
        py += "\t\t\t\td.nodeY = n.nodeY - 130\n";
        py += "\t\t\t\td.text = '''";
        py += PythonCallbacksDATStubs;
        py += "'''\n";
        py += "\t\t\t\td.dock = n\n";           // GLSLのシェーダDATと同じくホストノードへドック
        py += "\t\t\t\td.expose = True\n";      // ホスト下部にチップを表示(Falseだと×チップ)
        py += "\t\t\t\td.viewer = True\n";      // 開いた時はGLSL同様にテキストが見える
        py += "\t\t\t\td.showDocked = False\n"; // 既定は閉じる(↓チップ。↑/↓開閉の実体はこのフラグ)
        py += "\t\t\tn.par.callbacks = nm\n";
        py += "\t\t__cwlan_ok = bool(n.par.callbacks.eval())\n";
        py += "except Exception:\n";
        py += "\timport traceback as __cwlan_tb\n";
        py += "\t__cwlan_err = __cwlan_tb.format_exc()\n";
        bool ok = false;
        PyObject* main = PyImport_AddModule("__main__");                // borrowed
        PyObject* dict = main ? PyModule_GetDict(main) : nullptr;      // borrowed
        PyObject* args = myNode->context->createArgumentsTuple(0, nullptr); // [0]=op
        if (dict && args) {
            PyDict_SetItemString(dict, "__cwlan_node", PyTuple_GET_ITEM(args, 0));
            PyObject* r = PyRun_String(py.c_str(), Py_file_input, dict, dict);
            if (r) Py_DECREF(r); else PyErr_Clear();
            PyObject* v = PyDict_GetItemString(dict, "__cwlan_ok");    // borrowed
            ok = v && PyObject_IsTrue(v) == 1;
            PyDict_DelItemString(dict, "__cwlan_node");
        }
        if (args) Py_DECREF(args);
        PyGILState_Release(g);
        return ok;
    }

    const OP_NodeInfo* myNode = nullptr;   // Python コールバック用(context)
    bool myPrevGetSsid = false;            // Getssid の off→on 遷移検出
    bool myBootstrapped = false;           // 初回 cook の Callbacks DAT 自動生成済み
    std::thread myThread; std::mutex myMx; std::condition_variable myCv;
    bool myQuit = false, myPending = false, myRescan = false, myGetSsid = false;
    double myInterval = 10;
    Snapshot mySnap;
    std::vector<std::vector<std::string>> mySsidRows;   // myMx 保護(SSID一覧)
    std::string mySsidStatus;   // myMx 保護。ヘルパーの status(ok/denied/timeout/no_interface)
    std::atomic<uint64_t> myExec{0}, myScans{0};
    std::atomic<bool> myScanning{false};
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Corewlanscan");
    i->customOPInfo.opLabel->setString("CoreWLAN Scan");
    i->customOPInfo.opIcon->setString("CWS");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/CoreWLANScan/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 0; i->customOPInfo.maxInputs = 0;
    i->customOPInfo.pythonCallbacksDAT = PythonCallbacksDATStubs;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new CoreWLANScanCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<CoreWLANScanCHOP*>(i); }
}
