// CoreMIDI Out CHOP — MIDI 送信。TD 標準の MIDI Out CHOP が持っていない部分を埋める。
//
// TD 標準との違い(2026-08-13 に libMIDI.dylib のシンボルを調べて確認):
//   * TD はデバイス一覧を**起動時のスナップショット**でしか持たない。起動後に挿した機材は
//     現れず、抜けた機材は残り続ける(死んだエンドポイントに送り続けて無反応になる)。
//     こちらは MIDIClientCreateWithBlock の通知で **ホットプラグを反映**する
//   * TD はデバイスを**表示名でしか識別しない**。同名機材を区別できず、挿し直しで壊れる。
//     こちらは **UniqueID で保持**し、再接続時に MIDIObjectFindByUniqueID で自動的に繋ぎ直す
//   * 製造元 / モデル / オンライン状態が取れない → Info DAT に出す
//
// 送信テストは**パラメータだけで完結**する(Send Note / Send CC / All Notes Off のパルス)。
// スクリプトを書かずに配線と機材を確認できる。
//
// 注意: CHOP は出力がどこかで使われていないと cook されない。Note の自動 Note Off も
// cook で処理するので、テスト時は Null CHOP などに繋いでおくこと。
#include "CHOP_CPlusPlusBase.h"
#import <CoreMIDI/CoreMIDI.h>
#import <Foundation/Foundation.h>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace TD;

namespace {

struct Device {
    SInt32 uid = 0;
    bool online = true;
    std::string name, manufacturer, model;
};

std::string strProp(MIDIObjectRef obj, CFStringRef key)
{
    CFStringRef s = nullptr;
    if (MIDIObjectGetStringProperty(obj, key, &s) != noErr || !s) return "";
    char buf[256] = {};
    CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
    CFRelease(s);
    return buf;
}

SInt32 intProp(MIDIObjectRef obj, CFStringRef key)
{
    SInt32 v = 0;
    MIDIObjectGetIntegerProperty(obj, key, &v);
    return v;
}

constexpr int kOutChans = 3;   // connected / online / sends
const char* kOutNames[kOutChans] = {"connected", "online", "sends"};

class CoreMIDIOutCHOP final : public CHOP_CPlusPlusBase {
public:
    CoreMIDIOutCHOP(const OP_NodeInfo*)
    {
        // CoreMIDI の setup 変更通知は**クライアントを作ったスレッドのランループ**へ届く。
        // cook スレッドにはランループが無いので、専用スレッドを立ててそこで作る
        // (Bonjour で同じ罠を踏んでいる。詳細は skill pitfalls.md)。
        myThread = std::thread([this] { midiThread(); });
        // クライアントができるまで待つ(最初の cook で送信できるように)
        for (int i = 0; i < 100 && !myReady.load(); i++)
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    ~CoreMIDIOutCHOP() override
    {
        myQuit = true;
        if (myLoop) CFRunLoopStop(myLoop);
        if (myThread.joinable()) myThread.join();
        if (myPort) MIDIPortDispose(myPort);
        if (myClient) MIDIClientDispose(myClient);
    }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrameIfAsked = true;
        g->timeslice = false;
    }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override
    {
        info->numChannels = kOutChans;
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override
    {
        name->setString(kOutNames[i]);
    }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;

        // ホットプラグ、または Refresh パルスで一覧を作り直す
        if (mySetupChanged.exchange(false) || myRefresh.exchange(false))
            rescan();
        if (myDevices.empty() && myExec == 1) rescan();

        const bool active = in->getParInt("Active") != 0;
        const char* sel = in->getParString("Device");
        const SInt32 wantUID = (sel && *sel) ? (SInt32)strtol(sel, nullptr, 10) : 0;
        if (wantUID != myBoundUID) bindDevice(wantUID);
        // 同じ UniqueID の機材が挿し直された場合も、通知後の rescan で繋ぎ直る
        myOnline = deviceOnline(myBoundUID);

        const int ch = clampi(in->getParInt("Channel"), 1, 16) - 1;

        if (active && myDest) {
            handleInput(in, ch);
            handlePulses(in, ch);
        } else {
            myNoteOff.clear();
            myPendingNote = myPendingCC = myPendingPanic = false;
            myPendingPlay = myPendingStop = myPendingRec = myPendingRewind = false;
        }
        flushNoteOffs(ch);

        out->channels[0][0] = (myDest != 0) ? 1.0f : 0.0f;
        out->channels[1][0] = myOnline ? 1.0f : 0.0f;
        out->channels[2][0] = (float)mySends.load();
    }

    void pulsePressed(const char* name, void*) override
    {
        if (!strcmp(name, "Sendnote")) myPendingNote = true;
        else if (!strcmp(name, "Sendcc")) myPendingCC = true;
        else if (!strcmp(name, "Allnotesoff")) myPendingPanic = true;
        else if (!strcmp(name, "Refreshdevices")) myRefresh = true;
        else if (!strcmp(name, "Play")) myPendingPlay = true;
        else if (!strcmp(name, "Stop")) myPendingStop = true;
        else if (!strcmp(name, "Record")) myPendingRec = true;
        else if (!strcmp(name, "Rewind")) myPendingRewind = true;
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* PAGE = "CoreMIDI Out";
        {
            OP_NumericParameter p("Active");
            p.label = "Active"; p.page = PAGE; p.defaultValues[0] = 1;
            m->appendToggle(p);
        }
        {
            // 値は **UniqueID**(表示名ではない)。挿し直しても同じ機材に繋ぎ直せる。
            // 動的メニューは非空の既定値が要る(空だとパラメータ自体が生成されない・既知の罠)
            OP_StringParameter p("Device");
            p.label = "Device"; p.page = PAGE; p.defaultValue = "0";
            m->appendDynamicStringMenu(p);   // 中身は buildDynamicMenu で組む
        }
        {
            OP_NumericParameter p("Refreshdevices");
            p.label = "Refresh Devices"; p.page = PAGE;
            m->appendPulse(p);
        }
        {
            OP_NumericParameter p("Channel");
            p.label = "Channel"; p.page = PAGE;
            p.defaultValues[0] = 1; p.minSliders[0] = 1; p.maxSliders[0] = 16;
            p.minValues[0] = 1; p.maxValues[0] = 16; p.clampMins[0] = true; p.clampMaxes[0] = true;
            m->appendInt(p);
        }

        // --- パラメータだけで送信できるようにする(スクリプト不要) ---
        const char* TEST = "Send";
        auto ip = [&](const char* n, const char* l, int d, int lo, int hi) {
            OP_NumericParameter p(n);
            p.label = l; p.page = TEST; p.defaultValues[0] = d;
            p.minSliders[0] = lo; p.maxSliders[0] = hi;
            p.minValues[0] = lo; p.maxValues[0] = hi;
            p.clampMins[0] = true; p.clampMaxes[0] = true;
            m->appendInt(p);
        };
        ip("Note", "Note (0-127)", 60, 0, 127);
        ip("Velocity", "Velocity (0-127)", 100, 0, 127);
        {
            OP_NumericParameter p("Duration");
            p.label = "Note Duration (sec)"; p.page = TEST;
            p.defaultValues[0] = 0.3; p.minSliders[0] = 0.05; p.maxSliders[0] = 5.0;
            m->appendFloat(p);
        }
        { OP_NumericParameter p("Sendnote"); p.label = "Send Note"; p.page = TEST; m->appendPulse(p); }
        ip("Ccnumber", "CC Number (0-127)", 74, 0, 127);
        ip("Ccvalue", "CC Value (0-127)", 64, 0, 127);
        { OP_NumericParameter p("Sendcc"); p.label = "Send CC"; p.page = TEST; m->appendPulse(p); }
        { OP_NumericParameter p("Allnotesoff"); p.label = "All Notes Off (panic)"; p.page = TEST; m->appendPulse(p); }

        // --- DAW のトランスポート操作 ---
        // 経路が2つあり、どちらを聞くかは DAW 側の設定で決まる:
        //   mmc      … MIDI Machine Control(SysEx)。Logic は環境設定 > MIDI > 同期 で
        //              「MMC を受信」を有効にすると反応する
        //   realtime … MIDI リアルタイム(FA/FB/FC)。DAW を MIDI クロックに同期させる設定が要る
        // どちらが有効か分からないので既定は both(両方送る)。二重に反応する DAW では片方に絞る。
        {
            OP_StringParameter p("Transport");
            p.label = "Transport Method"; p.page = TEST; p.defaultValue = "both";
            const char* nm[] = {"mmc", "realtime", "both"};
            const char* lb[] = {"MMC (SysEx)", "MIDI Realtime", "Both"};
            m->appendMenu(p, 3, nm, lb);
        }
        {
            OP_NumericParameter p("Mmcdevice");
            p.label = "MMC Device ID"; p.page = TEST;
            p.defaultValues[0] = 127;                  // 127 = all devices
            p.minSliders[0] = 0; p.maxSliders[0] = 127;
            p.minValues[0] = 0; p.maxValues[0] = 127;
            p.clampMins[0] = true; p.clampMaxes[0] = true;
            m->appendInt(p);
        }
        { OP_NumericParameter p("Play");   p.label = "Play";   p.page = TEST; m->appendPulse(p); }
        { OP_NumericParameter p("Stop");   p.label = "Stop";   p.page = TEST; m->appendPulse(p); }
        { OP_NumericParameter p("Record"); p.label = "Record"; p.page = TEST; m->appendPulse(p); }
        { OP_NumericParameter p("Rewind"); p.label = "Return to Start"; p.page = TEST; m->appendPulse(p); }
    }

    void buildDynamicMenu(const OP_Inputs*, OP_BuildDynamicMenuInfo* info, void*) override
    {
        if (strcmp(info->name, "Device") != 0) return;
        std::lock_guard<std::mutex> l(myMutex);
        info->addMenuEntry("0", "(none)");
        for (const Device& d : myDevices) {
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
        const char* n[5] = {"executes", "sends", "devices", "connected", "online"};
        std::lock_guard<std::mutex> l(myMutex);
        float v[5] = {(float)myExec.load(), (float)mySends.load(), (float)myDevices.size(),
                      myDest ? 1.f : 0.f, myOnline ? 1.f : 0.f};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    // 機材の素性を表に出す。TD 標準は表示名しか持っていないので、ここが本 OP の主目的の一つ
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
        const Device& d = myDevices[idx];
        char uid[32]; snprintf(uid, sizeof uid, "%d", (int)d.uid);
        const char* vals[5] = {uid, d.name.c_str(), d.manufacturer.c_str(), d.model.c_str(),
                               d.online ? "1" : "0"};
        for (int i = 0; i < nCols && i < 5; i++) e->values[i]->setString(vals[i]);
    }

    void getWarningString(OP_String* w, void*) override
    {
        std::lock_guard<std::mutex> l(myMutex);
        if (myDevices.empty())
            w->setString("No MIDI destinations. Start the receiving app (Logic Pro publishes its own "
                         "virtual input), or enable the IAC Driver in Audio MIDI Setup.");
        else if (!myDest && !myBoundUID)
            w->setString("No device selected. Pick one in the Device menu.");
        else if (!myDest)
            // 選んだ機材が今は居ない。UniqueID は保持しているので、挿し直せば自動で繋ぎ直る
            w->setString("The selected device is not connected. It will reconnect automatically "
                         "when the device comes back.");
        else if (!myOnline)
            w->setString("The selected device is offline.");
    }

private:
    static int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

    // ---- MIDI 通知用スレッド(ランループ常駐) ----
    void midiThread()
    {
        @autoreleasepool {
            myLoop = CFRunLoopGetCurrent();
            MIDIClientRef c = 0;
            OSStatus st = MIDIClientCreateWithBlock(CFSTR("TDAppleOps CoreMIDI Out"), &c,
                ^(const MIDINotification* n) {
                    // 機材の抜き差し・名前変更など。ここでは印を付けるだけにして、
                    // 実際の再列挙は cook スレッドで行う(スレッド跨ぎの状態共有を避ける)
                    if (n->messageID == kMIDIMsgSetupChanged ||
                        n->messageID == kMIDIMsgObjectAdded ||
                        n->messageID == kMIDIMsgObjectRemoved ||
                        n->messageID == kMIDIMsgPropertyChanged)
                        mySetupChanged = true;
                });
            if (st == noErr) {
                myClient = c;
                MIDIOutputPortCreate(myClient, CFSTR("out"), &myPort);
            }
            myReady = true;
            while (!myQuit.load())
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
        }
    }

    void rescan()
    {
        std::vector<Device> devs;
        const ItemCount n = MIDIGetNumberOfDestinations();
        for (ItemCount i = 0; i < n; i++) {
            MIDIEndpointRef ep = MIDIGetDestination(i);
            if (!ep) continue;
            Device d;
            d.uid = intProp(ep, kMIDIPropertyUniqueID);
            d.online = intProp(ep, kMIDIPropertyOffline) == 0;
            d.name = strProp(ep, kMIDIPropertyDisplayName);
            if (d.name.empty()) d.name = strProp(ep, kMIDIPropertyName);
            d.manufacturer = strProp(ep, kMIDIPropertyManufacturer);
            d.model = strProp(ep, kMIDIPropertyModel);
            devs.push_back(d);
        }
        {
            std::lock_guard<std::mutex> l(myMutex);
            myDevices.swap(devs);
        }
        // 抜き差しで参照が変わるので、選択中の機材は必ず引き直す
        if (myBoundUID) bindDevice(myBoundUID);
    }

    bool deviceOnline(SInt32 uid) const
    {
        if (!uid) return false;
        for (const Device& d : myDevices)
            if (d.uid == uid) return d.online;
        return false;
    }

    // **UniqueID から実体を引き直す。TD が持っていない API**
    void bindDevice(SInt32 uid)
    {
        myBoundUID = uid;
        myDest = 0;
        if (!uid) return;
        MIDIObjectRef obj = 0;
        MIDIObjectType type = kMIDIObjectType_Other;
        if (MIDIObjectFindByUniqueID(uid, &obj, &type) == noErr &&
            (type == kMIDIObjectType_Destination || type == kMIDIObjectType_ExternalDestination))
            myDest = (MIDIEndpointRef)obj;
    }

    void sendBytes(const uint8_t* b, int n)
    {
        if (!myPort || !myDest) return;
        Byte storage[256];
        MIDIPacketList* pl = (MIDIPacketList*)storage;
        MIDIPacket* p = MIDIPacketListInit(pl);
        p = MIDIPacketListAdd(pl, sizeof storage, p, 0, n, b);
        if (p && MIDISend(myPort, myDest, pl) == noErr) mySends++;
    }

    void noteOn(int ch, int note, int vel)
    {
        uint8_t b[3] = {(uint8_t)(0x90 | ch), (uint8_t)clampi(note, 0, 127), (uint8_t)clampi(vel, 0, 127)};
        sendBytes(b, 3);
    }
    void noteOff(int ch, int note)
    {
        uint8_t b[3] = {(uint8_t)(0x80 | ch), (uint8_t)clampi(note, 0, 127), 0};
        sendBytes(b, 3);
    }
    void controlChange(int ch, int cc, int val)
    {
        uint8_t b[3] = {(uint8_t)(0xB0 | ch), (uint8_t)clampi(cc, 0, 127), (uint8_t)clampi(val, 0, 127)};
        sendBytes(b, 3);
    }

    void handlePulses(const OP_Inputs* in, int ch)
    {
        if (myPendingNote.exchange(false)) {
            const int note = in->getParInt("Note");
            noteOn(ch, note, in->getParInt("Velocity"));
            myNoteOff.push_back({note, now() + in->getParDouble("Duration")});
        }
        if (myPendingCC.exchange(false))
            controlChange(ch, in->getParInt("Ccnumber"), in->getParInt("Ccvalue"));
        handleTransport(in);
        if (myPendingPanic.exchange(false)) {
            myNoteOff.clear();
            for (int c = 0; c < 16; c++) {
                uint8_t b[3] = {(uint8_t)(0xB0 | c), 123, 0};   // All Notes Off
                sendBytes(b, 3);
            }
        }
    }

    // MMC は SysEx: F0 7F <deviceID> 06 <cmd> F7
    void mmc(int devId, uint8_t cmd)
    {
        uint8_t b[6] = {0xF0, 0x7F, (uint8_t)clampi(devId, 0, 127), 0x06, cmd, 0xF7};
        sendBytes(b, 6);
    }
    void realtime(uint8_t status) { sendBytes(&status, 1); }

    void handleTransport(const OP_Inputs* in)
    {
        const bool play = myPendingPlay.exchange(false);
        const bool stop = myPendingStop.exchange(false);
        const bool rec = myPendingRec.exchange(false);
        const bool rew = myPendingRewind.exchange(false);
        if (!play && !stop && !rec && !rew) return;

        const char* mode = in->getParString("Transport");
        const std::string mo = mode ? mode : "both";
        const bool useMMC = (mo != "realtime");
        const bool useRT = (mo != "mmc");
        const int dev = in->getParInt("Mmcdevice");

        if (rew) {
            // MMC Locate: F0 7F <id> 06 44 06 01 hh mm ss ff sf F7 (00:00:00:00)
            if (useMMC) {
                uint8_t b[13] = {0xF0, 0x7F, (uint8_t)clampi(dev, 0, 127), 0x06, 0x44, 0x06, 0x01,
                                 0, 0, 0, 0, 0, 0xF7};
                sendBytes(b, 13);
            }
            if (useRT) {   // Song Position Pointer = 0
                uint8_t b[3] = {0xF2, 0, 0};
                sendBytes(b, 3);
            }
        }
        if (stop) {
            if (useMMC) mmc(dev, 0x01);
            if (useRT) realtime(0xFC);
        }
        if (rec) {
            if (useMMC) mmc(dev, 0x06);   // Record Strobe
        }
        if (play) {
            if (useMMC) mmc(dev, 0x02);
            if (useRT) realtime(0xFB);    // Continue(現在位置から。頭からは Return to Start と併用)
        }
    }

    void flushNoteOffs(int ch)
    {
        const double t = now();
        for (size_t i = 0; i < myNoteOff.size();) {
            if (t >= myNoteOff[i].at) {
                noteOff(ch, myNoteOff[i].note);
                myNoteOff.erase(myNoteOff.begin() + i);
            } else i++;
        }
    }

    // 入力 CHOP: `note<n>` は 0→非0 で Note On / 非0→0 で Note Off、
    // `cc<n>` は値が変わったときだけ Control Change を送る(毎フレーム垂れ流さない)
    void handleInput(const OP_Inputs* in, int ch)
    {
        const OP_CHOPInput* c = in->getInputCHOP(0);
        if (!c || c->numSamples < 1) { myLast.clear(); return; }
        if ((int)myLast.size() != c->numChannels) myLast.assign(c->numChannels, -1.0f);
        for (int i = 0; i < c->numChannels; i++) {
            const char* nm = c->getChannelName(i);
            const float v = c->channelData[i][c->numSamples - 1];
            const float prev = myLast[i];
            myLast[i] = v;
            if (prev < 0) continue;                       // 初回は基準を取るだけ
            if (!strncmp(nm, "note", 4)) {
                const int note = atoi(nm + 4);
                if (prev <= 0 && v > 0) noteOn(ch, note, (int)(v <= 1.0f ? v * 127.0f : v));
                else if (prev > 0 && v <= 0) noteOff(ch, note);
            } else if (!strncmp(nm, "cc", 2)) {
                const int cc = atoi(nm + 2);
                const int a = (int)(prev <= 1.0f ? prev * 127.0f : prev);
                const int b = (int)(v <= 1.0f ? v * 127.0f : v);
                if (a != b) controlChange(ch, cc, b);
            }
        }
    }

    static double now()
    {
        using namespace std::chrono;
        return duration<double>(steady_clock::now().time_since_epoch()).count();
    }

    struct PendingOff { int note; double at; };

    std::thread myThread;
    CFRunLoopRef myLoop = nullptr;
    MIDIClientRef myClient = 0;
    MIDIPortRef myPort = 0;
    MIDIEndpointRef myDest = 0;
    SInt32 myBoundUID = 0;
    bool myOnline = false;

    std::mutex myMutex;
    std::vector<Device> myDevices;
    std::vector<PendingOff> myNoteOff;
    std::vector<float> myLast;

    std::atomic<bool> myQuit{false}, myReady{false}, mySetupChanged{false}, myRefresh{false};
    std::atomic<bool> myPendingNote{false}, myPendingCC{false}, myPendingPanic{false};
    std::atomic<bool> myPendingPlay{false}, myPendingStop{false}, myPendingRec{false}, myPendingRewind{false};
    std::atomic<uint64_t> myExec{0}, mySends{0};
};

} // namespace

extern "C" {

DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    OP_CustomOPInfo& x = info->customOPInfo;
    x.opType->setString("Coremidiout");
    x.opLabel->setString("CoreMIDI Out");
    x.opIcon->setString("CMO");
    x.authorName->setString("SYGNAL Inc.");
    x.authorEmail->setString("info@sygnal.tokyo");
    x.minInputs = 0;
    x.maxInputs = 1;
    x.majorVersion = 0;
    x.minorVersion = 9;
    if (x.opHelpURL)
        x.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/CoreMIDI/README.md");
}

DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new CoreMIDIOutCHOP(info);
}

DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (CoreMIDIOutCHOP*)instance;
}

}
