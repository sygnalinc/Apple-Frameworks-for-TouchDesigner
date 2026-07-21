// WiFi Monitor CHOP — CoreWLAN で現在接続中のWi-Fiインターフェースの RSSI / ノイズ / SNR /
// 送信レート / チャンネル / 送信電力 / PHYモード / セキュリティを数値CHOPとして出力する。
// SSID/BSSID等の文字列は Info DAT で見る。cook は軽量なので同期取得。
#import <Foundation/Foundation.h>
#import <CoreWLAN/CoreWLAN.h>
#include <string>
#include <atomic>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
class CoreWLANCHOP final : public CHOP_CPlusPlusBase {
public:
    CoreWLANCHOP(const OP_NodeInfo*) {}
    ~CoreWLANCHOP() override {}
    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; g->timeslice=false; }
    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override { info->numChannels=9; info->numSamples=1; info->sampleRate=60; return true; }
    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override {
        const char* n[]={"connected","rssi","noise","snr","tx_rate_mbps","tx_power","channel","channel_band","phy_mode"};
        name->setString(n[i]);
    }
    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        @autoreleasepool {
            CWInterface* w = [[CWWiFiClient sharedWiFiClient] interface];
            float rssi=0,noise=0,rate=0,txp=0,ch=0,band=0,phy=0;
            bool connected=false;
            if (w) {
                rssi=(float)[w rssiValue]; noise=(float)[w noiseMeasurement]; rate=(float)[w transmitRate]; txp=(float)[w transmitPower];
                CWChannel* c=[w wlanChannel]; if(c){ ch=(float)c.channelNumber; band=(float)c.channelBand; }
                // SSIDはLocation権限が無いとnil化されるので、チャンネル関連付け(またはrssi)で接続判定
                connected = (c != nil) || (rssi != 0);
                phy=(float)[w activePHYMode];
                myName = w.ssid ? w.ssid.UTF8String : ""; myBssid = w.bssid ? w.bssid.UTF8String : ""; myIface = w.interfaceName ? w.interfaceName.UTF8String : "";
                mySecurity = (int)[w security];
            }
            float snr = rssi - noise;
            float v[]={ connected?1.f:0.f, rssi, noise, snr, rate, txp, ch, band, phy };
            for (int i=0;i<9;i++) out->channels[i][0]=v[i];
            myRssi=rssi; myConnected=connected;
        }
    }
    void setupParameters(OP_ParameterManager*, void*) override {}

    bool getInfoDATSize(OP_InfoDATSize* s, void*) override { s->rows=4; s->cols=2; s->byColumn=false; return true; }
    void getInfoDATEntries(int32_t r, int32_t, OP_InfoDATEntries* e, void*) override {
        const char* keys[]={"ssid","bssid","interface","security"};
        e->values[0]->setString(keys[r]);
        if (r==0) e->values[1]->setString(myName.c_str());
        else if (r==1) e->values[1]->setString(myBssid.c_str());
        else if (r==2) e->values[1]->setString(myIface.c_str());
        else { char b[16]; snprintf(b,sizeof b,"%d",mySecurity); e->values[1]->setString(b); }
    }
    void getWarningString(OP_String* s, void*) override {
        if (!myConnected) s->setString("Not connected to Wi-Fi (or CoreWLAN needs Location permission on recent macOS).");
    }
    int32_t getNumInfoCHOPChans(void*) override { return 2; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","rssi"}; float v[]={(float)myExec.load(),myRssi};
        c->name->setString(n[i]); c->value=v[i];
    }
private:
    std::string myName, myBssid, myIface; int mySecurity=0; float myRssi=0; bool myConnected=false;
    std::atomic<uint64_t> myExec{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Corewlan");
    i->customOPInfo.opLabel->setString("CoreWLAN");
    i->customOPInfo.opIcon->setString("WIF");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new CoreWLANCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<CoreWLANCHOP*>(i); }
}
