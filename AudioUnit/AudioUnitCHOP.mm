// AudioUnit CHOP — Audio Unit エフェクトを TD のオーディオ経路でホストする
//
// TouchDesigner の Audio VST CHOP は **VST3 専用**（同梱 JUCE に AudioUnitPluginFormat が
// 入っていない）。macOS には標準で Apple 純正の AU エフェクトが 20 数個入っていて、
// サードパーティも AU で配布されることが多いので、その穴を埋める。
//
// 実装の型は AVAudio Spatial と同じ:
//   入力CHOP → AVAudioSourceNode → AVAudioUnit(=AU) → mainMixer → manual rendering で1ブロック取る
// timeslice=true なので入出力のサンプル数は TD が揃えてくれる。
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioToolbox/AudioUnitUtilities.h>   // AUEventListenerNotify(GUI へ変更を伝える)
#import <CoreAudioKit/CoreAudioKit.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#include "CHOP_CPlusPlusBase.h"
#include "PyCallbacksBootstrap.h"
#include <string>
#include <vector>
#include <unordered_map>
#include <atomic>
#include <cmath>

using namespace TD;

// プラグインのウインドウの閉じるボタン。AppKit スレッドで呼ばれるので**フラグを立てるだけ**にし、
// cook 側で Show UI トグルを落とす（AppKit から TD に触ると THREAD CONFLICT になる）。
// クラス名はバンドル固有にする（同名クラスを複数バンドルで定義すると ObjC ランタイムが
// 1つの実装を使い回して owner のキャスト先が食い違う）
@interface TDAudioUnitWinDelegate : NSObject <NSWindowDelegate>
@property (assign, nonatomic) std::atomic<bool>* flag;
@end
@implementation TDAudioUnitWinDelegate
- (BOOL)windowShouldClose:(NSWindow*)sender
{
    if (self.flag) self.flag->store(true);
    [sender orderOut:nil];
    return NO;   // 破棄はせず隠すだけ。再度 Show UI で出せる
}
@end

namespace {

// 「type:subtype:manufacturer」を16進で表した安定ID。表示名は再インストールや
// ローカライズで変わりうるが、この3つ組は変わらない（CoreMIDI の uniqueID と同じ考え方）
std::string descToId(const AudioComponentDescription& d)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "%08x:%08x:%08x",
             (unsigned)d.componentType, (unsigned)d.componentSubType, (unsigned)d.componentManufacturer);
    return buf;
}
bool idToDesc(const std::string& s, AudioComponentDescription* out)
{
    unsigned t = 0, sub = 0, m = 0;
    if (sscanf(s.c_str(), "%x:%x:%x", &t, &sub, &m) != 3) return false;
    out->componentType = t; out->componentSubType = sub; out->componentManufacturer = m;
    out->componentFlags = 0; out->componentFlagsMask = 0;
    return true;
}

// AU のパラメータ識別子は空白や記号を含むので、CHOP のチャンネル名に使える形へ落とす
std::string sanitize(NSString* s)
{
    std::string r;
    for (NSUInteger i = 0; i < s.length && r.size() < 30; i++) {
        unichar c = [s characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) r += (char)c;
        else if (c == ' ' || c == '_' || c == '-') { if (!r.empty() && r.back() != '_') r += '_'; }
    }
    while (!r.empty() && r.back() == '_') r.pop_back();
    if (r.empty()) r = "p";
    if (r[0] >= '0' && r[0] <= '9') r = "p" + r;
    return r;
}

constexpr int kLearnSlots = 16;

// AU は「GUI のつまみをどう振るか」をフラグで持っている(bit16〜18 に値 + bit22)。
// 線形正規化のままだと対数パラメータでズレる: AUPeakLimiter の Attack Time は
// つまみ中央(0.5)が実値 0.00387 で、線形正規化すると 0.114 にしかならない(実測)。
// 実測の内訳(この Mac のエフェクト24個・231パラメータ):
//   linear 181 / Logarithmic 41 / SquareRoot 3 / Squared 4 / Cubed 1 / Exponential 1
//
// p = つまみ位置(0〜1) ⇔ v = 実値
inline float curveToValue(AudioUnitParameterOptions curve, float p, float lo, float hi)
{
    if (p < 0) p = 0; else if (p > 1) p = 1;
    const AudioUnitParameterOptions t = GetAudioUnitParameterDisplayType(curve);
    if ((t == kAudioUnitParameterFlag_DisplayLogarithmic ||
         t == kAudioUnitParameterFlag_DisplayExponential) && lo > 0 && hi > lo)
        return lo * powf(hi / lo, p);
    float n = p;
    if      (t == kAudioUnitParameterFlag_DisplaySquareRoot) n = p * p;
    else if (t == kAudioUnitParameterFlag_DisplaySquared)    n = sqrtf(p);
    else if (t == kAudioUnitParameterFlag_DisplayCubed)      n = cbrtf(p);
    else if (t == kAudioUnitParameterFlag_DisplayCubeRoot)   n = p * p * p;
    return lo + n * (hi - lo);
}
inline float valueToCurve(AudioUnitParameterOptions curve, float v, float lo, float hi)
{
    if (hi <= lo) return 0.f;
    if (v < lo) v = lo; else if (v > hi) v = hi;
    const AudioUnitParameterOptions t = GetAudioUnitParameterDisplayType(curve);
    if ((t == kAudioUnitParameterFlag_DisplayLogarithmic ||
         t == kAudioUnitParameterFlag_DisplayExponential) && lo > 0 && hi > lo)
        return logf(v / lo) / logf(hi / lo);
    const float n = (v - lo) / (hi - lo);
    if      (t == kAudioUnitParameterFlag_DisplaySquareRoot) return sqrtf(n);
    else if (t == kAudioUnitParameterFlag_DisplaySquared)    return n * n;
    else if (t == kAudioUnitParameterFlag_DisplayCubed)      return n * n * n;
    else if (t == kAudioUnitParameterFlag_DisplayCubeRoot)   return cbrtf(n);
    return n;
}

struct PluginEntry {
    std::string id;      // "aufx:dist:appl" を16進にしたもの
    std::string label;   // "AUDistortion — Apple"
};

struct ParamEntry {
    AUParameter* p = nil;
    std::string chan;    // 自動化 CHOP で使うチャンネル名
    std::string ident;   // AU 側の識別子
    std::string name;    // 表示名
    std::string unit;
    float minV = 0, maxV = 1, cur = 0;
    float lastAU   = NAN;      // AU側で最後に見た値。ここから動いていたら GUI が動かされた
    float lastSlot = NAN;      // Learn 枠で最後に見た値。ここから動いていたら TD 側で動かされた
    uint64_t address = 0;      // AUParameter のアドレス。**v2 のパラメータIDとは別物**(実測)
    AudioUnitParameterID pid = 0;  // v2 側のID。GUI はこちらを読み書きする
    AudioUnitParameterOptions curve = 0;  // GUI のつまみの振り方(対数など)
    std::string type = "float";   // float / int / menu / toggle
    std::string values;           // menu のときの選択肢名を | で連結
    int      learnSlot = -1;   // 割り当てられた Learn 枠(1始まり。-1=未割り当て)
};

} // namespace

static const char* kPanelScript = R"AUPANEL(# AudioUnit CHOP が生成した Learned パネル。
#
# 隣の Info DAT を読み、learn 済みパラメータの**型どおりの**TDパラメータを生やす
# (スライダー / プルダウン / トグル / 整数)。値はプラグインと双方向に同期する:
#   プラグインの GUI を動かす → ここのパラメータが追従
#   ここのパラメータを動かす → チャンネルで出力され AudioUnit CHOP の入力1が受け取る
#
# learn の内容が変わったら自動で作り直す。手で編集してもよいが
# Create / Rebuild Panel を押すと上書きされる。

def _params_dat(scriptOp):
    # **参照をカスタムパラメータに持たせてはいけない。** setuppars はカスタム
    # パラメータを作り直すので、そのたびに参照が消えて何も生えなくなる(実測)。
    # storage(パラメータではないので消えない)+ 命名規則で解決する
    path = scriptOp.fetch("params", "")
    d = op(path) if path else None
    if d is None:
        nm = scriptOp.name
        host = nm[:-6] if nm.endswith("_panel") else nm
        d = scriptOp.parent().op(host + "_params")
    return d


def _rows(scriptOp):
    try:
        d = _params_dat(scriptOp)
    except Exception:
        return []
    if not d or d.numRows < 2:
        return []
    hdr = [d[0, c].val for c in range(d.numCols)]
    out = []
    for r in range(1, d.numRows):
        row = dict(zip(hdr, [d[r, c].val for c in range(d.numCols)]))
        if row.get("learn"):
            row["_row"] = r
            out.append(row)
    return out


def _pname(ch):
    s = "".join(c for c in ch if c.isalnum())
    return (s[:1].upper() + s[1:].lower()) if s else "P"


def onSetupParameters(scriptOp):
    page = scriptOp.appendCustomPage("Learned")
    for row in _rows(scriptOp):
        nm = _pname(row["channel"])
        t = row.get("type", "float")
        lo = float(row["min"])
        hi = float(row["max"])
        cur = float(row["value"])
        label = row["name"]
        if t == "toggle":
            p = page.appendToggle(nm, label=label)[0]
            p.default = int(round(cur))
            p.val = int(round(cur))
        elif t == "menu":
            p = page.appendMenu(nm, label=label)[0]
            n = int(round(hi - lo)) + 1
            labels = row.get("values", "").split("|") if row.get("values") else []
            if len(labels) != n:
                labels = [str(int(lo) + i) for i in range(n)]
            p.menuNames = ["v%d" % (int(lo) + i) for i in range(n)]
            p.menuLabels = labels
            p.menuIndex = max(0, min(n - 1, int(round(cur - lo))))
        elif t == "int":
            p = page.appendInt(nm, label=label)[0]
            p.normMin, p.normMax = lo, hi
            p.min, p.max = lo, hi
            p.clampMin = p.clampMax = True
            p.default = int(round(cur))
            p.val = int(round(cur))
        else:
            p = page.appendFloat(nm, label=label)[0]
            p.normMin, p.normMax = lo, hi
            p.min, p.max = lo, hi
            p.clampMin = p.clampMax = True
            p.default = cur
            p.val = cur
    return


def _curve_to_value(curve, p, lo, hi):
    # 枠を廃止したので、0〜1 の自動化(MIDI)はここで実値へ直す。
    # AU が持っている表示曲線に合わせないと、対数パラメータで中央が合わない
    p = 0.0 if p < 0 else (1.0 if p > 1 else p)
    if curve == "log" and lo > 0 and hi > lo:
        return lo * (hi / lo) ** p
    n = p
    if curve == "sqrt":
        n = p * p
    elif curve == "sq":
        n = p ** 0.5
    elif curve == "cube":
        n = p ** (1.0 / 3.0)
    elif curve == "cbrt":
        n = p * p * p
    return lo + n * (hi - lo)


def _read(par, lo):
    if par.style == "Menu":
        return float(lo + par.menuIndex)
    return float(par.eval())


def _write(par, v, lo):
    if par.style == "Menu":
        par.menuIndex = max(0, min(len(par.menuNames) - 1, int(round(v - lo))))
    elif par.style == "Toggle":
        par.val = 1 if v >= 0.5 else 0
    else:
        par.val = v


def onCook(scriptOp):
    scriptOp.clear()
    st = scriptOp.storage
    # **表の作り直しは Info DAT が cook されたときだけ。**
    # 16x10 のセルを毎フレーム読むと Python だけで数 ms かかる(実測)
    d = _params_dat(scriptOp)
    sig = "%d:%s" % (d.numRows if d else 0,
                     "".join(d[r, "learn"].val for r in range(1, d.numRows)) if d else "")
    rows = st.get("rows")
    if rows is None or st.get("sig") != sig:
        rows = _rows(scriptOp)
        st["rows"] = rows
        st["sig"] = sig
    # **実際に生えているパラメータ**と learn の内容を突き合わせる。
    # 「作り直した」というフラグを持つと、作り直しに失敗したときに詰まって復帰できない
    built = set(p.name for p in scriptOp.customPars if p.page.name == "Learned")
    want = set(_pname(r["channel"]) for r in rows)
    if built != want:
        st["au"] = {}
        run("op(%r).par.setuppars.pulse()" % scriptOp.path, delayFrames=1)
        return
    names = built
    seen = st.get("au", {})
    for r in rows:
        nm = _pname(r["channel"])
        if nm not in names:
            continue
        par = scriptOp.par[nm]
        lo = float(r["min"])
        hi = float(r["max"])
        auv = float(d[r["_row"], "value"].val) if d else float(r["value"])
        span = (hi - lo) if hi > lo else 1.0
        # 入力0に 0〜1 の自動化(MIDI など)が来ていれば、それを最優先で反映する
        drv = None
        if scriptOp.inputs and scriptOp.inputs[0]:
            ch = scriptOp.inputs[0].chan(r["channel"])
            if ch is not None:
                drv = _curve_to_value(r.get("curve", "linear"), float(ch[0]), lo, hi)
        if drv is not None:
            _write(par, drv, lo)
            seen[nm] = drv
        # プラグイン側(GUI)が動いていたら、こちらのパラメータへ書き戻す
        elif nm not in seen or abs(auv - seen[nm]) > span * 1e-5:
            _write(par, auv, lo)
            seen[nm] = auv
        else:
            seen[nm] = auv
        # 現在値をチャンネルで出す。AudioUnit CHOP が入力1で受け取る
        scriptOp.appendChan(r["channel"])[0] = _read(par, lo)
    st["au"] = seen
    return
)AUPANEL";

// ---------------------------------------------------------------- plugin

class AudioUnitCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit AudioUnitCHOP(const OP_NodeInfo* info) : myNode(info) { rescan(); }
    virtual ~AudioUnitCHOP() { closeWindowSync(); teardown(); }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrame = false; g->cookEveryFrameIfAsked = true;
        g->timeslice = true;   // オーディオフィルタなので必須（入出力のサンプル数を TD が揃える）
    }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override
    {
        // 入力がモノでもステレオを出す。true を返して 2ch を明示しないと、
        // 出力 ch 数が入力に一致してしまい channels[1] が範囲外になる（AVAudio Spatial の教訓）
        info->numChannels = 2;
        return true;
    }
    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override
    {
        name->setString(i == 0 ? "left" : "right");
    }

    // ------------------------------------------------------------ cook

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        const int n = out->numSamples;
        for (int c = 0; c < out->numChannels; c++) memset(out->channels[c], 0, sizeof(float) * n);

        @autoreleasepool {
            // 閉じるボタンが押されていたら Show UI を落とす（AppKit 側から TD に触らないための往復）
            if (myWindowClosed.exchange(false)) { if (myUnit) saveState(); setShowUIPar(0); }

            const bool active = in->getParInt("Active") != 0;
            std::string want = in->getParString("Plugin") ? in->getParString("Plugin") : "";
            if (want == "none") want.clear();

            if (want != myWantId) { myWantId = want; teardownUnit(); if (!want.empty()) beginLoad(want); }

            // 非同期ロードの完了を拾う
            if (myLoaded.exchange(false)) { adoptLoadedUnit(); restoreState(in); restoreLearnMap(in); }
            if (myLoadFailed.exchange(false)) myErr = myErrPending;

            const OP_CHOPInput* ci = in->getInputCHOP(0);
            if (!active || !ci || ci->numChannels < 1 || ci->numSamples < 1 || out->numChannels < 2) return;

            const double sr = ci->sampleRate > 0 ? ci->sampleRate : 44100.0;
            if (!myUnit) {                        // プラグイン未選択/ロード中は素通し
                passThrough(out, ci, n, in);
                return;
            }
            if (!ensureEngine(sr, n)) { passThrough(out, ci, n, in); return; }

            applyPreset(in);
            // **入力を先に適用する。** 逆順だと、パネル(入力1)が毎cook 出す値が
            // Learn 枠の変更を上書きしてしまい、枠から動かせなくなる(実測)。
            // 先に入力を反映しておけば syncParams から見て「AU は動いていない」状態になり、
            // 枠の変更がそのまま通る
            applyParamsFromInput(in);
            syncParams(in);
            myBypassed = in->getParInt("Bypass") != 0;
            myUnit.AUAudioUnit.shouldBypassEffect = myBypassed;
            syncWindow(in);
            if (myWantSaveState.exchange(false)) saveState();

            // 入力をステレオに整えて source node に渡す
            const int inN = ci->numSamples;
            myInL.assign(inN, 0.f); myInR.assign(inN, 0.f);
            if (ci->numChannels == 1) {
                const float* s = ci->getChannelData(0);
                memcpy(myInL.data(), s, sizeof(float) * inN);
                memcpy(myInR.data(), s, sizeof(float) * inN);
            } else {
                memcpy(myInL.data(), ci->getChannelData(0), sizeof(float) * inN);
                memcpy(myInR.data(), ci->getChannelData(1), sizeof(float) * inN);
            }
            myInPos = 0;

            const int render = n < inN ? n : inN;
            NSError* err = nil;
            AVAudioEngineManualRenderingStatus st =
                [myEngine renderOffline:(AVAudioFrameCount)render toBuffer:myOutBuf error:&err];
            if (st != AVAudioEngineManualRenderingStatusSuccess) {
                myWarn = "render failed";
                passThrough(out, ci, n, in);
                return;
            }
            const int copy = render < (int)myOutBuf.frameLength ? render : (int)myOutBuf.frameLength;
            const float* L = myOutBuf.floatChannelData[0];
            const float* R = myOutBuf.floatChannelData[1];

            const float wet  = (float)in->getParDouble("Drywet");
            const float dry  = 1.0f - wet;
            const float gain = (float)in->getParDouble("Gain");
            for (int i = 0; i < copy; i++) {
                out->channels[0][i] = (L[i] * wet + myInL[i] * dry) * gain;
                out->channels[1][i] = (R[i] * wet + myInR[i] * dry) * gain;
            }
            myRenders++;
        }
    }

    // ------------------------------------------------------------ parameters

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "AudioUnit";
        { OP_NumericParameter p("Active"); p.label = "Active"; p.page = P; p.defaultValues[0] = 1; m->appendToggle(p); }
        {
            OP_StringParameter p("Plugin"); p.label = "Plugin"; p.page = P;
            p.defaultValue = "none";      // 動的メニューは既定値が空だとパラメータ自体が生成されない
            m->appendDynamicStringMenu(p);
        }
        { OP_NumericParameter p("Rescan"); p.label = "Rescan Plugins"; p.page = P; m->appendPulse(p); }
        {
            OP_StringParameter p("Preset"); p.label = "Factory Preset"; p.page = P;
            p.defaultValue = "none";
            m->appendDynamicStringMenu(p);
        }
        { OP_NumericParameter p("Bypass"); p.label = "Bypass"; p.page = P; p.defaultValues[0] = 0; m->appendToggle(p); }
        { OP_NumericParameter p("Drywet"); p.label = "Dry / Wet"; p.page = P; p.defaultValues[0] = 1;
          p.minSliders[0] = 0; p.maxSliders[0] = 1; p.minValues[0] = 0; p.maxValues[0] = 1;
          p.clampMins[0] = true; p.clampMaxes[0] = true; m->appendFloat(p); }
        { OP_NumericParameter p("Gain"); p.label = "Output Gain"; p.page = P; p.defaultValues[0] = 1;
          p.minSliders[0] = 0; p.maxSliders[0] = 2; m->appendFloat(p); }
        {
            // MIDI コンは 0〜1 で来るので、既定は「そのパラメータの min〜max へ引き伸ばす」
            OP_StringParameter p("Inputrange"); p.label = "Input Range"; p.page = P;
            p.defaultValue = "Normalized";
            const char* n[] = {"Normalized", "Raw"};
            const char* l[] = {"Normalized 0-1 -> parameter range", "Raw value"};
            m->appendMenu(p, 2, n, l);
        }
        { OP_NumericParameter p("Showui"); p.label = "Display GUI"; p.page = P; p.defaultValues[0] = 0; m->appendToggle(p); }
        { OP_NumericParameter p("Alwaysontop"); p.label = "Always On Top"; p.page = P; p.defaultValues[0] = 0; m->appendToggle(p); }
        { OP_NumericParameter p("Resetstate"); p.label = "Reset Plugin State"; p.page = P; m->appendPulse(p); }

        // Audio VST CHOP の learn parms 相当。TD は実行中にパラメータを増やせないので、
        // 枠を先に kLearnSlots 個用意しておき、GUI で触ったパラメータをそこへ割り当てる
        const char* L = "Learn";
        { OP_NumericParameter p("Learn"); p.label = "Learn Parameters"; p.page = L; p.defaultValues[0] = 0; m->appendToggle(p); }
        { OP_NumericParameter p("Clearlearned"); p.label = "Clear Learned"; p.page = L; m->appendPulse(p); }
        { OP_NumericParameter p("Createpanel"); p.label = "Create / Rebuild Panel"; p.page = L; m->appendPulse(p); }
        {
            OP_StringParameter p("Learnmap"); p.label = "Learned Mapping"; p.page = L;
            p.defaultValue = ""; m->appendString(p);
        }

        const char* S = "State";
        { OP_NumericParameter p("Loadstate"); p.label = "Load Plugin State"; p.page = S; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Savestate"); p.label = "Save Plugin State"; p.page = S; m->appendPulse(p); }
        {
            // GUI で作った音を .toe と一緒に持ち回るための入れ物。AU の fullState を
            // バイナリ plist → base64 にしたもの（Apple 純正エフェクトで 312〜1144 文字と実測）
            OP_StringParameter p("Statedata"); p.label = "Plugin State (base64)"; p.page = S;
            p.defaultValue = ""; m->appendString(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (!strcmp(name, "Rescan")) rescan();
        else if (!strcmp(name, "Resetstate")) myWantReset = true;
        else if (!strcmp(name, "Savestate")) myWantSaveState = true;
        else if (!strcmp(name, "Clearlearned")) myWantClearLearn = true;
        else if (!strcmp(name, "Createpanel")) myWantPanel = true;
    }

    void buildDynamicMenu(const OP_Inputs*, OP_BuildDynamicMenuInfo* info, void*) override
    {
        const std::string which = info->name ? info->name : "";
        if (which == "Plugin") {
            info->addMenuEntry("none", "(none)");
            for (const auto& e : myPlugins) info->addMenuEntry(e.id.c_str(), e.label.c_str());
        } else if (which == "Preset") {
            info->addMenuEntry("none", "(none)");
            for (size_t i = 0; i < myPresets.size(); i++)
                info->addMenuEntry(std::to_string(i).c_str(), myPresets[i].c_str());
        }
    }

    // ------------------------------------------------------------ info

    int32_t getNumInfoCHOPChans(void*) override { return 8; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        static const char* n[] = { "executes", "renders", "samplerate", "loaded",
                                   "params", "latency_ms", "bypassed", "learned" };
        const float v[] = { (float)myExec.load(), (float)myRenders.load(), (float)mySampleRate,
                            (float)(myUnit != nil), (float)myParams.size(),
                            (float)(myLatencySec * 1000.0), (float)myBypassed, (float)learnedCount() };
        c->name->setString(n[i]); c->value = v[i];
    }

    bool getInfoDATSize(OP_InfoDATSize* s, void*) override
    {
        s->rows = 1 + (int)myParams.size();
        s->cols = 11;
        s->byColumn = false;
        return true;
    }
    void getInfoDATEntries(int32_t row, int32_t, OP_InfoDATEntries* e, void*) override
    {
        auto set = [&](int i, const std::string& v) {
            myScratch[i] = v; e->values[i]->setString(myScratch[i].c_str());
        };
        if (row == 0) {
            set(0, "index"); set(1, "channel"); set(2, "name");
            set(3, "min"); set(4, "max"); set(5, "value"); set(6, "unit"); set(7, "learn");
            set(8, "type"); set(9, "values"); set(10, "curve");
            return;
        }
        const ParamEntry& p = myParams[row - 1];
        char b[64];
        set(0, std::to_string(row - 1));
        set(1, p.chan);
        set(2, p.name);
        snprintf(b, sizeof(b), "%g", p.minV); set(3, b);
        snprintf(b, sizeof(b), "%g", p.maxV); set(4, b);
        snprintf(b, sizeof(b), "%g", readParam(p)); set(5, b);
        set(6, p.unit);
        set(7, p.learnSlot > 0 ? ("learn" + std::to_string(p.learnSlot)) : "");
        set(8, p.type);
        set(9, p.values);
        {   // パネルが 0〜1 の自動化(MIDI)を実値へ直すのに使う
            const AudioUnitParameterOptions t = GetAudioUnitParameterDisplayType(p.curve);
            const char* c = "linear";
            if (t == kAudioUnitParameterFlag_DisplayLogarithmic ||
                t == kAudioUnitParameterFlag_DisplayExponential) c = "log";
            else if (t == kAudioUnitParameterFlag_DisplaySquareRoot) c = "sqrt";
            else if (t == kAudioUnitParameterFlag_DisplaySquared)    c = "sq";
            else if (t == kAudioUnitParameterFlag_DisplayCubed)      c = "cube";
            else if (t == kAudioUnitParameterFlag_DisplayCubeRoot)   c = "cbrt";
            set(10, c);
        }
    }

    void getWarningString(OP_String* s, void*) override { if (!myWarn.empty()) s->setString(myWarn.c_str()); }
    void getErrorString(OP_String* s, void*) override { if (!myErr.empty()) s->setString(myErr.c_str()); }

private:
    int learnedCount() const
    {
        int n = 0;
        for (int i = 0; i < kLearnSlots; i++) if (myLearnIdx[i] >= 0) n++;
        return n;
    }

    // ------------------------------------------------------------ scan

    void rescan()
    {
        @autoreleasepool {
            myPlugins.clear();
            AudioComponentDescription d = {};
            d.componentType = kAudioUnitType_Effect;
            NSArray<AVAudioUnitComponent*>* comps =
                [[AVAudioUnitComponentManager sharedAudioUnitComponentManager] componentsMatchingDescription:d];
            for (AVAudioUnitComponent* c in comps) {
                PluginEntry e;
                e.id = descToId(c.audioComponentDescription);
                e.label = std::string(c.name.UTF8String ?: "?") + "  —  " + std::string(c.manufacturerName.UTF8String ?: "?");
                myPlugins.push_back(e);
            }
        }
    }

    // ------------------------------------------------------------ load

    void beginLoad(const std::string& id)
    {
        AudioComponentDescription d = {};
        if (!idToDesc(id, &d)) { myErr = "bad plugin id"; return; }
        myErr.clear(); myWarn.clear();
        myLoadToken++;
        const uint64_t token = myLoadToken;
        // options=0 は「そのコンポーネントの既定の読み込み方」。v3 のアプリ拡張は
        // 別プロセスで動くので、その場合プラグインが落ちても TD は巻き込まれない
        [AVAudioUnit instantiateWithComponentDescription:d options:0
            completionHandler:^(AVAudioUnit* unit, NSError* err) {
                if (token != myLoadToken) return;          // 途中で選び直されていたら捨てる
                if (!unit) { myErrPending = err.localizedDescription.UTF8String ?: "load failed"; myLoadFailed = true; return; }
                myPendingUnit = unit;
                myLoaded = true;
            }];
    }

    void adoptLoadedUnit()
    {
        teardownEngine();
        myUnit = myPendingUnit; myPendingUnit = nil;
        myAppliedPreset = -2;
        buildParamTable();
        myLatencySec = myUnit ? myUnit.AUAudioUnit.latency : 0;
        myWindowTitle = myUnit ? (myUnit.name.UTF8String ?: "AudioUnit") : "AudioUnit";
        myErr.clear();
    }

    void buildParamTable()
    {
        myParams.clear(); myPresets.clear(); myChanMap.clear();
        if (!myUnit) return;
        AUAudioUnit* au = myUnit.AUAudioUnit;
        if (AUParameterTree* tree = au.parameterTree) {
            for (AUParameter* p in tree.allParameters) {
                ParamEntry e;
                e.p = p;
                e.ident = p.identifier.UTF8String ?: "";
                e.name  = p.displayName.UTF8String ?: e.ident;
                e.unit  = p.unitName.UTF8String ?: "";
                e.minV = p.minValue; e.maxV = p.maxValue; e.cur = p.value;
                e.address = p.address;
                // チャンネル名は**表示名から**作る。AU の identifier は AUDistortion のように
                // "0" "1" "2" と数字だけのことがあり、それを p0/p1 にすると別パラメータの
                // 添え字別名 p<index> と衝突しうる（実測で発覚）。表示名なら意味も読める
                e.chan = sanitize(p.displayName.length ? p.displayName : p.identifier);
                if (myChanMap.count(e.chan)) e.chan += "_" + std::to_string(myParams.size());
                const int idx = (int)myParams.size();
                myChanMap[e.chan] = idx;
                myChanMap["p" + std::to_string(idx)] = idx;   // 添え字でも指せる別名
                myParams.push_back(e);
            }
        }
        for (AUAudioUnitPreset* pr in (au.factoryPresets ?: @[]))
            myPresets.push_back(pr.name.UTF8String ?: "preset");
        myAddrToIndex.clear();
        for (size_t i = 0; i < myParams.size(); i++) myAddrToIndex[myParams[i].address] = (int)i;

        // v2 側のパラメータID一覧。**AUParameter.address とは一致しない**(実測: v2id=3 ↔ addr=10)。
        // 並び順は同じなので添え字で対応づける
        myAU2 = myUnit.audioUnit;
        UInt32 sz = 0;
        if (myAU2 && AudioUnitGetPropertyInfo(myAU2, kAudioUnitProperty_ParameterList,
                                              kAudioUnitScope_Global, 0, &sz, nullptr) == noErr && sz) {
            std::vector<AudioUnitParameterID> ids(sz / sizeof(AudioUnitParameterID));
            if (AudioUnitGetProperty(myAU2, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global,
                                     0, ids.data(), &sz) == noErr)
                for (size_t i = 0; i < myParams.size() && i < ids.size(); i++) {
                    myParams[i].pid = ids[i];
                    AudioUnitParameterInfo pinfo; UInt32 isz = sizeof(pinfo);
                    if (AudioUnitGetProperty(myAU2, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global,
                                             ids[i], &pinfo, &isz) == noErr) {
                        ParamEntry& pe = myParams[i];
                        pe.curve = pinfo.flags;
                        // AU はパラメータの単位で型を伝えてくる。実測(エフェクト24個・231個)では
                        // Boolean 18 / Indexed 24(うち19個は選択肢名あり)/ それ以外 189
                        if (pinfo.unit == kAudioUnitParameterUnit_Boolean) pe.type = "toggle";
                        else if (pinfo.unit == kAudioUnitParameterUnit_Indexed) {
                            NSArray<NSString*>* vs = pe.p ? pe.p.valueStrings : nil;
                            if (vs.count) {
                                pe.type = "menu";
                                pe.values = [[vs componentsJoinedByString:@"|"] UTF8String] ?: "";
                            } else pe.type = "int";
                        }
                    }
                }
        }
        installObserver();
    }

    // ------------------------------------------------------------ engine

    bool ensureEngine(double sr, int maxFrames)
    {
        const int cap = maxFrames * 2 < 4096 ? 4096 : maxFrames * 2;
        if (myEngine && fabs(mySampleRate - sr) < 0.5 && myMaxFrames >= maxFrames && myEngineUnit == myUnit)
            return true;
        teardownEngine();
        mySampleRate = sr; myMaxFrames = cap;

        AVAudioFormat* fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sr channels:2];
        if (!fmt) { myErr = "bad format"; return false; }

        myEngine = [[AVAudioEngine alloc] init];
        AudioUnitCHOP* self_ = this;
        mySource = [[AVAudioSourceNode alloc] initWithFormat:fmt renderBlock:
            ^OSStatus(BOOL*, const AudioTimeStamp*, AVAudioFrameCount frames, AudioBufferList* abl) {
                const int avail = (int)self_->myInL.size() - self_->myInPos;
                const int give  = (int)frames < avail ? (int)frames : (avail > 0 ? avail : 0);
                for (UInt32 b = 0; b < abl->mNumberBuffers && b < 2; b++) {
                    float* dst = (float*)abl->mBuffers[b].mData;
                    const std::vector<float>& src = (b == 0) ? self_->myInL : self_->myInR;
                    for (int i = 0; i < give; i++) dst[i] = src[self_->myInPos + i];
                    for (AVAudioFrameCount i = give; i < frames; i++) dst[i] = 0.f;
                }
                self_->myInPos += give;
                return noErr;
            }];

        [myEngine attachNode:mySource];
        [myEngine attachNode:myUnit];
        [myEngine connect:mySource to:myUnit format:fmt];
        [myEngine connect:myUnit to:myEngine.mainMixerNode format:fmt];

        NSError* err = nil;
        if (![myEngine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                                          format:fmt maximumFrameCount:(AVAudioFrameCount)cap error:&err]) {
            myErr = err.localizedDescription.UTF8String ?: "manual rendering failed";
            teardownEngine(); return false;
        }
        if (![myEngine startAndReturnError:&err]) {
            myErr = err.localizedDescription.UTF8String ?: "engine start failed";
            teardownEngine(); return false;
        }
        myOutBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:myEngine.manualRenderingFormat
                                                 frameCapacity:(AVAudioFrameCount)cap];
        myEngineUnit = myUnit;
        myErr.clear();
        return true;
    }

    void teardownEngine()
    {
        if (myEngine) { [myEngine stop]; }
        myEngine = nil; mySource = nil; myOutBuf = nil; myEngineUnit = nil; mySampleRate = 0;
    }
    void teardownUnit()
    {
        removeObserver();
        destroyWindow();
        teardownEngine();
        myUnit = nil; myPendingUnit = nil;
        myParams.clear(); myPresets.clear(); myChanMap.clear();
        myLatencySec = 0;
    }
    void teardown() { teardownUnit(); }

    // ------------------------------------------------------------ per-cook helpers

    void passThrough(CHOP_Output* out, const OP_CHOPInput* ci, int n, const OP_Inputs* in)
    {
        const float gain = (float)in->getParDouble("Gain");
        const int copy = n < ci->numSamples ? n : ci->numSamples;
        const float* L = ci->getChannelData(0);
        const float* R = ci->numChannels > 1 ? ci->getChannelData(1) : L;
        for (int i = 0; i < copy; i++) { out->channels[0][i] = L[i] * gain; out->channels[1][i] = R[i] * gain; }
    }

    void applyPreset(const OP_Inputs* in)
    {
        if (myWantReset) {
            myWantReset = false;
            [myUnit.AUAudioUnit reset];
            myAppliedPreset = -2;
        }
        const char* s = in->getParString("Preset");
        const int want = (s && strcmp(s, "none")) ? atoi(s) : -1;
        if (want == myAppliedPreset) return;
        myAppliedPreset = want;
        if (want < 0) return;
        NSArray<AUAudioUnitPreset*>* pr = myUnit.AUAudioUnit.factoryPresets;
        if (want < (int)pr.count) {
            myUnit.AUAudioUnit.currentPreset = pr[want];
            // 基準はリセットしない。プリセットによる変化も syncParams に
            // 「AU 側が動いた」として拾わせ、Learn 枠へ反映させる
        }
    }

    // 値の書き込みはここだけ。normalized なら 0〜1 をそのパラメータの min〜max へ引き伸ばす。
    // **自分が最後に書いた値と同じなら書かない**ので、動かしていないパラメータは
    // プラグインの GUI やプリセットが持ち主のままになる
    void writeParam(ParamEntry& e, float v, bool normalized)
    {
        float target = normalized ? curveToValue(e.curve, v, e.minV, e.maxV) : v;
        if (target < e.minV) target = e.minV;
        if (target > e.maxV) target = e.maxV;
        if (!std::isnan(e.lastAU) && fabsf(target - e.lastAU) < 1e-7f) return;
        e.p.value = target;              // v3→v2 は同期するので、音はこれだけで変わる
        notifyGUI(e);                    // ただし GUI は通知しないと描き直さない
        // **書いた値ではなく読み戻した値**を控える。量子化するパラメータだと
        // 書いた値と実際の値がずれ、毎cook「GUIが動いた」と誤検出してしまう
        e.lastAU = readParam(e);
    }

    // v2 のプラグイン GUI は AUEventListener で変更を受け取る。こちらが新 API で書いても
    // 通知は飛ばないので、明示的に知らせる（実測: これが無いと GUI のつまみが動かない）
    void notifyGUI(const ParamEntry& e)
    {
        if (!myAU2) return;
        AudioUnitEvent ev = {};
        ev.mEventType = kAudioUnitEvent_ParameterValueChange;
        ev.mArgument.mParameter.mAudioUnit   = myAU2;
        ev.mArgument.mParameter.mParameterID = e.pid;
        ev.mArgument.mParameter.mScope       = kAudioUnitScope_Global;
        ev.mArgument.mParameter.mElement     = 0;
        AUEventListenerNotify(nullptr, nullptr, &ev);
    }

    // **読むのは v2 側**。GUI の操作は v2 にしか反映されず、AUParameter.value は古いままになる(実測)
    float readParam(const ParamEntry& e) const
    {
        if (myAU2) {
            AudioUnitParameterValue v = 0;
            if (AudioUnitGetParameter(myAU2, e.pid, kAudioUnitScope_Global, 0, &v) == noErr) return v;
        }
        return e.p ? e.p.value : e.cur;
    }

    // 入力1のチャンネル名でパラメータを動かす。
    // 名前は Info DAT の channel 列 / `p<index>` / 割り当て済みの `learn<n>` が使える
    void applyParamsFromInput(const OP_Inputs* in)
    {
        const OP_CHOPInput* pi = in->getInputCHOP(1);
        if (!pi || pi->numSamples < 1) return;
        const char* rng = in->getParString("Inputrange");
        const bool norm = !rng || strcmp(rng, "Raw") != 0;
        for (int c = 0; c < pi->numChannels; c++) {
            const char* nm = pi->getChannelName(c);
            if (!nm) continue;
            auto it = myChanMap.find(nm);
            if (it == myChanMap.end()) continue;
            writeParam(myParams[it->second], pi->getChannelData(c)[pi->numSamples - 1], norm);
        }
    }

    // ------------------------------------------------------------ learn

    // Learn 中に GUI で触られたパラメータを空いている枠へ割り当てる。
    // 学習中はこちらから値を書かない(自分の書き込みを「触られた」と誤検出しないため)
    // AU 側(=GUI が書く方)と Learn 枠(=TD のパラメータ)を**毎cook 双方向で同期**する。
    //
    //  ・AU 側が動いていた → GUI かプリセットで動かされた。枠へ書き戻す
    //                        （Learn 中で未割り当てなら、その場で枠に割り当てる）
    //  ・枠が動いていた     → TD 側で動かされた。AU へ書いて GUI にも通知する
    //
    // Learn の On/Off は「未割り当てのものを拾うかどうか」だけの違いにしてある。
    // Learn 中でも枠は生きているし、Learn を切っても GUI 追従は続く
    void syncParams(const OP_Inputs* in)
    {
        if (myWantClearLearn.exchange(false)) {
            for (auto& e : myParams) e.learnSlot = -1;
            for (int i = 0; i < kLearnSlots; i++) myLearnIdx[i] = -1;
            rebuildLearnAliases(); saveLearnMap();
        }
        myLearning = in->getParInt("Learn") != 0;
        if (myWantPanel.exchange(false)) createPanel();

        // AU 側(GUI・プリセット・パネル)で動いたパラメータを検出する。
        // Learn 中で未割り当てなら、その場でパネルへ載せる対象にする。
        // **値そのものはここでは書かない。** 書き手はパネル(入力1)に一本化した
        for (size_t i = 0; i < myParams.size(); i++) {
            ParamEntry& e = myParams[i];
            const float now  = readParam(e);
            const float span = (e.maxV - e.minV) > 0 ? (e.maxV - e.minV) : 1.0f;
            if (std::isnan(e.lastAU)) { e.lastAU = now; continue; }
            if (fabsf(now - e.lastAU) <= span * 0.001f) continue;
            e.lastAU = now;
            if (myLearning && e.learnSlot <= 0) assignLearnSlot((int)i);
        }
    }

    // 隣に Script CHOP のパネルを生成して入力1へ配線する。
    // TD は実行中にこの op のパラメータを増やせないが、**Script CHOP なら
    // onSetupParameters で型付きパラメータを生やせる**(実測)。そこを使う
    void createPanel()
    {
        std::string py;
        py += "import td\n";
        py += "p = n.parent()\n";
        py += "base = n.name\n";
        py += "info = p.op(base + '_params') or p.create(td.infoDAT, base + '_params')\n";
        py += "info.par.op = n\n";
        py += "info.nodeX, info.nodeY = n.nodeX + 200, n.nodeY - 150\n";
        py += "cb = p.op(base + '_panel_callbacks') or p.create(td.textDAT, base + '_panel_callbacks')\n";
        py += "cb.text = __au_panel_src\n";
        py += "cb.nodeX, cb.nodeY = n.nodeX - 250, n.nodeY - 300\n";
        py += "sc = p.op(base + '_panel') or p.create(td.scriptCHOP, base + '_panel')\n";
        py += "sc.nodeX, sc.nodeY = n.nodeX - 250, n.nodeY - 150\n";
        py += "sc.par.callbacks = cb\n";
        py += "sc.store('params', info.path)\n";   // 参照は storage(setuppars で消えない)
        py += "info.cook(force=True)\n";           // 生成直後は未cookで中身が空
        py += "sc.par.setuppars.pulse()\n";        // 型付きパラメータを作る
        py += "n.inputConnectors[1].connect(sc)\n";
        py += "n.par.Inputrange = 'Raw'\n";   // パネルは実値を出すので Raw
        // スクリプト本体は Python 側の変数に入れてから使う(エスケープ地獄を避ける)
        PyGILState_STATE g = PyGILState_Ensure();
        if (PyObject* main = PyImport_AddModule("__main__")) {
            if (PyObject* dict = PyModule_GetDict(main)) {
                PyObject* v = PyUnicode_FromString(kPanelScript);
                if (v) { PyDict_SetItemString(dict, "__au_panel_src", v); Py_DECREF(v); }
            }
        }
        PyGILState_Release(g);
        if (!tdpycb::runWithNode(myNode, py)) myWarn = "could not create the panel";
    }

    void assignLearnSlot(int idx)
    {
        for (int i = 0; i < kLearnSlots; i++) {
            if (myLearnIdx[i] >= 0) continue;
            myLearnIdx[i] = idx;
            myParams[idx].learnSlot = i + 1;
            rebuildLearnAliases(); saveLearnMap();
            return;
        }
        myWarn = "all learn slots are used";
    }

    // 入力CHOP から `learn1` `learn2` … でも指せるようにする
    void rebuildLearnAliases()
    {
        for (int i = 0; i < kLearnSlots; i++) myChanMap.erase("learn" + std::to_string(i + 1));
        for (int i = 0; i < kLearnSlots; i++)
            if (myLearnIdx[i] >= 0) myChanMap["learn" + std::to_string(i + 1)] = myLearnIdx[i];
    }

    void saveLearnMap()
    {
        std::string v = myWantId + "|";
        for (int i = 0; i < kLearnSlots; i++) {
            if (i) v += ",";
            v += std::to_string(myLearnIdx[i]);
        }
        tdpycb::setStringPars(myNode, {{"Learnmap", v}});
    }

    void restoreLearnMap(const OP_Inputs* in)
    {
        for (int i = 0; i < kLearnSlots; i++) myLearnIdx[i] = -1;
        for (auto& e : myParams) e.learnSlot = -1;
        const char* raw = in->getParString("Learnmap");
        if (raw && *raw) {
            std::string s2 = raw;
            const size_t bar = s2.find('|');
            if (bar != std::string::npos && s2.substr(0, bar) == myWantId) {
                std::string body = s2.substr(bar + 1);
                int i = 0; size_t pos = 0;
                while (i < kLearnSlots && pos <= body.size()) {
                    const size_t c = body.find(',', pos);
                    const std::string tok = body.substr(pos, c == std::string::npos ? std::string::npos : c - pos);
                    const int idx = tok.empty() ? -1 : atoi(tok.c_str());
                    if (idx >= 0 && idx < (int)myParams.size()) {
                        myLearnIdx[i] = idx; myParams[idx].learnSlot = i + 1;
                    }
                    i++;
                    if (c == std::string::npos) break;
                    pos = c + 1;
                }
            }
        }
        rebuildLearnAliases();
    }

    // GUI で動かされたパラメータを知るためのオブザーバ。AU 側のスレッドから来るので
    // アドレスを1つ置くだけにして、割り当ては cook 側で行う
    void installObserver()
    {
        removeObserver();
        if (!myUnit) return;
        AUParameterTree* tree = myUnit.AUAudioUnit.parameterTree;
        if (!tree) return;
        std::atomic<uint64_t>* touched = &myTouchedAddr;
        myObserverTree = tree;
        myObserverToken = [tree tokenByAddingParameterObserver:^(AUParameterAddress address, AUValue) {
            touched->store(address + 1);          // 0 を「無し」に使うので +1
        }];
    }
    void removeObserver()
    {
        if (myObserverTree && myObserverToken) [myObserverTree removeParameterObserver:myObserverToken];
        myObserverTree = nil; myObserverToken = nullptr; myTouchedAddr = 0;
    }

    // ------------------------------------------------------------ plugin UI window

    void syncWindow(const OP_Inputs* in)
    {
        const bool top = in->getParInt("Alwaysontop") != 0;
        if (top != myAlwaysOnTop) {
            myAlwaysOnTop = top;
            NSWindow* w = myWindow;
            if (w) dispatch_async(dispatch_get_main_queue(), ^{
                w.level = top ? NSFloatingWindowLevel : NSNormalWindowLevel; });
        }
        const bool want = in->getParInt("Showui") != 0;
        if (want == myWindowOpen) return;
        myWindowOpen = want;
        if (want) openWindow(); else closeWindow();
    }

    // ウインドウとビューコントローラは**作り直さず使い回す**。
    // 閉じるたびに contentViewController を捨てると、同じプラグインで2回目に
    // requestViewController しても表示できなくなる（実測で再現）。
    // 使い回せば位置も保たれるし、ホストとして普通の作りになる。
    void openWindow()
    {
        if (NSWindow* w = myWindow) {          // 既にあるなら出すだけ
            const bool top = myAlwaysOnTop;
            dispatch_async(dispatch_get_main_queue(), ^{
                w.level = top ? NSFloatingWindowLevel : NSNormalWindowLevel;
                [w makeKeyAndOrderFront:nil]; });
            return;
        }
        AVAudioUnit* unit = myUnit;
        if (!unit) return;
        if (!unit.AUAudioUnit.providesUserInterface) { myWarn = "this plugin has no GUI"; return; }
        NSString* title = [NSString stringWithUTF8String:myWindowTitle.c_str()];
        std::atomic<bool>* closedFlag = &myWindowClosed;
        NSWindow* __strong * slot = &myWindow;
        const bool top = myAlwaysOnTop;
        dispatch_async(dispatch_get_main_queue(), ^{
            [unit.AUAudioUnit requestViewControllerWithCompletionHandler:^(AUViewControllerBase* vc) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!vc || *slot) return;
                    NSRect r = vc.view.frame;
                    if (r.size.width < 100 || r.size.height < 60) r = NSMakeRect(0, 0, 480, 320);
                    NSWindow* w = [[NSWindow alloc]
                        initWithContentRect:r
                                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                             NSWindowStyleMaskMiniaturizable)
                                    backing:NSBackingStoreBuffered defer:NO];
                    w.title = title;
                    w.releasedWhenClosed = NO;
                    w.level = top ? NSFloatingWindowLevel : NSNormalWindowLevel;
                    w.contentViewController = vc;
                    [w center];
                    [w makeKeyAndOrderFront:nil];
                    // 閉じるボタンは AppKit スレッドで押される。ここで TD に触ると
                    // THREAD CONFLICT になるのでフラグを立てるだけにして cook 側で処理する
                    TDAudioUnitWinDelegate* del = [[TDAudioUnitWinDelegate alloc] init];
                    del.flag = closedFlag;
                    w.delegate = del;
                    objc_setAssociatedObject(w, "tdaudel", del, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    *slot = w;
                });
            }];
        });
    }

    // 閉じるのは隠すだけ（VC は保持）。破棄はプラグインを差し替えるときだけ
    void closeWindow()
    {
        myWindowOpen = false;
        NSWindow* w = myWindow;
        if (!w) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [w orderOut:nil]; });
    }
    void destroyWindow()
    {
        NSWindow* w = myWindow; myWindow = nil; myWindowOpen = false;
        if (!w) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [w orderOut:nil]; w.contentViewController = nil; });
    }
    void closeWindowSync()
    {
        NSWindow* w = myWindow; myWindow = nil; myWindowOpen = false;
        if (!w) return;
        if ([NSThread isMainThread]) { [w orderOut:nil]; w.contentViewController = nil; }
        else dispatch_sync(dispatch_get_main_queue(), ^{ [w orderOut:nil]; w.contentViewController = nil; });
    }

    // C++ SDK には自分のパラメータを書く API が無いので、埋め込み Python で戻す
    void setShowUIPar(int v) { tdpycb::setFloatPars(myNode, {{"Showui", (double)v}}); }

    // AU の fullState を base64 にしてパラメータへ。.toe と一緒に保存される。
    // 先頭にプラグインIDを付けておき、別プラグインの状態を誤って流し込まないようにする
    void saveState()
    {
        if (!myUnit) return;
        NSDictionary* st = myUnit.AUAudioUnit.fullState;
        if (!st) return;
        NSError* e = nil;
        NSData* pl = [NSPropertyListSerialization dataWithPropertyList:st
                        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&e];
        if (!pl) { myWarn = "could not serialize plugin state"; return; }
        if (pl.length > 256 * 1024) { myWarn = "plugin state too large to store (>256KB)"; return; }
        std::string v = myWantId + "|" + std::string([pl base64EncodedStringWithOptions:0].UTF8String);
        tdpycb::setStringPars(myNode, {{"Statedata", v}});
        myStateSaves++;
    }

    void restoreState(const OP_Inputs* in)
    {
        if (!myUnit || in->getParInt("Loadstate") == 0) return;
        const char* raw = in->getParString("Statedata");
        if (!raw || !*raw) return;
        std::string s = raw;
        const size_t bar = s.find('|');
        if (bar == std::string::npos) return;
        if (s.substr(0, bar) != myWantId) return;   // 別プラグインの状態は流し込まない
        NSString* b64 = [NSString stringWithUTF8String:s.substr(bar + 1).c_str()];
        NSData* pl = b64 ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
        if (!pl) return;
        NSError* e = nil;
        id plist = [NSPropertyListSerialization propertyListWithData:pl options:0 format:NULL error:&e];
        if ([plist isKindOfClass:[NSDictionary class]]) {
            myUnit.AUAudioUnit.fullState = plist;
            for (auto& p : myParams) { p.lastAU = NAN; p.lastSlot = NAN; p.cur = p.p ? p.p.value : p.cur; }
        }
    }

    // ------------------------------------------------------------ state

    const OP_NodeInfo* myNode = nullptr;
    std::string myWindowTitle = "AudioUnit";

    std::vector<PluginEntry> myPlugins;
    std::vector<ParamEntry>  myParams;
    std::vector<std::string> myPresets;
    std::unordered_map<std::string, int> myChanMap;
    std::string myScratch[12];

    std::string myWantId, myWarn, myErr, myErrPending;
    std::atomic<bool> myLoaded{false}, myLoadFailed{false};
    std::atomic<uint64_t> myLoadToken{0};
    AVAudioUnit* myPendingUnit = nil;
    AVAudioUnit* myUnit = nil;
    AVAudioUnit* myEngineUnit = nil;

    AVAudioEngine*     myEngine = nil;
    AVAudioSourceNode* mySource = nil;
    AVAudioPCMBuffer*  myOutBuf = nil;
    double mySampleRate = 0;
    int    myMaxFrames = 0;

    std::vector<float> myInL, myInR;
    int myInPos = 0;

    int  myAppliedPreset = -2;
    bool myWantReset = false;
    std::atomic<bool> myWantSaveState{false};
    std::atomic<bool> myWantClearLearn{false};
    std::atomic<bool> myWantPanel{false};
    std::atomic<uint64_t> myTouchedAddr{0};
    bool myLearning = false;
    int  myLearnIdx[kLearnSlots] = { -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1 };
    std::unordered_map<uint64_t,int> myAddrToIndex;
    AudioUnit myAU2 = nullptr;
    AUParameterTree* myObserverTree = nil;
    AUParameterObserverToken myObserverToken = nullptr;
    std::atomic<int64_t> myStateSaves{0};
    bool myAlwaysOnTop = false;
    bool myBypassed = false;
    double myLatencySec = 0;

    NSWindow* myWindow = nil;
    bool myWindowOpen = false;
    std::atomic<bool> myWindowClosed{false};

    std::atomic<int64_t> myExec{0}, myRenders{0};
};

// ---------------------------------------------------------------- entry

extern "C" {

DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    info->setAPIVersion(CHOPCPlusPlusAPIVersion);   // apiVersion は private。直接代入は不可
    info->customOPInfo.opType->setString("Audiounit");
    info->customOPInfo.opLabel->setString("AudioUnit");
    info->customOPInfo.opIcon->setString("AUN");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.authorEmail->setString("");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 2;
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    if (info->customOPInfo.opHelpURL)
        info->customOPInfo.opHelpURL->setString(
            "https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/AudioUnit/README.md");
}

DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new AudioUnitCHOP(info);
}

DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (AudioUnitCHOP*)instance;
}

}
