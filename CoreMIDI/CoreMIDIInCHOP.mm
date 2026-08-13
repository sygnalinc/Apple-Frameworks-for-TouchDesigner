// CoreMIDI In CHOP — DAW / 機材から**同期情報**を受け取る。
//
// **ノートや CC の入力は TD 標準の MIDI In CHOP で足りる**ので、ここでは扱わない。
// このOPがあるのは、TD にできない次の2つのため:
//
//   1. **MIDI Clock からテンポを出す。** TD の MIDI In は clock を数値にしてくれない。
//      Logic のようにテンポを送れる DAW をマスターにして、TD 側を追従させられる
//      (MTC はテンポを運ばないので、テンポ同期はこちらの経路でしか成立しない)
//   2. **MTC(タイムコード)を受ける。** TD は MTC に一切対応していない
//
// 加えて CoreMIDI Out と同じく、**UniqueID でデバイスを保持**し**ホットプラグを反映**する。
#include "CHOP_CPlusPlusBase.h"
#include "CoreMIDIShared.h"
#import <Foundation/Foundation.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mach/mach_time.h>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace TD;

namespace {

constexpr int kChans = 12;
const char* kNames[kChans] = {
    "connected", "online", "playing",
    "bpm", "beat", "bar",
    "tc_hours", "tc_minutes", "tc_seconds", "tc_frames", "tc_position", "tc_valid",
};

double hostToSec()
{
    static double f = 0;
    if (f == 0) {
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        f = (double)tb.numer / (double)tb.denom * 1e-9;
    }
    return f;
}

class CoreMIDIInCHOP final : public CHOP_CPlusPlusBase {
public:
    CoreMIDIInCHOP(const OP_NodeInfo*)
    {
        myThread = std::thread([this] { midiThread(); });
        for (int i = 0; i < 100 && !myReady.load(); i++)
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        rescan();
    }

    ~CoreMIDIInCHOP() override
    {
        myQuit = true;
        if (myLoop) CFRunLoopStop(myLoop);
        if (myThread.joinable()) myThread.join();
        if (myPort) MIDIPortDispose(myPort);
        if (myClient) MIDIClientDispose(myClient);
    }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        // 受信は別スレッドで起きるので、見られていなくても回しておく
        g->cookEveryFrame = true;
        g->timeslice = false;
    }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override
    {
        info->numChannels = kChans;
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override
    {
        name->setString(kNames[i]);
    }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        if (mySetupChanged.exchange(false) || myRefresh.exchange(false)) rescan();

        const char* sel = in->getParString("Device");
        const SInt32 wantUID = (sel && *sel) ? (SInt32)strtol(sel, nullptr, 10) : 0;
        if (wantUID != myBoundUID) bind(wantUID);
        myOnline = online(myBoundUID);

        // 一定時間 clock が来なければ停止扱いにする(FC を取りこぼしても復帰できるように)
        {
            std::lock_guard<std::mutex> l(myMutex);
            if (myPlaying && myLastClockHost) {
                const double age = (double)(mach_absolute_time() - myLastClockHost) * hostToSec();
                if (age > 0.5) myPlaying = false;
            }
            const int sig = in->getParInt("Beatsperbar");
            out->channels[0][0] = mySource ? 1.f : 0.f;
            out->channels[1][0] = myOnline ? 1.f : 0.f;
            out->channels[2][0] = myPlaying ? 1.f : 0.f;
            out->channels[3][0] = (float)myBPM;
            out->channels[4][0] = (float)(myClockCount / 24.0);
            out->channels[5][0] = sig > 0 ? (float)(myClockCount / 24.0 / sig) : 0.f;
            out->channels[6][0] = (float)myTC[0];
            out->channels[7][0] = (float)myTC[1];
            out->channels[8][0] = (float)myTC[2];
            out->channels[9][0] = (float)myTC[3];
            out->channels[10][0] = (float)(myTC[0] * 3600 + myTC[1] * 60 + myTC[2] +
                                           (myMtcFps > 0 ? myTC[3] / myMtcFps : 0.0));
            out->channels[11][0] = myMtcValid ? 1.f : 0.f;
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (!strcmp(name, "Refreshdevices")) myRefresh = true;
        else if (!strcmp(name, "Reset")) myReset = true;
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* PAGE = "CoreMIDI In";
        {
            OP_StringParameter p("Device");
            p.label = "Device"; p.page = PAGE; p.defaultValue = "0";
            m->appendDynamicStringMenu(p);
        }
        { OP_NumericParameter p("Refreshdevices"); p.label = "Refresh Devices"; p.page = PAGE; m->appendPulse(p); }
        {
            OP_NumericParameter p("Beatsperbar");
            p.label = "Beats Per Bar"; p.page = PAGE;
            p.defaultValues[0] = 4; p.minSliders[0] = 1; p.maxSliders[0] = 16;
            p.minValues[0] = 1; p.maxValues[0] = 32; p.clampMins[0] = true; p.clampMaxes[0] = true;
            m->appendInt(p);
        }
        {
            // clock 何個ぶんで BPM を平均するか。小さいと追従が速く、大きいと安定する
            OP_NumericParameter p("Smoothing");
            p.label = "BPM Smoothing (clocks)"; p.page = PAGE;
            p.defaultValues[0] = 24; p.minSliders[0] = 6; p.maxSliders[0] = 96;
            p.minValues[0] = 2; p.maxValues[0] = 384; p.clampMins[0] = true; p.clampMaxes[0] = true;
            m->appendInt(p);
        }
        { OP_NumericParameter p("Reset"); p.label = "Reset Position"; p.page = PAGE; m->appendPulse(p); }
    }

    void buildDynamicMenu(const OP_Inputs*, OP_BuildDynamicMenuInfo* info, void*) override
    {
        if (strcmp(info->name, "Device") != 0) return;
        std::lock_guard<std::mutex> l(myMutex);
        info->addMenuEntry("0", "(none)");
        for (const tdmidi::Device& d : myDevices) {
            char val[32]; snprintf(val, sizeof val, "%d", (int)d.uid);
            std::string label = d.name;
            if (!d.manufacturer.empty()) label += "  [" + d.manufacturer + "]";
            if (!d.online) label += "  (offline)";
            info->addMenuEntry(val, label.c_str());
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        const char* n[5] = {"executes", "clocks", "devices", "connected", "mtc_frames"};
        std::lock_guard<std::mutex> l(myMutex);
        float v[5] = {(float)myExec.load(), (float)myClockTotal, (float)myDevices.size(),
                      mySource ? 1.f : 0.f, (float)myMtcTotal};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    bool getInfoDATSize(OP_InfoDATSize* s, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        s->rows = (int32_t)myDevices.size() + 1;
        s->cols = 5;
        s->byColumn = false;
        return true;
    }

    void getInfoDATEntries(int32_t row, int32_t nCols, OP_InfoDATEntries* e, void*) override
    {
        static const char* hdr[5] = {"uniqueid", "name", "manufacturer", "model", "online"};
        std::lock_guard<std::mutex> l(myMutex);
        if (row == 0) {
            for (int i = 0; i < nCols && i < 5; i++) e->values[i]->setString(hdr[i]);
            return;
        }
        const int idx = row - 1;
        if (idx < 0 || idx >= (int)myDevices.size()) return;
        const tdmidi::Device& d = myDevices[idx];
        char uid[32]; snprintf(uid, sizeof uid, "%d", (int)d.uid);
        const char* vals[5] = {uid, d.name.c_str(), d.manufacturer.c_str(), d.model.c_str(),
                               d.online ? "1" : "0"};
        for (int i = 0; i < nCols && i < 5; i++) e->values[i]->setString(vals[i]);
    }

    void getWarningString(OP_String* w, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        if (myDevices.empty())
            w->setString("No MIDI sources. Start the sending app or connect a device.");
        else if (!mySource && !myBoundUID)
            w->setString("No device selected. Pick one in the Device menu.");
        else if (!mySource)
            w->setString("The selected device is not connected. It will reconnect automatically "
                         "when the device comes back.");
    }

private:
    void midiThread()
    {
        @autoreleasepool {
            myLoop = CFRunLoopGetCurrent();
            MIDIClientRef c = 0;
            OSStatus st = MIDIClientCreateWithBlock(CFSTR("TDAppleOps CoreMIDI In"), &c,
                ^(const MIDINotification* n) {
                    if (n->messageID == kMIDIMsgSetupChanged ||
                        n->messageID == kMIDIMsgObjectAdded ||
                        n->messageID == kMIDIMsgObjectRemoved ||
                        n->messageID == kMIDIMsgPropertyChanged)
                        mySetupChanged = true;
                });
            if (st == noErr) {
                myClient = c;
                // 受信は CoreMIDI の高優先度スレッドで呼ばれる。**ここでは状態を更新するだけ**にする
                MIDIInputPortCreateWithBlock(myClient, CFSTR("in"), &myPort,
                    ^(const MIDIPacketList* pl, void*) { receive(pl); });
            }
            myReady = true;
            while (!myQuit.load())
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
        }
    }

    void receive(const MIDIPacketList* pl)
    {
        const MIDIPacket* p = &pl->packet[0];
        for (UInt32 i = 0; i < pl->numPackets; i++) {
            for (UInt16 j = 0; j < p->length; j++) {
                const uint8_t b = p->data[j];
                if (b == 0xF8) onClock();
                else if (b == 0xFA) { onStart(true); }
                else if (b == 0xFB) { onStart(false); }
                else if (b == 0xFC) { std::lock_guard<std::mutex> l(myMutex); myPlaying = false; }
                else if (b == 0xF2 && j + 2 < p->length) {   // Song Position Pointer
                    const int spp = p->data[j + 1] | (p->data[j + 2] << 7);
                    std::lock_guard<std::mutex> l(myMutex);
                    myClockCount = (double)spp * 6.0;        // 16分音符 = clock 6個
                    j += 2;
                } else if (b == 0xF1 && j + 1 < p->length) { // MTC クォーターフレーム
                    onQuarterFrame(p->data[j + 1]);
                    j += 1;
                }
            }
            p = MIDIPacketNext(p);
        }
    }

    void onStart(bool fromTop)
    {
        std::lock_guard<std::mutex> l(myMutex);
        myPlaying = true;
        if (fromTop) myClockCount = 0;
    }

    void onClock()
    {
        const MIDITimeStamp now = mach_absolute_time();
        std::lock_guard<std::mutex> l(myMutex);
        myClockTotal++;
        myClockCount += 1.0;
        myPlaying = true;
        // BPM は「smoothing 個ぶんの経過時間」から出す。1拍 = clock 24個
        myClockHist.push_back(now);
        const size_t want = (size_t)mySmoothing + 1;
        while (myClockHist.size() > want) myClockHist.erase(myClockHist.begin());
        if (myClockHist.size() >= 3) {
            const double span = (double)(myClockHist.back() - myClockHist.front()) * hostToSec();
            const double ticks = (double)(myClockHist.size() - 1);
            if (span > 1e-6) myBPM = 60.0 / (span / ticks * 24.0);
        }
        myLastClockHost = now;
    }

    // クォーターフレーム8個で hh:mm:ss:ff が1つそろう
    void onQuarterFrame(uint8_t data)
    {
        const int piece = (data >> 4) & 0x7;
        const int v = data & 0xF;
        std::lock_guard<std::mutex> l(myMutex);
        myMtcTotal++;
        myQF[piece] = v;
        myQFSeen |= (1 << piece);
        if (piece == 7 && myQFSeen == 0xFF) {
            myTC[3] = myQF[0] | (myQF[1] << 4);              // frames
            myTC[2] = myQF[2] | (myQF[3] << 4);              // seconds
            myTC[1] = myQF[4] | (myQF[5] << 4);              // minutes
            myTC[0] = myQF[6] | ((myQF[7] & 1) << 4);        // hours
            const int rc = (myQF[7] >> 1) & 3;
            myMtcFps = (rc == 0) ? 24.0 : (rc == 1) ? 25.0 : (rc == 2) ? (30.0 / 1.001) : 30.0;
            myMtcValid = true;
            myQFSeen = 0;
        }
    }

    void rescan()
    {
        std::vector<tdmidi::Device> devs = tdmidi::enumerate(true);
        { std::lock_guard<std::mutex> l(myMutex); myDevices.swap(devs); }
        if (myBoundUID) bind(myBoundUID);
    }

    bool online(SInt32 uid)
    {
        std::lock_guard<std::mutex> l(myMutex);
        for (const tdmidi::Device& d : myDevices)
            if (d.uid == uid) return d.online;
        return false;
    }

    void bind(SInt32 uid)
    {
        if (mySource && myPort) MIDIPortDisconnectSource(myPort, mySource);
        myBoundUID = uid;
        mySource = tdmidi::findByUID(uid, true);
        if (mySource && myPort) MIDIPortConnectSource(myPort, mySource, nullptr);
        std::lock_guard<std::mutex> l(myMutex);
        myPlaying = false;
        myClockHist.clear();
    }

    std::thread myThread;
    CFRunLoopRef myLoop = nullptr;
    MIDIClientRef myClient = 0;
    MIDIPortRef myPort = 0;
    MIDIEndpointRef mySource = 0;
    SInt32 myBoundUID = 0;
    bool myOnline = false;
    int mySmoothing = 24;

    std::mutex myMutex;
    std::vector<tdmidi::Device> myDevices;
    std::vector<MIDITimeStamp> myClockHist;
    MIDITimeStamp myLastClockHost = 0;
    double myBPM = 0, myClockCount = 0, myMtcFps = 0;
    uint64_t myClockTotal = 0, myMtcTotal = 0;
    bool myPlaying = false, myMtcValid = false;
    int myQF[8] = {}, myQFSeen = 0, myTC[4] = {};

    std::atomic<bool> myQuit{false}, myReady{false}, mySetupChanged{false},
                      myRefresh{false}, myReset{false};
    std::atomic<uint64_t> myExec{0};
};

} // namespace

extern "C" {

DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    OP_CustomOPInfo& x = info->customOPInfo;
    x.opType->setString("Coremidiin");
    x.opLabel->setString("CoreMIDI In");
    x.opIcon->setString("CMI");
    x.authorName->setString("SYGNAL Inc.");
    x.authorEmail->setString("info@sygnal.tokyo");
    x.cookOnStart = true;
    x.minInputs = 0;
    x.maxInputs = 0;
    x.majorVersion = 0;
    x.minorVersion = 9;
    if (x.opHelpURL)
        x.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/CoreMIDI/README.md");
}

DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new CoreMIDIInCHOP(info);
}

DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (CoreMIDIInCHOP*)instance;
}

}
