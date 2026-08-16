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
    float lastWritten = NAN;   // 自分が書いた値。GUI/プリセットと喧嘩しないための記録
};

} // namespace

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
            if (myLoaded.exchange(false)) { adoptLoadedUnit(); restoreState(in); }
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
            applyParamsFromInput(in);
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
        { OP_NumericParameter p("Showui"); p.label = "Display GUI"; p.page = P; p.defaultValues[0] = 0; m->appendToggle(p); }
        { OP_NumericParameter p("Alwaysontop"); p.label = "Always On Top"; p.page = P; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Resetstate"); p.label = "Reset Plugin State"; p.page = P; m->appendPulse(p); }

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

    int32_t getNumInfoCHOPChans(void*) override { return 7; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        static const char* n[] = { "executes", "renders", "samplerate", "loaded",
                                   "params", "latency_ms", "bypassed" };
        const float v[] = { (float)myExec.load(), (float)myRenders.load(), (float)mySampleRate,
                            (float)(myUnit != nil), (float)myParams.size(),
                            (float)(myLatencySec * 1000.0), (float)myBypassed };
        c->name->setString(n[i]); c->value = v[i];
    }

    bool getInfoDATSize(OP_InfoDATSize* s, void*) override
    {
        s->rows = 1 + (int)myParams.size();
        s->cols = 7;
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
            set(3, "min"); set(4, "max"); set(5, "value"); set(6, "unit");
            return;
        }
        const ParamEntry& p = myParams[row - 1];
        char b[64];
        set(0, std::to_string(row - 1));
        set(1, p.chan);
        set(2, p.name);
        snprintf(b, sizeof(b), "%g", p.minV); set(3, b);
        snprintf(b, sizeof(b), "%g", p.maxV); set(4, b);
        snprintf(b, sizeof(b), "%g", p.p ? p.p.value : p.cur); set(5, b);
        set(6, p.unit);
    }

    void getWarningString(OP_String* s, void*) override { if (!myWarn.empty()) s->setString(myWarn.c_str()); }
    void getErrorString(OP_String* s, void*) override { if (!myErr.empty()) s->setString(myErr.c_str()); }

private:
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
            for (auto& p : myParams) p.lastWritten = NAN;   // プリセットが上書きした値を尊重する
        }
    }

    // 入力1のチャンネル名でパラメータを動かす。**値が変わったときだけ書く**ので、
    // 自動化していないパラメータはプラグインの GUI やプリセット側が持ち主のままになる
    void applyParamsFromInput(const OP_Inputs* in)
    {
        const OP_CHOPInput* pi = in->getInputCHOP(1);
        if (!pi || pi->numSamples < 1) return;
        for (int c = 0; c < pi->numChannels; c++) {
            const char* nm = pi->getChannelName(c);
            if (!nm) continue;
            auto it = myChanMap.find(nm);
            if (it == myChanMap.end()) continue;
            ParamEntry& e = myParams[it->second];
            const float v = pi->getChannelData(c)[pi->numSamples - 1];
            if (!std::isnan(e.lastWritten) && fabsf(v - e.lastWritten) < 1e-7f) continue;
            const float cl = v < e.minV ? e.minV : (v > e.maxV ? e.maxV : v);
            e.p.value = cl;
            e.lastWritten = v;
        }
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
            for (auto& p : myParams) { p.lastWritten = NAN; p.cur = p.p ? p.p.value : p.cur; }
        }
    }

    // ------------------------------------------------------------ state

    const OP_NodeInfo* myNode = nullptr;
    std::string myWindowTitle = "AudioUnit";

    std::vector<PluginEntry> myPlugins;
    std::vector<ParamEntry>  myParams;
    std::vector<std::string> myPresets;
    std::unordered_map<std::string, int> myChanMap;
    std::string myScratch[8];

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
    std::atomic<int64_t> myStateSaves{0};
    bool myAlwaysOnTop = true;
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
