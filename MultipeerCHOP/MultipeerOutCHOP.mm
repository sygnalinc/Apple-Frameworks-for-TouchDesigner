// Multipeer Out CHOP — TouchDesigner カスタムオペレータ(macOS / MultipeerConnectivity)
//
// **TD の CHOP を iPhone/iPad へ送る(送信側)**。入力 CHOP の各チャンネルを名前付きで
// 低遅延(unreliable)パケット化し、同じ Service Type の全ピアへ毎フレーム送信する。
// iPhone をハプティクス/表示などの出力先に使える。
//
// 対になる受信側は Multipeer In CHOP(ピア → TD)。テキスト版は Multipeer In/Out DAT。
//
// 出力: 1ch "connected"(接続ピアがあれば 1)。診断は Info CHOP。

#include <atomic>
#include <cstring>
#include <string>
#include <vector>

#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include "MultipeerChopBridge.h"

using namespace TD;

namespace {

class MultipeerOutCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit MultipeerOutCHOP(const OP_NodeInfo*) {}

    ~MultipeerOutCHOP() override
    {
        if (myBridge)
            [myBridge shutdown];
        myBridge = nil;
    }

    void getGeneralInfo(CHOP_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
        ginfo->timeslice = false;
    }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs* inputs, void*) override
    {
        ensureBridge(inputs);
        info->numChannels = 1;   // "connected"
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t, OP_String* name, const OP_Inputs*, void*) override
    {
        name->setString("connected");
    }

    void execute(CHOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        {
            std::lock_guard<std::mutex> g(myBridge ? myBridge->lock : myDummyLock);
            myPeerCount = myBridge ? myBridge->peerCount : 0;
        }
        output->channels[0][0] = (myPeerCount > 0) ? 1.0f : 0.0f;

        // 入力CHOPの各チャンネルを全ピアへ送信
        const OP_CHOPInput* in = inputs->getInputCHOP(0);
        const bool active = inputs->getParInt("Active") != 0;
        if (active && myBridge && in && in->numChannels > 0 && in->numSamples > 0)
            sendChannels(in);
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Multipeer Out";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Peername");
            p.label = "Peer Name";
            p.page = "Multipeer Out";
            p.defaultValue = "td-mac-out";
            manager->appendString(p);
        }
        {
            OP_StringParameter p("Servicetype");
            p.label = "Service Type";
            p.page = "Multipeer Out";
            p.defaultValue = "td-sensor";
            manager->appendString(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[3] = {"executes", "peers", "sent_chans"};
        float values[3] = {(float)myExecCount, (float)myPeerCount, (float)mySentChans};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        if (myPeerCount == 0)
            warning->setString("No peers connected (start a receiver with the same "
                               "Service Type on the local network)");
    }

private:
    void ensureBridge(const OP_Inputs* inputs)
    {
        const bool active = inputs->getParInt("Active") != 0;
        std::string name, service;
        if (const char* n = inputs->getParString("Peername"))
            name = n;
        if (const char* s = inputs->getParString("Servicetype"))
            service = s;
        if (name.empty())
            name = "td-mac-out";

        if (active && (!myBridge || name != myName || service != myService)) {
            if (myBridge)
                [myBridge shutdown];
            myName = name;
            myService = service;
            myBridge = [[TDMultipeerChopBridge alloc]
                initWithName:[NSString stringWithUTF8String:name.c_str()]
                     service:[NSString stringWithUTF8String:service.c_str()]
                      prefix:false];
        } else if (!active && myBridge) {
            [myBridge shutdown];
            myBridge = nil;
            myPeerCount = 0;
        }
    }

    void sendChannels(const OP_CHOPInput* in)
    {
        @autoreleasepool {
            std::vector<uint8_t> buf;
            buf.insert(buf.end(), {'T', 'D', 'M', 'P'});
            const uint16_t count = (uint16_t)in->numChannels;
            buf.push_back(count & 0xFF);
            buf.push_back((count >> 8) & 0xFF);
            for (int c = 0; c < in->numChannels; c++) {
                const char* nm = in->getChannelName(c);
                std::string s = nm ? nm : "";
                if (s.size() > 255)
                    s.resize(255);
                buf.push_back((uint8_t)s.size());
                buf.insert(buf.end(), s.begin(), s.end());
                float v = in->getChannelData(c)[0];
                uint8_t* vp = (uint8_t*)&v;
                buf.insert(buf.end(), vp, vp + 4);
            }
            [myBridge sendCount:count bytes:buf.data() length:buf.size()];
            mySentChans = count;
        }
    }

    TDMultipeerChopBridge* myBridge = nil;
    std::mutex myDummyLock;
    std::string myName, myService;
    int myPeerCount = 0;
    int mySentChans = 0;
    std::atomic<int> myExecCount{0};
};

}   // namespace

extern "C" {

DLLEXPORT void
FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Multipeerout");
    info->customOPInfo.opLabel->setString("Multipeer Out");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.opIcon->setString("MPO");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/MultipeerCHOP/README.md");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT CHOP_CPlusPlusBase*
CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new MultipeerOutCHOP(info);
}

DLLEXPORT void
DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (MultipeerOutCHOP*)instance;
}

}   // extern "C"
