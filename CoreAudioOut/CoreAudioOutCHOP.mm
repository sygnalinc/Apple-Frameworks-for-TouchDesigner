// CoreAudio Out CHOP — CoreAudio のデバイスへ直接音を出す(Audio Device Out の代替)。
//
// 存在理由(TD 標準にできないこと・すべて実測):
//  1. **ファイル再生が cook に依存しない。** Audio File In + Audio Device Out は cook 駆動なので、
//     重いフレームで音が作られずバッファが枯渇して途切れる。この op はファイルを自前スレッドで
//     デコードし、CoreAudio の IOProc が直接読むので、cook が何秒止まっても音は続く
//  2. **デバイスのサンプルレートを合わせられる**(Match Device Rate)。TD はデバイスのレートを
//     変えないので 44.1k→48k の変換が常に入る。合わせれば変換ゼロ
//  3. **排他モード(hog)**。ショー中に他アプリの音やレート変更が混ざらない
//
// 入力0(任意)= TD の音声。ファイルとミックスされる。ただし**入力側は cook 駆動のまま**なので、
// cook が止まればその成分は止まる(それを直せるのはファイル再生だけ)。
// 出力 CHOP はモニタ用(実際に鳴った音のコピー)。
#include "CHOP_CPlusPlusBase.h"
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <string>
#include <thread>
#include <vector>
#include <cmath>
#include <cstring>

using namespace TD;

constexpr uint32_t kRing = 1 << 18;          // 262144 サンプル ≈ 48kHz で 5.5 秒
constexpr uint32_t kMask = kRing - 1;

// ---------------------------------------------------------------- ファイルデコーダ
// 自前スレッドで ExtAudioFile を読み、リングを常に満たしておく。
// IOProc(リアルタイムスレッド)はリングを読むだけ。ロックは IOProc 側に持ち込まない
struct FilePlayer {
    std::vector<float> ringL, ringR;
    std::atomic<uint64_t> w{0}, r{0};
    std::atomic<bool> playing{false}, loop{true}, quit{false}, seekReq{false};
    std::atomic<double> seekTo{0}, position{0}, duration{0}, gain{1.0};
    std::string path, err;
    double fileRate = 0, outRate = 48000;
    std::thread th;

    FilePlayer() { ringL.assign(kRing, 0.f); ringR.assign(kRing, 0.f); }
    ~FilePlayer() { stop(); }

    void start(const std::string& p, double devRate)
    {
        stop();
        path = p; outRate = devRate; err.clear();
        w = 0; r = 0; position = 0; quit = false;
        th = std::thread([this] { run(); });
    }
    void stop()
    {
        quit = true;
        if (th.joinable()) th.join();
    }

    void run()
    {
        @autoreleasepool {
            NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
            ExtAudioFileRef f = nullptr;
            if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &f) != noErr || !f) {
                err = "cannot open audio file"; return;
            }
            AudioStreamBasicDescription in = {};
            UInt32 sz = sizeof(in);
            ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &sz, &in);
            fileRate = in.mSampleRate;

            // クライアント形式 = デバイスレートの float32 インターリーブ2ch。
            // レート変換は ExtAudioFile(AudioConverter)が行う
            AudioStreamBasicDescription cf = {};
            cf.mSampleRate = outRate; cf.mFormatID = kAudioFormatLinearPCM;
            cf.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            cf.mChannelsPerFrame = 2; cf.mBitsPerChannel = 32;
            cf.mBytesPerFrame = 8; cf.mFramesPerPacket = 1; cf.mBytesPerPacket = 8;
            if (ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof(cf), &cf) != noErr) {
                err = "unsupported audio format"; ExtAudioFileDispose(f); return;
            }
            SInt64 frames = 0; sz = sizeof(frames);
            ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileLengthFrames, &sz, &frames);
            duration = fileRate > 0 ? (double)frames / fileRate : 0;

            std::vector<float> buf(4096 * 2);
            while (!quit.load()) {
                if (seekReq.exchange(false)) {
                    const double t = seekTo.load();
                    ExtAudioFileSeek(f, (SInt64)(t * fileRate));
                    position = t;
                    w.store(r.load());          // リングを空にして即座に新しい位置から
                }
                if (!playing.load()) { std::this_thread::sleep_for(std::chrono::milliseconds(10)); continue; }
                // リングの空きが半分を切るまで詰める
                const uint64_t used = w.load() - r.load();
                if (used > kRing / 2) { std::this_thread::sleep_for(std::chrono::milliseconds(5)); continue; }

                AudioBufferList abl; abl.mNumberBuffers = 1;
                abl.mBuffers[0].mNumberChannels = 2;
                abl.mBuffers[0].mDataByteSize = (UInt32)(buf.size() * sizeof(float));
                abl.mBuffers[0].mData = buf.data();
                UInt32 n = 4096;
                if (ExtAudioFileRead(f, &n, &abl) != noErr) { err = "read error"; break; }
                if (n == 0) {                    // ファイル末尾
                    if (loop.load()) { ExtAudioFileSeek(f, 0); position = 0; continue; }
                    playing = false; continue;
                }
                const float g = (float)gain.load();
                uint64_t wp = w.load();
                for (UInt32 i = 0; i < n; i++) {
                    ringL[(wp + i) & kMask] = buf[i*2]   * g;
                    ringR[(wp + i) & kMask] = buf[i*2+1] * g;
                }
                w.store(wp + n);
                position = position + (double)n / outRate * (fileRate > 0 ? 1.0 : 1.0);
            }
            ExtAudioFileDispose(f);
        }
    }
};

// ---------------------------------------------------------------- CHOP
class CoreAudioOutCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit CoreAudioOutCHOP(const OP_NodeInfo*)
    {
        for (int c = 0; c < 2; c++) { myInRing[c].assign(kRing, 0.f); myMonRing[c].assign(kRing, 0.f); }
    }
    ~CoreAudioOutCHOP() override { teardown(); }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrame = true;                 // 入力を出力に運ぶので毎フレーム
        g->timeslice = true;
    }
    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override
    {
        info->numChannels = 2;
        info->sampleRate = (float)(myDevRate > 0 ? myDevRate : 48000);
        return true;
    }
    void getChannelName(int32_t i, OP_String* n, const OP_Inputs*, void*) override
    {
        n->setString(i == 0 ? "left" : "right");
    }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        const int n = out->numSamples;
        for (int c = 0; c < out->numChannels; c++) memset(out->channels[c], 0, sizeof(float) * n);

        const bool active = in->getParInt("Active") != 0;
        if (!active) { teardown(); return; }

        ensureDevice(in);
        if (!myRunning) return;

        // ---- ファイル再生の指示(実処理はデコーダスレッド)
        const char* fp = in->getParString("File");
        const std::string want = fp ? fp : "";
        if (myPlayer.outRate > 0 && fabs(myPlayer.outRate - myDevRate) > 1 && !myFilePath.empty()) {
            myPlayer.start(myFilePath, myDevRate);      // レートが変わった。開き直す
        }
        if (want != myFilePath) {
            myFilePath = want;
            if (!want.empty()) myPlayer.start(want, myDevRate);
            else myPlayer.stop();
        }
        myPlayer.playing = in->getParInt("Play") != 0;
        myPlayer.loop = in->getParInt("Loop") != 0;
        myPlayer.gain = in->getParDouble("Filegain");
        if (myWantCue.exchange(false)) { myPlayer.seekTo = in->getParDouble("Cuepoint"); myPlayer.seekReq = true; }

        // ---- 入力0(TD の音声)をリングへ積む(IOProc が読む)
        const OP_CHOPInput* ci = in->getInputCHOP(0);
        const float ig = (float)in->getParDouble("Inputgain");
        if (ci && ci->numSamples > 0 && ci->numChannels > 0) {
            const int ns = ci->numSamples;
            const float* L = ci->getChannelData(0);
            const float* R = ci->numChannels > 1 ? ci->getChannelData(1) : L;
            uint64_t wp = myInW.load();
            for (int i = 0; i < ns; i++) {
                myInRing[0][(wp + i) & kMask] = L[i] * ig;
                myInRing[1][(wp + i) & kMask] = R[i] * ig;
            }
            myInW.store(wp + ns);
        }

        // ---- モニタ出力(IOProc が実際に鳴らした音のコピー)
        uint64_t mr = myMonR.load();
        const uint64_t mw = myMonW.load();
        const int avail = (int)(mw - mr);
        const int give = n < avail ? n : (avail > 0 ? avail : 0);
        for (int i = 0; i < give; i++) {
            out->channels[0][i] = myMonRing[0][(mr + i) & kMask];
            out->channels[1][i] = myMonRing[1][(mr + i) & kMask];
        }
        myMonR.store(mr + give);
        if (avail > (int)myDevRate) myMonR.store(mw - (uint64_t)myDevRate / 4);   // 溜まりすぎたら追いつく
    }

    // ------------------------------------------------------------ デバイス
    struct Dev { AudioDeviceID id; std::string name; UInt32 uid; };

    // 出力ストリームを持つデバイスを列挙する
    static std::vector<Dev> listOutputs()
    {
        std::vector<Dev> out;
        AudioObjectPropertyAddress da = { kAudioHardwarePropertyDevices,
                                          kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 sz = 0;
        if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &da, 0, nullptr, &sz) != noErr || !sz)
            return out;
        std::vector<AudioDeviceID> ids(sz / sizeof(AudioDeviceID));
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &da, 0, nullptr, &sz, ids.data());
        for (AudioDeviceID d : ids) {
            AudioObjectPropertyAddress sa = { kAudioDevicePropertyStreams,
                                              kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
            UInt32 ssz = 0;
            if (AudioObjectGetPropertyDataSize(d, &sa, 0, nullptr, &ssz) != noErr || ssz < sizeof(AudioStreamID))
                continue;                                     // 出力を持たない(マイク等)
            CFStringRef nm = nullptr; UInt32 nsz = sizeof(nm);
            AudioObjectPropertyAddress na = { kAudioObjectPropertyName,
                                              kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            std::string name = "?";
            if (AudioObjectGetPropertyData(d, &na, 0, nullptr, &nsz, &nm) == noErr && nm) {
                char b[256] = {};
                CFStringGetCString(nm, b, sizeof b, kCFStringEncodingUTF8);
                name = b; CFRelease(nm);
            }
            out.push_back({ d, name, (UInt32)d });
        }
        return out;
    }

    static AudioDeviceID defaultOut()
    {
        AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice,
                                         kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioDeviceID d = 0; UInt32 sz = sizeof(d);
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &sz, &d);
        return d;
    }
    static std::vector<double> ratesOf(AudioDeviceID d)
    {
        std::vector<double> out;
        AudioObjectPropertyAddress a = { kAudioDevicePropertyAvailableNominalSampleRates,
                                         kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        UInt32 sz = 0;
        if (AudioObjectGetPropertyDataSize(d, &a, 0, nullptr, &sz) != noErr || !sz) return out;
        std::vector<AudioValueRange> rr(sz / sizeof(AudioValueRange));
        AudioObjectGetPropertyData(d, &a, 0, nullptr, &sz, rr.data());
        for (const AudioValueRange& r : rr) out.push_back(r.mMinimum);
        return out;
    }

    static double rateOf(AudioDeviceID d)
    {
        AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate,
                                         kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Float64 r = 0; UInt32 sz = sizeof(r);
        AudioObjectGetPropertyData(d, &a, 0, nullptr, &sz, &r);
        return r;
    }

    void ensureDevice(const OP_Inputs* in)
    {
        // ---- デバイス選択(default = システム既定に追従)
        const char* sel = in->getParString("Device");
        AudioDeviceID dev = 0;
        if (sel && *sel && strcmp(sel, "default")) {
            const AudioDeviceID want = (AudioDeviceID)strtoul(sel, nullptr, 10);
            for (const Dev& d : listOutputs()) if (d.id == want) { dev = want; break; }
            if (!dev) { teardown(); myErr = "selected device is not connected"; return; }
        } else {
            dev = defaultOut();
        }
        const bool hog = in->getParInt("Exclusive") != 0;

        // ---- デバイスのレート変更(システム全体に効く)
        const char* rp = in->getParString("Devicerate");
        const double wantRate = (rp && strcmp(rp, "asis")) ? atof(rp) : 0;
        const char* bp = in->getParString("Buffersize");
        const UInt32 wantBuf = (bp && strcmp(bp, "asis")) ? (UInt32)atoi(bp) : 0;

        if (myRunning && dev == myDev && hog == myHog &&
            wantRate == myWantRate && wantBuf == myWantBuf) return;
        teardown();
        if (!dev) { myErr = "no output device"; return; }
        myDev = dev; myHog = hog; myWantRate = wantRate; myWantBuf = wantBuf;
        myWarn.clear();

        if (wantRate > 0) {
            bool ok = false;
            for (double r : ratesOf(dev)) if (fabs(r - wantRate) < 1) ok = true;
            if (!ok) myWarn = "device does not support that sample rate";
            else {
                AudioObjectPropertyAddress a = { kAudioDevicePropertyNominalSampleRate,
                                                 kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                Float64 v = wantRate;
                if (AudioObjectSetPropertyData(dev, &a, 0, nullptr, sizeof(v), &v) != noErr)
                    myWarn = "could not set the device sample rate";
                else {
                    // 反映は非同期。少し待って読み直す
                    for (int i = 0; i < 20 && fabs(rateOf(dev) - wantRate) > 1; i++)
                        std::this_thread::sleep_for(std::chrono::milliseconds(25));
                }
            }
        }
        if (wantBuf > 0) {
            AudioObjectPropertyAddress a = { kAudioDevicePropertyBufferFrameSize,
                                             kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
            UInt32 v = wantBuf;
            if (AudioObjectSetPropertyData(dev, &a, 0, nullptr, sizeof(v), &v) != noErr)
                myWarn = "could not set the buffer size";
        }
        myDevRate = rateOf(dev);

        if (hog) {
            pid_t me = getpid();
            AudioObjectPropertyAddress ha = { kAudioDevicePropertyHogMode,
                                              kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            if (AudioObjectSetPropertyData(dev, &ha, 0, nullptr, sizeof(me), &me) != noErr)
                myWarn = "could not take exclusive access";
            else myHogged = true;
        }

        CoreAudioOutCHOP* self_ = this;
        OSStatus st = AudioDeviceCreateIOProcIDWithBlock(&myProc, dev, nullptr,
            ^(const AudioTimeStamp*, const AudioBufferList*, const AudioTimeStamp*,
              AudioBufferList* outB, const AudioTimeStamp*) {
                self_->render(outB);
            });
        if (st != noErr) { myErr = "could not create IOProc"; return; }
        st = AudioDeviceStart(dev, myProc);
        if (st != noErr) { myErr = "could not start device"; return; }
        myErr.clear();
        myRunning = true;
    }

    // IOProc(リアルタイムスレッド)。ロック禁止・確保禁止
    void render(AudioBufferList* outB)
    {
        for (UInt32 b = 0; b < outB->mNumberBuffers; b++) {
            float* dst = (float*)outB->mBuffers[b].mData;
            const UInt32 ch = outB->mBuffers[b].mNumberChannels;
            const UInt32 nf = outB->mBuffers[b].mDataByteSize / (sizeof(float) * (ch ? ch : 1));
            uint64_t fr = myPlayer.r.load();
            const uint64_t fw = myPlayer.w.load();
            uint64_t ir = myInR.load();
            const uint64_t iw = myInW.load();
            uint64_t mw = myMonW.load();
            for (UInt32 i = 0; i < nf; i++) {
                float L = 0, R = 0;
                if (fr < fw) { L += myPlayer.ringL[fr & kMask]; R += myPlayer.ringR[fr & kMask]; fr++; }
                if (ir < iw) { L += myInRing[0][ir & kMask];    R += myInRing[1][ir & kMask];    ir++; }
                if (ch >= 2) { dst[i*ch] = L; dst[i*ch+1] = R; }
                else if (ch == 1) dst[i] = (L + R) * 0.5f;
                myMonRing[0][mw & kMask] = L; myMonRing[1][mw & kMask] = R; mw++;
            }
            myPlayer.r.store(fr);
            myInR.store(ir);
            myMonW.store(mw);
            break;                                   // 最初のバッファのみ(通常1つ)
        }
    }

    void teardown()
    {
        if (myProc) { AudioDeviceStop(myDev, myProc); AudioDeviceDestroyIOProcID(myDev, myProc); myProc = nullptr; }
        if (myHogged) {
            pid_t none = -1;
            AudioObjectPropertyAddress ha = { kAudioDevicePropertyHogMode,
                                              kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            AudioObjectSetPropertyData(myDev, &ha, 0, nullptr, sizeof(none), &none);
            myHogged = false;
        }
        myRunning = false;
    }

    // ------------------------------------------------------------ パラメータ
    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "CoreAudio Out";
        { OP_NumericParameter p("Active"); p.label = "Active"; p.page = P; p.defaultValues[0] = 1; m->appendToggle(p); }
        {
            // 出力デバイス。内部値は AudioDeviceID の文字列(default = システム既定に追従)
            OP_StringParameter p("Device"); p.label = "Device"; p.page = P;
            p.defaultValue = "default";       // 動的メニューは既定値が空だと生成されない(既知の罠)
            m->appendDynamicStringMenu(p);
        }
        {
            // デバイスのサンプルレートを変更する(システム全体に効く)。
            // device = 触らない / 44100〜96000 = そのレートへ設定
            OP_StringParameter p("Devicerate"); p.label = "Device Sample Rate"; p.page = P;
            const char* n[] = { "asis", "44100", "48000", "88200", "96000" };
            const char* l[] = { "As Is", "44100", "48000", "88200", "96000" };
            p.defaultValue = "asis";
            m->appendMenu(p, 5, n, l);
        }
        {
            // デバイスの I/O バッファ(フレーム数)。小さいほど低レイテンシ・音切れしやすい
            OP_StringParameter p("Buffersize"); p.label = "Buffer Size (frames)"; p.page = P;
            const char* n[] = { "asis", "64", "128", "256", "512", "1024", "2048" };
            const char* l[] = { "As Is", "64", "128", "256", "512", "1024", "2048" };
            p.defaultValue = "asis";
            m->appendMenu(p, 7, n, l);
        }
        { OP_NumericParameter p("Inputgain"); p.label = "Input Gain"; p.page = P; p.defaultValues[0] = 1;
          p.minSliders[0] = 0; p.maxSliders[0] = 2; m->appendFloat(p); }
        { OP_NumericParameter p("Exclusive"); p.label = "Exclusive (Hog Mode)"; p.page = P; p.defaultValues[0] = 0; m->appendToggle(p); }

        const char* F = "File Player";
        { OP_StringParameter p("File"); p.label = "Audio File"; p.page = F; m->appendFile(p); }
        { OP_NumericParameter p("Play"); p.label = "Play"; p.page = F; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Loop"); p.label = "Loop"; p.page = F; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Filegain"); p.label = "File Gain"; p.page = F; p.defaultValues[0] = 1;
          p.minSliders[0] = 0; p.maxSliders[0] = 2; m->appendFloat(p); }
        { OP_NumericParameter p("Cuepoint"); p.label = "Cue Point (s)"; p.page = F; p.defaultValues[0] = 0;
          p.minSliders[0] = 0; p.maxSliders[0] = 60; m->appendFloat(p); }
        { OP_NumericParameter p("Cuepulse"); p.label = "Cue Pulse"; p.page = F; m->appendPulse(p); }
    }
    void pulsePressed(const char* name, void*) override
    {
        if (!strcmp(name, "Cuepulse")) myWantCue = true;
    }

    void buildDynamicMenu(const OP_Inputs*, OP_BuildDynamicMenuInfo* info, void*) override
    {
        if (strcmp(info->name, "Device")) return;
        info->addMenuEntry("default", "System Default");
        for (const Dev& d : listOutputs()) {
            char v[16]; snprintf(v, sizeof v, "%u", (unsigned)d.uid);
            info->addMenuEntry(v, d.name.c_str());
        }
    }

    // ------------------------------------------------------------ info
    int32_t getNumInfoCHOPChans(void*) override { return 7; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        static const char* n[] = { "executes", "device_rate", "running",
                                   "file_position", "file_duration", "file_buffered", "buffer_frames" };
        UInt32 bf = 0; UInt32 bsz = sizeof(bf);
        if (myDev) {
            AudioObjectPropertyAddress a = { kAudioDevicePropertyBufferFrameSize,
                                             kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
            AudioObjectGetPropertyData(myDev, &a, 0, nullptr, &bsz, &bf);
        }
        const float v[] = { (float)myExec.load(), (float)myDevRate, myRunning ? 1.f : 0.f,
                            (float)myPlayer.position.load(), (float)myPlayer.duration.load(),
                            (float)(myPlayer.w.load() - myPlayer.r.load()), (float)bf };
        c->name->setString(n[i]); c->value = v[i];
    }
    void getErrorString(OP_String* s, void*) override
    {
        if (!myErr.empty()) s->setString(myErr.c_str());
        else if (!myPlayer.err.empty()) s->setString(myPlayer.err.c_str());
    }
    void getWarningString(OP_String* s, void*) override { if (!myWarn.empty()) s->setString(myWarn.c_str()); }

private:
    std::atomic<int> myExec{0};
    AudioDeviceID myDev = 0;
    AudioDeviceIOProcID myProc = nullptr;
    double myDevRate = 48000;
    bool myRunning = false, myHog = false, myHogged = false;
    double myWantRate = 0; UInt32 myWantBuf = 0;
    std::string myErr, myWarn, myFilePath;
    std::atomic<bool> myWantCue{false};

    FilePlayer myPlayer;
    std::vector<float> myInRing[2];
    std::atomic<uint64_t> myInW{0}, myInR{0};
    std::vector<float> myMonRing[2];
    std::atomic<uint64_t> myMonW{0}, myMonR{0};
};

// ---------------------------------------------------------------- entry
extern "C" {

DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    info->setAPIVersion(CHOPCPlusPlusAPIVersion);
    info->customOPInfo.opType->setString("Coreaudioout");
    info->customOPInfo.opLabel->setString("CoreAudio Out");
    info->customOPInfo.opIcon->setString("CAO");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.authorEmail->setString("");
    info->customOPInfo.minInputs = 0;       // 入力0 = TD の音声(任意)
    info->customOPInfo.maxInputs = 1;
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    if (info->customOPInfo.opHelpURL)
        info->customOPInfo.opHelpURL->setString(
            "https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/CoreAudioOut/README.md");
}

DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* info) { return new CoreAudioOutCHOP(info); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* instance) { delete (CoreAudioOutCHOP*)instance; }

}
