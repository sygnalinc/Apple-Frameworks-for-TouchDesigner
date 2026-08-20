#pragma once
// AudioUnit Effect / AudioUnit Instrument の共通実装。
//
// **ObjC のクラス名はバンドルごとに変える。** 同名クラスを複数の .plugin が定義すると
// ObjC ランタイムは片方の実装だけを使い回し、owner の C++ キャスト先が食い違う
// (MapKit で踏んだ罠)。各 .mm が TDAU_DELEGATE を define してから include する。
#ifndef TDAU_DELEGATE
#error "define TDAU_DELEGATE before including AudioUnitCommon.h"
#endif

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
#include <mach/mach_time.h>
#include <algorithm>
#include <map>
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
@interface TDAU_DELEGATE : NSObject <NSWindowDelegate>
@property (assign, nonatomic) std::atomic<bool>* flag;
@end
@implementation TDAU_DELEGATE
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

constexpr int kLearnSlots = 128;   // パネルに載せられるパラメータの上限

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

// エフェクト(aufx)と楽器(aumu)の違いはここだけ。あとは全部共通
#include "MidiSeq.h"

struct AUKind {
    OSType componentType;   // kAudioUnitType_Effect / kAudioUnitType_MusicDevice
    bool   instrument;      // 音声入力を持たず、ノートで鳴らす
};

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
# **この op は AudioUnit CHOP を一切読まない。** パネルは AudioUnit CHOP の入力1に
# 繋がる(=上流)ので、こちらから AudioUnit CHOP の Info DAT を読むと
# 「Cook dependency loop」になる(実測で TD が警告を出す)。
#
# 代わりに:
#   ・パラメータの仕様は AudioUnit CHOP が storage("spec") に入れてくれる
#   ・プラグイン側で動いた値も AudioUnit CHOP がこちらのパラメータへ書き込む
#   ・こちらは自分のパラメータを 0〜1 のつまみ位置でチャンネルに出すだけ
#
# パラメータの単位は AudioUnit CHOP の **Input Range** に従う:
#   Normalized … Float は 0〜1 のつまみ位置(表示曲線を通して実値になる)
#   Raw        … Float はそのパラメータ自身の単位(Hz・ms・dB…)
# 切り替えると AudioUnit CHOP がパネルを作り直し、値も新しい単位に置き換える。
# 入力0に自動化(MIDI など)を繋ぐと、それが優先される(単位は同じ約束に従う)。

import json


_SPEC_CACHE = {}


def _spec(scriptOp):
    # **毎cook パースしない。** storage の文字列が変わったときだけ解析する
    # (毎フレーム json.loads すると Python だけで 2ms 超かかる・実測)
    # **自分自身に store しない。** 自分の cook 中に store すると dirty になり、
    # TouchDesigner が自己ループ(Cook dependency loop)を報告する(実測)
    raw = scriptOp.fetch("spec", "[]")
    key = scriptOp.path
    cache = _SPEC_CACHE.get(key)
    if cache is not None and cache[0] == raw:
        return cache[1]
    try:
        rows = json.loads(raw)
    except Exception:
        rows = []
    _SPEC_CACHE[key] = (raw, rows)
    return rows


def _pname(ch):
    s = "".join(c for c in ch if c.isalnum())
    return (s[:1].upper() + s[1:].lower()) if s else "P"


def onSetupParameters(scriptOp):
    page = scriptOp.appendCustomPage("Learned")
    for r in _spec(scriptOp):
        nm = _pname(r["ch"])
        t = r.get("t", "float")
        lo = float(r["lo"])
        hi = float(r["hi"])
        pos = float(r.get("pos", 0.0))
        raw = int(r.get("rw", 0))
        val = float(r.get("v", lo + pos * (hi - lo)))
        label = r.get("nm", r["ch"])
        if t == "toggle":
            p = page.appendToggle(nm, label=label)[0]
            p.default = 1 if pos >= 0.5 else 0
            p.val = p.default
        elif t == "menu":
            p = page.appendMenu(nm, label=label)[0]
            n = int(round(hi - lo)) + 1
            labels = r.get("vs") or []
            if len(labels) != n:
                labels = [str(int(lo) + i) for i in range(n)]
            p.menuNames = ["v%d" % (int(lo) + i) for i in range(n)]
            p.menuLabels = labels
            p.menuIndex = max(0, min(n - 1, int(round(pos * (n - 1)))))
        elif t == "int":
            p = page.appendInt(nm, label=label)[0]
            p.normMin, p.normMax = lo, hi
            p.min, p.max = lo, hi
            p.clampMin = p.clampMax = True
            p.default = int(round(lo + pos * (hi - lo)))
            p.val = p.default
        else:
            p = page.appendFloat(nm, label=label)[0]
            # Raw は実単位、Normalized は 0〜1 のつまみ位置
            p.normMin, p.normMax = (lo, hi) if raw else (0.0, 1.0)
            p.min, p.max = (lo, hi) if raw else (0.0, 1.0)
            p.clampMin = p.clampMax = True
            p.default = val if raw else pos
            p.val = p.default
    return


def _emit(par, r):
    # チャンネルへ出す値。Raw は実単位のまま、Normalized はつまみ位置
    lo = float(r["lo"]); hi = float(r["hi"])
    if int(r.get("rw", 0)):
        if par.style == "Menu":
            return float(int(lo) + par.menuIndex)
        if par.style == "Toggle":
            return 1.0 if par.eval() else 0.0
        return float(par.eval())
    return _pos_of(par, lo, hi)


def _take(par, v, r):
    # 入力0から来た値をパラメータへ
    lo = float(r["lo"]); hi = float(r["hi"])
    if int(r.get("rw", 0)):
        if par.style == "Menu":
            n = len(par.menuNames)
            par.menuIndex = max(0, min(n - 1, int(round(v - lo)))) if n > 1 else 0
        elif par.style == "Toggle":
            par.val = 1 if v >= 0.5 else 0
        elif par.style == "Int":
            par.val = int(round(max(lo, min(hi, v))))
        else:
            par.val = max(lo, min(hi, v))
        return
    _set_pos(par, v, lo, hi)


def _pos_of(par, lo, hi):
    # パラメータの表示 → つまみ位置(0〜1)。Float は既に 0〜1
    if par.style == "Menu":
        n = len(par.menuNames)
        return float(par.menuIndex) / (n - 1) if n > 1 else 0.0
    if par.style == "Toggle":
        return 1.0 if par.eval() else 0.0
    if par.style == "Int":
        return (float(par.eval()) - lo) / (hi - lo) if hi > lo else 0.0
    return float(par.eval())


def _set_pos(par, pos, lo, hi):
    if par.style == "Menu":
        n = len(par.menuNames)
        par.menuIndex = max(0, min(n - 1, int(round(pos * (n - 1))))) if n > 1 else 0
    elif par.style == "Toggle":
        par.val = 1 if pos >= 0.5 else 0
    elif par.style == "Int":
        par.val = int(round(lo + pos * (hi - lo)))
    else:
        par.val = pos


def onCook(scriptOp):
    scriptOp.clear()
    rows = _spec(scriptOp)
    built = set(x.name for x in scriptOp.customPars if x.page.name == "Learned")
    want = set(_pname(r["ch"]) for r in rows)
    if built != want:
        run("op(%r).par.setuppars.pulse()" % scriptOp.path, delayFrames=1)
        return
    src = scriptOp.inputs[0] if scriptOp.inputs else None
    for r in rows:
        nm = _pname(r["ch"])
        if nm not in built:
            continue
        par = scriptOp.par[nm]
        # 入力0に自動化が来ていれば、それを反映する
        if src is not None:
            ch = src.chan(r["ch"])
            if ch is not None:
                _take(par, float(ch[0]), r)
        scriptOp.appendChan(r["ch"])[0] = _emit(par, r)
    # **今どちらの単位で出しているかを添える。** AudioUnit CHOP は Input Range を
    # 切り替えた直後、この印が自分の設定と合うまで入力を適用しない
    # (作り直しが1フレーム遅れるので、その間に古い単位の値を書かないため)
    mode = int(rows[0].get("rw", 0)) if rows else 0
    scriptOp.appendChan("__range")[0] = float(mode)
    return
)AUPANEL";

// ---------------------------------------------------------------- plugin

class AudioUnitBase : public CHOP_CPlusPlusBase
{
public:
    AudioUnitBase(const OP_NodeInfo* info, const AUKind& kind) : myNode(info), myKind(kind)
    {
        for (int i = 0; i < kLearnSlots; i++) myLearnIdx[i] = -1;
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        myTimebase = (double)tb.numer / (double)tb.denom;
        rescan();
    }
    virtual ~AudioUnitBase() { closeWindowSync(); teardown(); }

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
        // **音を生成して出す CHOP はサンプルレートを明示しないと 60Hz 扱いになる**
        // (CoreAudio Tap で踏んだ罠)。エフェクトは入力に合わせるので TD 任せでよい
        if (myKind.instrument) info->sampleRate = 44100;
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

            // **パラメータ・GUI・Learn は音が流れていなくても動かす。**
            // 音声入力の有無で早期 return すると、入力1(パネル)を読まないので
            // パネルが cook されず、つまみを動かしても何も起きない(実測)
            if (myUnit) {
                applyPreset(in);
                // **入力を先に適用する。** 逆順だと、パネル(入力1)が毎cook 出す値が
                // Learn 枠の変更を上書きしてしまい、枠から動かせなくなる(実測)
                applyParamsFromInput(in);
                syncParams(in);
                if (!myKind.instrument) {     // 楽器に Bypass / Dry-Wet は無い
                    myBypassed = in->getParInt("Bypass") != 0;
                    myUnit.AUAudioUnit.shouldBypassEffect = myBypassed;
                }
                if (myWantSaveState.exchange(false)) saveState();
            }
            syncWindow(in);

            if (myKind.instrument) { renderInstrument(out, in, n, active); return; }

            const OP_CHOPInput* ci = in->getInputCHOP(0);
            if (!active || !ci || ci->numChannels < 1 || ci->numSamples < 1 || out->numChannels < 2) return;

            const double sr = ci->sampleRate > 0 ? ci->sampleRate : 44100.0;
            if (!myUnit) {                        // プラグイン未選択/ロード中は素通し
                passThrough(out, ci, n, in);
                return;
            }
            if (!ensureEngine(sr, n)) { passThrough(out, ci, n, in); return; }

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
        if (!myKind.instrument) {
            { OP_NumericParameter p("Bypass"); p.label = "Bypass"; p.page = P; p.defaultValues[0] = 0; m->appendToggle(p); }
            { OP_NumericParameter p("Drywet"); p.label = "Dry / Wet"; p.page = P; p.defaultValues[0] = 1;
              p.minSliders[0] = 0; p.maxSliders[0] = 1; p.minValues[0] = 0; p.maxValues[0] = 1;
              p.clampMins[0] = true; p.clampMaxes[0] = true; m->appendFloat(p); }
        }
        { OP_NumericParameter p("Gain"); p.label = "Output Gain"; p.page = P; p.defaultValues[0] = 1;
          p.minSliders[0] = 0; p.maxSliders[0] = 2; m->appendFloat(p); }
        {
            // MIDI コンは 0〜1 で来るので、既定は「そのパラメータの min〜max へ引き伸ばす」
            OP_StringParameter p("Inputrange"); p.label = "Input Range"; p.page = P;
            p.defaultValue = "Normalized";   // MIDI が素の 0〜1 で来るので既定はこちら
            const char* n[] = {"Normalized", "Raw"};
            const char* l[] = {"Normalized 0-1 -> parameter range", "Raw value"};
            m->appendMenu(p, 2, n, l);
        }
        { OP_NumericParameter p("Showui"); p.label = "Display GUI"; p.page = P; p.defaultValues[0] = 0; m->appendToggle(p); }
        { OP_NumericParameter p("Alwaysontop"); p.label = "Always On Top"; p.page = P; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Resetstate"); p.label = "Reset Plugin State"; p.page = P; m->appendPulse(p); }

        // Learn 関連は数が少ないので AudioUnit ページにまとめる
        const char* L = P;
        { OP_NumericParameter p("Learn"); p.label = "Learn Parameters"; p.page = L; p.defaultValues[0] = 0; m->appendToggle(p); }
        { OP_NumericParameter p("Clearlearned"); p.label = "Clear Learned"; p.page = L; m->appendPulse(p); }
        { OP_NumericParameter p("Createpanel"); p.label = "Create / Rebuild Panel"; p.page = L; m->appendPulse(p); }
        {
            OP_StringParameter p("Learnmap"); p.label = "Learned Mapping"; p.page = L;
            p.defaultValue = ""; m->appendString(p);
        }

        if (myKind.instrument) {
            // 手元にノート入力が無くても鳴らせるように、パラメータだけで打てるようにしておく
            const char* PL = "Play";
            { OP_NumericParameter p("Note"); p.label = "Note"; p.page = PL; p.defaultValues[0] = 60;
              p.minSliders[0] = 0; p.maxSliders[0] = 127; p.minValues[0] = 0; p.maxValues[0] = 127;
              p.clampMins[0] = true; p.clampMaxes[0] = true; m->appendInt(p); }
            { OP_NumericParameter p("Velocity"); p.label = "Velocity"; p.page = PL; p.defaultValues[0] = 0.8;
              p.minSliders[0] = 0; p.maxSliders[0] = 1; p.minValues[0] = 0; p.maxValues[0] = 1;
              p.clampMins[0] = true; p.clampMaxes[0] = true; m->appendFloat(p); }
            { OP_NumericParameter p("Midichannel"); p.label = "MIDI Channel"; p.page = PL; p.defaultValues[0] = 1;
              p.minSliders[0] = 1; p.maxSliders[0] = 16; p.minValues[0] = 1; p.maxValues[0] = 16;
              p.clampMins[0] = true; p.clampMaxes[0] = true; m->appendInt(p); }
            {
                // **AUMIDISynth は既定では音色が切り替わらない**(全プログラムで波形が完全に同一・実測)。
                // GM のサウンドバンクを読ませると切り替わるので、既定で macOS 同梱のものを指す
                OP_StringParameter p("Soundbank"); p.label = "Sound Bank"; p.page = PL;
                p.defaultValue = "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls";
                m->appendFile(p);
            }
            { OP_NumericParameter p("Noteon"); p.label = "Note On"; p.page = PL; m->appendPulse(p); }
            { OP_NumericParameter p("Noteoff"); p.label = "Note Off"; p.page = PL; m->appendPulse(p); }
            { OP_NumericParameter p("Allnotesoff"); p.label = "All Notes Off"; p.page = PL; m->appendPulse(p); }

            // ---- MIDI ファイル再生。Movie File In と同じ形の操作にそろえる ----
            const char* MF = "MIDI File";
            { OP_StringParameter p("Midifile"); p.label = "MIDI File"; p.page = MF; m->appendFile(p); }
            { OP_NumericParameter p("Play"); p.label = "Play"; p.page = MF; p.defaultValues[0] = 1; m->appendToggle(p); }
            {
                OP_StringParameter p("Playmode"); p.label = "Play Mode"; p.page = MF;
                const char* n[] = { "sequential", "locked", "index" };
                const char* l[] = { "Sequential", "Locked to Timeline", "Specify Index" };
                p.defaultValue = "sequential";
                m->appendMenu(p, 3, n, l);
            }
            { OP_NumericParameter p("Speed"); p.label = "Speed"; p.page = MF; p.defaultValues[0] = 1;
              p.minSliders[0] = -2; p.maxSliders[0] = 2; m->appendFloat(p); }
            { OP_NumericParameter p("Loop"); p.label = "Loop"; p.page = MF; p.defaultValues[0] = 1; m->appendToggle(p); }
            {
                // On にすると再生速度に (TD の BPM ÷ ファイルの BPM) を掛ける。
                // MIDI なので音程は変わらず、テンポだけが TD 側に追従する
                OP_NumericParameter p("Synctempo"); p.label = "Sync to TD Tempo"; p.page = MF;
                p.defaultValues[0] = 0; m->appendToggle(p);
            }
            { OP_NumericParameter p("Cue"); p.label = "Cue"; p.page = MF; p.defaultValues[0] = 0; m->appendToggle(p); }
            { OP_NumericParameter p("Cuepoint"); p.label = "Cue Point (s)"; p.page = MF; p.defaultValues[0] = 0;
              p.minSliders[0] = 0; p.maxSliders[0] = 60; m->appendFloat(p); }
            { OP_NumericParameter p("Cuepulse"); p.label = "Cue Pulse"; p.page = MF; m->appendPulse(p); }
            { OP_NumericParameter p("Position"); p.label = "Position"; p.page = MF; p.defaultValues[0] = 0;
              p.minSliders[0] = 0; p.maxSliders[0] = 1; p.minValues[0] = 0; p.maxValues[0] = 1;
              p.clampMins[0] = true; p.clampMaxes[0] = true; m->appendFloat(p); }
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
        else if (!strcmp(name, "Noteon"))  myWantNoteOn = true;
        else if (!strcmp(name, "Noteoff")) myWantNoteOff = true;
        else if (!strcmp(name, "Allnotesoff")) myWantAllOff = true;
        else if (!strcmp(name, "Cuepulse")) myWantCue = true;
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

    int32_t getNumInfoCHOPChans(void*) override { return myKind.instrument ? 15 : 8; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        static const char* n[] = { "executes", "renders", "samplerate", "loaded",
                                   "params", "latency_ms", "bypassed", "learned",
                                   "notes_sent", "notes_held", "programs_sent",
                                   "file_position", "file_duration", "bank_status", "file_bpm" };
        int held = 0;
        for (const auto& kv : myHeld) if (kv.first < 0x10000 && kv.second > 0) held++;
        const float v[] = { (float)myExec.load(), (float)myRenders.load(), (float)mySampleRate,
                            (float)(myUnit != nil), (float)myParams.size(),
                            (float)(myLatencySec * 1000.0), (float)myBypassed, (float)learnedCount(),
                            (float)myNotesSent, (float)held, (float)myProgsSent,
                            (float)mySeqPos, (float)mySeq.duration, (float)myBankStatus,
                            (float)mySeq.bpm };
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
            d.componentType = myKind.componentType;
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
        myBankPath.clear();          // 楽器が変わったらサウンドバンクを入れ直す
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

        // **v2 側のIDは `AUParameter.address` そのもの**(6プラグインで100%一致・実測)。
        // 以前 kAudioUnitProperty_ParameterList を添え字で突き合わせていたが、
        // **v2 と v3 では並び順が違う**(AUDistortion は16個中11個ずれ・AUMatrixReverb は
        // 17個中11個)。そのせいで書く先と読む先が食い違い、値が動かなくなっていた
        myAU2 = myUnit.audioUnit;
        if (myAU2) {
            for (auto& e : myParams) {
                e.pid = (AudioUnitParameterID)e.address;
                AudioUnitParameterInfo pinfo; UInt32 isz = sizeof(pinfo);
                if (AudioUnitGetProperty(myAU2, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global,
                                         e.pid, &pinfo, &isz) != noErr) continue;
                e.curve = pinfo.flags;
                // AU はパラメータの単位で型を伝えてくる。実測(エフェクト24個・231個)では
                // Boolean 18 / Indexed 24(うち19個は選択肢名あり)/ それ以外 189
                if (pinfo.unit == kAudioUnitParameterUnit_Boolean) e.type = "toggle";
                else if (pinfo.unit == kAudioUnitParameterUnit_Indexed) {
                    NSArray<NSString*>* vs = e.p ? e.p.valueStrings : nil;
                    if (vs.count) {
                        e.type = "menu";
                        e.values = [[vs componentsJoinedByString:@"|"] UTF8String] ?: "";
                    } else e.type = "int";
                }
            }
        }
        installObserver();
    }

    // ------------------------------------------------------------ engine

    // ------------------------------------------------------ 楽器(aumu)
    AVAudioUnitMIDIInstrument* midiUnit() const
    {
        return [myUnit isKindOfClass:[AVAudioUnitMIDIInstrument class]]
                   ? (AVAudioUnitMIDIInstrument*)myUnit : nil;
    }

    static int velByte(float v)
    {
        // 0〜1 で来ることも、生の MIDI 値(1〜127)で来ることもある
        const float f = v <= 1.0f ? v * 127.0f : v;
        const int b = (int)lroundf(f);
        return b < 1 ? 1 : (b > 127 ? 127 : b);
    }

    // `ch<ch>p` = プログラムチェンジ(音色切替)。TouchDesigner の MIDI In CHOP は
    // GM の慣習どおり **1始まり**で出す(生の 68 = Oboe が 69)ので、送るときに1引く
    static bool parseProgram(const char* nm, int& ch, bool& oneBased)
    {
        if (!nm || nm[0] != 'c' || nm[1] != 'h') return false;
        const char* q = nm + 2;
        int v = 0;
        while (*q >= '0' && *q <= '9') { v = v * 10 + (*q - '0'); q++; }
        if (q == nm + 2) return false;
        // `ch1p`    = TouchDesigner の MIDI In CHOP。GM の慣習で **1始まり**
        // `ch1prog` = CoreMIDI In CHOP(このリポジトリ)。**生の MIDI 値**
        if (!strcmp(q, "p")) oneBased = true;
        else if (!strcmp(q, "prog")) oneBased = false;
        else return false;
        ch = v;
        return ch >= 1 && ch <= 16;
    }

    // 入力0のチャンネル名からノートを拾う。CoreMIDI In CHOP の `ch1n60` と
    // 素の `note60` の両方を受ける(値=ベロシティ、0でノートオフ)
    static bool parseNote(const char* nm, int& ch, int& note)
    {
        if (!nm) return false;
        if (nm[0] == 'c' && nm[1] == 'h') {
            const char* n = strchr(nm + 2, 'n');
            if (!n) return false;
            ch = atoi(nm + 2); note = atoi(n + 1);
        } else if (!strncmp(nm, "note", 4)) {
            ch = 1; note = atoi(nm + 4);
        } else return false;
        return ch >= 1 && ch <= 16 && note >= 0 && note <= 127;
    }

    void allNotesOff()
    {
        AVAudioUnitMIDIInstrument* mi = midiUnit();
        if (mi) for (const auto& kv : myHeld)
            if (kv.first < 0x10000 && kv.second > 0)
                [mi stopNote:(uint8_t)(kv.first & 0xff) onChannel:(uint8_t)(kv.first >> 8)];
        myHeld.clear();
    }

    // サウンドバンクを読ませる。受け付けない楽器(サードパーティ等)ではエラーが返るだけなので無視する
    void applySoundBank(const OP_Inputs* in)
    {
        const char* sb = in->getParString("Soundbank");
        const std::string want = sb ? sb : "";
        if (want == myBankPath || !myUnit) return;
        myBankPath = want;
        if (want.empty()) return;
        NSString* path = [NSString stringWithUTF8String:want.c_str()];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            myWarn = "sound bank not found: " + want;
            return;
        }
        NSURL* url = [NSURL fileURLWithPath:path];
        const OSStatus st = AudioUnitSetProperty(myUnit.audioUnit, kMusicDeviceProperty_SoundBankURL,
                                                 kAudioUnitScope_Global, 0, &url, sizeof(url));
        myBankStatus = (int)st;
        if (st != noErr) myWarn = "this plugin did not accept the sound bank (" + std::to_string((int)st) + ")";
    }

    // ---------------------------------------------- MIDI ファイル再生
    // Movie File In と同じ考え方。位置は秒。Sequential は実時計で進めるので
    // タイムラインを止めても鳴り続ける(タイムラインに合わせたいときは Locked)
    void playFile(const OP_Inputs* in, AVAudioUnitMIDIInstrument* mi)
    {
        const char* fp = in->getParString("Midifile");
        const std::string want = fp ? fp : "";
        if (want != mySeq.path) {
            allNotesOff();
            mySeq.load(want);
            mySeqPos = 0; mySeqPrev = -1;
            if (!want.empty() && !mySeq.err.empty()) myWarn = mySeq.err;
        }
        if (mySeq.ev.empty() || mySeq.duration <= 0) return;

        const double dur = mySeq.duration;
        const char* pm = in->getParString("Playmode");
        const bool locked = pm && !strcmp(pm, "locked");
        const bool index  = pm && !strcmp(pm, "index");
        const bool play   = in->getParInt("Play") != 0;
        const bool loop   = in->getParInt("Loop") != 0;
        const double cuePt = in->getParDouble("Cuepoint");
        double speed = in->getParDouble("Speed");
        if (in->getParInt("Synctempo") != 0 && mySeq.bpm > 0) speed *= tdTempo() / mySeq.bpm;

        double pos = mySeqPos;
        bool seek = false;
        if (myWantCue.exchange(false)) { pos = cuePt; seek = true; }
        else if (in->getParInt("Cue") != 0) { pos = cuePt; seek = (fabs(pos - mySeqPos) > 1e-6); }
        else if (index) {
            pos = in->getParDouble("Position") * dur;
            seek = (fabs(pos - mySeqPos) > 0.05);
        } else if (locked) {
            const OP_TimeInfo* ti = in->getTimeInfo();
            const double t = ti && ti->rate > 0 ? (double)ti->frame / ti->rate : 0;
            pos = t * speed + cuePt;
            seek = (fabs(pos - mySeqPos) > 0.25);
        } else if (play) {
            const uint64_t now = mach_absolute_time();
            if (mySeqClock == 0) mySeqClock = now;
            const double dt = (double)(now - mySeqClock) * myTimebase / 1e9;
            mySeqClock = now;
            pos = mySeqPos + dt * speed;
        }
        if (!play && !index && !locked) {
            // 止めたらその場で保持する。**ただしキューは停止中でも効かせる** —
            // ここで return してしまうと Cue Pulse を消費だけして捨てることになる(実測で踏んだ)
            mySeqClock = 0;
            if (seek) { allNotesOff(); mySeqPos = pos; mySeqPrev = pos; }
            return;
        }

        if (pos > dur || pos < 0) {                    // 端に来た
            if (loop) { pos = pos - floor(pos / dur) * dur; seek = true; }
            else { pos = pos < 0 ? 0 : dur; if (mySeqPos != pos) { allNotesOff(); } }
        }
        if (seek) { allNotesOff(); mySeqPrev = pos - 1e-9; }

        // 前回位置から今の位置までのイベントを出す(逆再生時は送らない)
        const double a = mySeqPrev < 0 ? -1e-9 : mySeqPrev, b = pos;
        if (b > a) {
            for (const MidiEvent& e : mySeq.ev) {
                if (e.t <= a) continue;
                if (e.t > b) break;
                sendEvent(mi, e);
            }
        }
        mySeqPrev = b; mySeqPos = b;
    }

    // **OP_TimeInfo にテンポは無い**(frame / rate / deltaMS のみ)ので Python から読む。
    // テンポはめったに変わらないので 30 cook キャッシュする(毎cook 読むと重い)
    double tdTempo()
    {
        if (myTempoAge > 0 && --myTempoAge > 0 && myTdTempo > 0) return myTdTempo;
        myTempoAge = 30;
        PyGILState_STATE g = PyGILState_Ensure();
        if (PyObject* main = PyImport_AddModule("__main__")) {
            PyObject* dict = PyModule_GetDict(main);
            PyObject* r = PyRun_String("import td as __au_td\n__au_tempo = float(__au_td.root.time.tempo)\n",
                                       Py_file_input, dict, dict);
            if (r) Py_DECREF(r); else PyErr_Clear();
            if (PyObject* t = PyDict_GetItemString(dict, "__au_tempo")) {
                const double d = PyFloat_AsDouble(t);
                if (d > 0) myTdTempo = d;
            }
        }
        PyGILState_Release(g);
        return myTdTempo;
    }

    void sendEvent(AVAudioUnitMIDIInstrument* mi, const MidiEvent& e)
    {
        const uint8_t hi = e.s & 0xf0, ch = e.s & 0x0f;
        if (hi == 0x90 && e.d2 > 0) { [mi startNote:e.d1 withVelocity:e.d2 onChannel:ch]; myNotesSent++; myHeld[(ch<<8)|e.d1] = 1.f; }
        else if (hi == 0x80 || hi == 0x90) { [mi stopNote:e.d1 onChannel:ch]; myHeld[(ch<<8)|e.d1] = 0.f; }
        else if (hi == 0xc0) { [mi sendMIDIEvent:e.s data1:e.d1]; myProgsSent++; }
        else { [mi sendMIDIEvent:e.s data1:e.d1 data2:e.d2]; }
    }

    void applyNotes(const OP_Inputs* in)
    {
        AVAudioUnitMIDIInstrument* mi = midiUnit();
        if (!mi) { myWarn = "this plugin is not a MIDI instrument"; return; }
        applySoundBank(in);
        playFile(in, mi);

        if (myWantAllOff.exchange(false)) allNotesOff();

        const int pnote = in->getParInt("Note");
        const int pch   = in->getParInt("Midichannel") - 1;
        if (myWantNoteOn.exchange(false))
        {
            [mi startNote:(uint8_t)pnote withVelocity:(uint8_t)velByte((float)in->getParDouble("Velocity"))
                onChannel:(uint8_t)pch];
            myNotesSent++;
            myHeld[(pch << 8) | pnote] = 1.f;
        }
        if (myWantNoteOff.exchange(false)) [mi stopNote:(uint8_t)pnote onChannel:(uint8_t)pch];

        const OP_CHOPInput* ni = in->getInputCHOP(0);
        if (!ni || ni->numSamples < 1) return;

        // **音色はノートより先に送る。** 同じ cook で音色とノートが来たとき、
        // 順序が逆だと最初の1音が前の音色で鳴る
        for (int c = 0; c < ni->numChannels; c++) {
            int ch = 0; bool oneBased = true;
            if (!parseProgram(ni->getChannelName(c), ch, oneBased)) continue;
            const int prog = (int)lroundf(ni->getChannelData(c)[ni->numSamples - 1]) - (oneBased ? 1 : 0);
            if (prog < 0 || prog > 127) continue;
            const int key = 0x10000 | (ch - 1);
            if (myHeld.count(key) && (int)myHeld[key] == prog) continue;
            myHeld[key] = (float)prog;
            [mi sendMIDIEvent:(uint8_t)(0xC0 | (ch - 1)) data1:(uint8_t)prog];
            myProgsSent++;
        }

        for (int c = 0; c < ni->numChannels; c++) {
            int ch = 0, note = 0;
            if (!parseNote(ni->getChannelName(c), ch, note)) continue;
            const float v = ni->getChannelData(c)[ni->numSamples - 1];
            const int key = ((ch - 1) << 8) | note;
            const float prev = myHeld.count(key) ? myHeld[key] : 0.f;
            if (v > 0.0001f && prev <= 0.0001f)
                { [mi startNote:(uint8_t)note withVelocity:(uint8_t)velByte(v) onChannel:(uint8_t)(ch - 1)];
                  myNotesSent++; }
            else if (v <= 0.0001f && prev > 0.0001f)
                [mi stopNote:(uint8_t)note onChannel:(uint8_t)(ch - 1)];
            myHeld[key] = v;
        }
    }

    void renderInstrument(CHOP_Output* out, const OP_Inputs* in, int n, bool active)
    {
        if (out->numChannels < 2 || !myUnit) return;
        if (!active) { allNotesOff(); return; }
        const double sr = out->sampleRate > 0 ? out->sampleRate : 44100.0;
        if (!ensureEngine(sr, n)) return;
        applyNotes(in);

        NSError* err = nil;
        AVAudioEngineManualRenderingStatus st =
            [myEngine renderOffline:(AVAudioFrameCount)n toBuffer:myOutBuf error:&err];
        if (st != AVAudioEngineManualRenderingStatusSuccess) { myWarn = "render failed"; return; }

        const int copy = n < (int)myOutBuf.frameLength ? n : (int)myOutBuf.frameLength;
        const float* L = myOutBuf.floatChannelData[0];
        const float* R = myOutBuf.floatChannelData[1];
        const float gain = (float)in->getParDouble("Gain");
        for (int i = 0; i < copy; i++) {
            out->channels[0][i] = L[i] * gain;
            out->channels[1][i] = R[i] * gain;
        }
        myRenders++;
    }

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
        if (myKind.instrument) {
            // 楽器は自分が音源。source node を挟まずミキサーへ直結する
            [myEngine attachNode:myUnit];
            [myEngine connect:myUnit to:myEngine.mainMixerNode format:fmt];
            NSError* e2 = nil;
            if (![myEngine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                                              format:fmt maximumFrameCount:(AVAudioFrameCount)cap error:&e2] ||
                ![myEngine startAndReturnError:&e2]) {
                myErr = e2.localizedDescription.UTF8String ?: "engine start failed";
                teardownEngine(); return false;
            }
            myOutBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:myEngine.manualRenderingFormat
                                                     frameCapacity:(AVAudioFrameCount)cap];
            myEngineUnit = myUnit; myErr.clear();
            return true;
        }
        AudioUnitBase* self_ = this;
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
        // パネルは今どちらの単位で出しているかを `__range` で申告する。
        // Input Range を切り替えた直後はパネルの作り直しが1フレーム遅れるので、
        // 印が合うまで適用しない(古い単位の値をそのまま書かないため)
        for (int c = 0; c < pi->numChannels; c++) {
            const char* mn = pi->getChannelName(c);
            if (mn && strcmp(mn, "__range") == 0) {
                const bool panelRaw = pi->getChannelData(c)[pi->numSamples - 1] >= 0.5f;
                if (panelRaw == norm) return;
            }
        }
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
            myPanelDirty = true;
        }
        const char* rngp = in->getParString("Inputrange");
        const bool raw = rngp && strcmp(rngp, "Raw") == 0;
        if (raw != myRawMode) { myRawMode = raw; myPanelDirty = true; }  // 単位が変わったら作り直す

        const bool learn = in->getParInt("Learn") != 0;
        // Learn を On にした瞬間、パネルが無ければ作る(触ったつまみをすぐ見られるように)
        if (learn && !myLearning && myUnit) createPanel(true);
        myLearning = learn;
        if (myWantPanel.exchange(false)) createPanel(false);
        if (myFirstSync) { myFirstSync = false; if (myUnit) myPanelDirty = true; }

        std::vector<std::pair<std::string, double>> push;
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
            if (e.learnSlot > 0)
                push.push_back({panelParName(e.chan),
                                myRawMode ? now : valueToCurve(e.curve, now, e.minV, e.maxV)});
        }
        pushToPanel(push);
        if (myPanelDirty) { myPanelDirty = false; refreshPanelSpec(); }
    }

    // learn の内容が変わったら、パネルへ新しい仕様を渡して作り直させる。
    // これをしないと Learnmap には入るのにパネルには出てこない
    void refreshPanelSpec()
    {
        const std::string spec = learnedSpecJSON();
        PyGILState_STATE g = PyGILState_Ensure();
        if (PyObject* main = PyImport_AddModule("__main__")) {
            if (PyObject* dict = PyModule_GetDict(main)) {
                PyObject* sp = PyUnicode_FromString(spec.c_str());
                if (sp) { PyDict_SetItemString(dict, "__au_spec", sp); Py_DECREF(sp); }
                const std::string sig = learnedSigString();
                PyObject* sg = PyUnicode_FromString(sig.c_str());
                if (sg) { PyDict_SetItemString(dict, "__au_sig", sg); Py_DECREF(sg); }
            }
        }
        PyGILState_Release(g);
        // storage への書き込みは cook 依存にならないので即時でよい。
        // **パラメータの作り直し(setuppars)だけは cook スタックの外へ回す** —
        // execute の時点でパネル(入力1)は cook 中で、そこで dirty にすると
        // TouchDesigner が Cook dependency loop を報告する(実測)
        std::string py = "sc = n.parent().op(n.name + '_params')\n";
        py += "if sc:\n";
        py += " sc.store('spec', __au_spec)\n";
        py += " if sc.fetch('sig', '') != __au_sig:\n";
        py += "  sc.store('sig', __au_sig)\n";
        py += "  import td\n";
        py += "  td.run('op(' + repr(sc.path) + ').par.setuppars.pulse()', delayFrames=1)\n";
        tdpycb::runWithNode(myNode, py);
    }

    // 隣に Script CHOP のパネルを生成して入力1へ配線する。
    // TD は実行中にこの op のパラメータを増やせないが、**Script CHOP なら
    // onSetupParameters で型付きパラメータを生やせる**(実測)。そこを使う
    void createPanel(bool onlyIfMissing)
    {
        std::string py;
        py += "import td\n";
        py += "p = n.parent()\n";
        py += "base = n.name\n";
        py += std::string("__au_only = ") + (onlyIfMissing ? "True" : "False") + "\n";
        py += "if not (__au_only and p.op(base + '_params')):\n";
        py += " info = p.op(base + '_info') or p.create(td.infoDAT, base + '_info')\n";
        py += " info.par.op = n\n";
        // **Script CHOP を先に作る。** Script CHOP は生成時に自前の callbacks DAT を
        // 作るので、先にこちらで同名の DAT を用意すると `..._callbacks1` が余分にできる(実測)。
        // TD が作ったものをそのまま使い回す
        py += " sc = p.op(base + '_params') or p.create(td.scriptCHOP, base + '_params')\n";
        py += " cb = sc.par.callbacks.eval() if hasattr(sc.par, 'callbacks') else None\n";
        py += " if cb is None: cb = p.op(base + '_params_callbacks') or p.create(td.textDAT, base + '_params_callbacks')\n";
        py += " cb.text = __au_panel_src\n";
        py += " sc.nodeX, sc.nodeY = n.nodeX, n.nodeY - 160\n";   // AudioUnit CHOP の真下
        py += " sc.viewer = True\n";                        // 値がすぐ見えるように開いておく
        // 選択したときに Learned ページが出るようにする。pageindex は
        // 「組み込みページの数 + カスタムページの位置」(pages は組み込みのみ・実測)
        py += " __au_pg = [q.name for q in sc.customPages]\n";
        py += " if 'Learned' in __au_pg: sc.par.pageindex = len(sc.pages) + __au_pg.index('Learned')\n";
        py += " sc.par.callbacks = cb\n";
        py += " sc.store('spec', __au_spec)\n";     // パネルはこれだけを見る(op を読まない)
        py += " sc.par.setuppars.pulse()\n";        // 型付きパラメータを作る
        py += " n.inputConnectors[1].connect(sc)\n";
        // 2つの DAT は既定で**閉じたドックチップ**にしてネットワークを散らかさない。
        // 開閉の実体は showDocked(expose=False は「×」チップになるので使わない)。
        // ドック後は nodeX/Y が無効になるので位置は設定しない
        py += " cb.dock = sc\n";
        py += " cb.expose = True\n";
        py += " cb.viewer = True\n";
        py += " cb.showDocked = False\n";
        py += " info.dock = n\n";
        py += " info.expose = True\n";
        py += " info.viewer = True\n";
        py += " info.showDocked = False\n";
        // スクリプト本体は Python 側の変数に入れてから使う(エスケープ地獄を避ける)
        PyGILState_STATE g = PyGILState_Ensure();
        if (PyObject* main = PyImport_AddModule("__main__")) {
            if (PyObject* dict = PyModule_GetDict(main)) {
                PyObject* v = PyUnicode_FromString(kPanelScript);
                if (v) { PyDict_SetItemString(dict, "__au_panel_src", v); Py_DECREF(v); }
                const std::string spec = learnedSpecJSON();
                PyObject* sp = PyUnicode_FromString(spec.c_str());
                if (sp) { PyDict_SetItemString(dict, "__au_spec", sp); Py_DECREF(sp); }
            }
        }
        PyGILState_Release(g);
        if (!tdpycb::runWithNode(myNode, py)) myWarn = "could not create the panel";
    }

    static std::string jesc(const std::string& v)
    {
        std::string r;
        for (char c : v) { if (c == '"' || c == '\\') r += '\\'; r += c; }
        return r;
    }

    // learn 済みパラメータの仕様を JSON に。パネルはこれだけを見て UI を作る
    // (AudioUnit CHOP を読まないので Cook dependency loop にならない)
    // 「どのパラメータが載っているか」だけの署名(値は含めない)。
    // パネルを作り直すべきかの判定に使う
    std::string learnedSigString()
    {
        std::string sig;
        for (int i = 0; i < kLearnSlots; i++) {
            const int idx = myLearnIdx[i];
            if (idx < 0 || idx >= (int)myParams.size()) continue;
            const ParamEntry& e = myParams[idx];
            sig += e.chan; sig += ":"; sig += e.type; sig += ",";
        }
        sig += myRawMode ? "|raw" : "|norm";
        return sig;
    }

    std::string learnedSpecJSON()
    {
        std::string j = "[";
        bool first = true;
        for (int i = 0; i < kLearnSlots; i++) {
            const int idx = myLearnIdx[i];
            if (idx < 0 || idx >= (int)myParams.size()) continue;
            const ParamEntry& e = myParams[idx];
            if (!first) j += ",";
            first = false;
            char b[256];
            const float cur = readParam(e);
            snprintf(b, sizeof b,
                     "{\"ch\":\"%s\",\"nm\":\"%s\",\"t\":\"%s\",\"lo\":%g,\"hi\":%g,"
                     "\"pos\":%g,\"v\":%g,\"rw\":%d",
                     jesc(e.chan).c_str(), jesc(e.name).c_str(), e.type.c_str(),
                     e.minV, e.maxV, valueToCurve(e.curve, cur, e.minV, e.maxV),
                     cur, myRawMode ? 1 : 0);
            j += b;
            if (e.type == "menu" && !e.values.empty()) {
                j += ",\"vs\":[";
                std::string tok; bool f2 = true;
                std::string src = e.values + "|";
                for (char c : src) {
                    if (c == '|') { if (!f2) j += ","; f2 = false; j += "\"" + jesc(tok) + "\""; tok.clear(); }
                    else tok += c;
                }
                j += "]";
            }
            j += "}";
        }
        return j + "]";
    }

    // プラグイン側で動いた値をパネルのパラメータへ押し込む。
    // パネルからこちらを読ませるとループになるので、**押す向き**にしてある
    // **パネルのパラメータは execute の中で直接書かない。**
    // このとき入力1のパネルは cook スタックにいるので、書くと dirty になり
    // TouchDesigner が Cook dependency loop を報告する(実測)。1フレーム遅らせる
    void pushToPanel(const std::vector<std::pair<std::string, double>>& vals)
    {
        if (vals.empty()) return;
        std::string body;
        for (const auto& kv : vals) {
            char line[160];
            snprintf(line, sizeof line, "sc.par.%s = %.6f\n", kv.first.c_str(), kv.second);
            body += line;
        }
        std::string py = "sc = n.parent().op(n.name + '_params')\nif sc:\n";
        py += " import td\n";
        py += " td.run('sc = op(' + repr(sc.path) + ')\\n' + \'\'\'" + body + "\'\'\', delayFrames=1)\n";
        tdpycb::runWithNode(myNode, py);
    }

    // 表示用のパラメータ名(パネル側の _pname と同じ規則)
    static std::string panelParName(const std::string& ch)
    {
        std::string r;
        for (char c : ch) if (isalnum((unsigned char)c)) r += c;
        if (r.empty()) return "P";
        r[0] = (char)toupper((unsigned char)r[0]);
        for (size_t i = 1; i < r.size(); i++) r[i] = (char)tolower((unsigned char)r[i]);
        return r;
    }

    void assignLearnSlot(int idx)
    {
        for (int i = 0; i < kLearnSlots; i++) {
            if (myLearnIdx[i] >= 0) continue;
            myLearnIdx[i] = idx;
            myParams[idx].learnSlot = i + 1;
            rebuildLearnAliases(); saveLearnMap();
            myPanelDirty = true;      // learn した瞬間にパネルへ反映する
            return;
        }
        myWarn = "learn slots are full (" + std::to_string(kLearnSlots) +
                 ") - use Clear Learned to start over";
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
        // プラグインを切り替えるとここで別の割り当てが復元される。
        // パネルにも渡し直さないと、前のプラグインのつまみが残ったままになる(実測)
        myPanelDirty = true;
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
                    TDAU_DELEGATE* del = [[TDAU_DELEGATE alloc] init];
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
    std::atomic<bool> myWantNoteOn{false};
    std::atomic<bool> myWantNoteOff{false};
    std::atomic<bool> myWantAllOff{false};
    std::atomic<bool> myWantCue{false};
    std::string myBankPath;
    int myBankStatus = -12345;
    double myTdTempo = 120; int myTempoAge = 0;
    MidiSeq  mySeq;
    double   mySeqPos = 0, mySeqPrev = -1;
    uint64_t mySeqClock = 0;
    double   myTimebase = 1.0;
    int myNotesSent = 0;
    int myProgsSent = 0;
    std::map<int, float> myHeld;      // (ch<<8 | note) -> 直前のベロシティ
    bool myPanelDirty = false;
    bool myFirstSync = true;
    bool myRawMode = false;
    const AUKind myKind;
    std::atomic<uint64_t> myTouchedAddr{0};
    bool myLearning = false;
    int  myLearnIdx[kLearnSlots];
    std::unordered_map<uint64_t,int> myAddrToIndex;
    AudioUnit myAU2 = nullptr;
    AUParameterTree* myObserverTree = nil;
    AUParameterObserverToken myObserverToken = nullptr;
    std::atomic<int64_t> myStateSaves{0};
    bool myAlwaysOnTop = true;
    bool myBypassed = false;
    double myLatencySec = 0;

    NSWindow* myWindow = nil;
    bool myWindowOpen = false;
    std::atomic<bool> myWindowClosed{false};

    std::atomic<int64_t> myExec{0}, myRenders{0};
};
