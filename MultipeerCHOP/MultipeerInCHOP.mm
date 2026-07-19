// Multipeer In CHOP — TouchDesigner カスタムオペレータ(macOS / MultipeerConnectivity)
//
// **iPhone/iPad をワイヤレスセンサーにする(受信側)**。同じ Service Type のピア
// (iOS サンプルアプリ等)から名前付き float チャンネルのバイナリパケットを
// 低遅延(unreliable)で毎フレーム受信し、CHOP チャンネルとして動的出力する。
// ジャイロ/加速度/姿勢/タッチなどをそのまま TD のパラメータに使える。
//
// 対になる送信側は Multipeer Out CHOP(TD → ピア)。テキスト版は Multipeer In/Out DAT。
//
// 実装: 受信は delegate(ロック保護)。cook は最新値を読むだけでブロックしない。

#include <atomic>
#include <string>
#include <vector>

#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include "MultipeerChopBridge.h"

using namespace TD;

namespace {

class MultipeerInCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit MultipeerInCHOP(const OP_NodeInfo*) {}

    ~MultipeerInCHOP() override
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
        // 受信済みチャンネルのスナップショットを取り、名前と数を固定
        myNames.clear();
        myVals.clear();
        if (myBridge) {
            std::lock_guard<std::mutex> g(myBridge->lock);
            for (auto& kv : myBridge->values) {
                myNames.push_back(kv.first);
                myVals.push_back(kv.second);
            }
            myPeerCount = myBridge->peerCount;
        }
        // まだ受信が無いときは1chダミー(TDは0ch出力を嫌う)
        info->numChannels = myNames.empty() ? 1 : (int32_t)myNames.size();
        info->numSamples = 1;
        info->startIndex = 0;
        return true;
    }

    void getChannelName(int32_t index, OP_String* name, const OP_Inputs*, void*) override
    {
        if (index < (int32_t)myNames.size())
            name->setString(myNames[index].c_str());
        else
            name->setString("connected");
    }

    void execute(CHOP_Output* output, const OP_Inputs*, void*) override
    {
        myExecCount++;
        if (myNames.empty()) {
            output->channels[0][0] = (myPeerCount > 0) ? 1.0f : 0.0f;
        } else {
            for (int i = 0; i < (int)myNames.size() && i < output->numChannels; i++)
                output->channels[i][0] = myVals[i];
        }
    }

    void setupParameters(OP_ParameterManager* manager, void*) override
    {
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = "Multipeer In";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Peername");
            p.label = "Peer Name";
            p.page = "Multipeer In";
            p.defaultValue = "td-mac";
            manager->appendString(p);
        }
        {
            OP_StringParameter p("Servicetype");
            p.label = "Service Type";
            p.page = "Multipeer In";
            p.defaultValue = "td-sensor";
            manager->appendString(p);
        }
        {
            // 複数台を区別: チャンネル名に "<peer>/" を付ける
            OP_NumericParameter p("Prefixpeer");
            p.label = "Prefix Peer Name";
            p.page = "Multipeer In";
            p.defaultValues[0] = 0;
            manager->appendToggle(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[3] = {"executes", "peers", "channels"};
        float values[3] = {(float)myExecCount, (float)myPeerCount, (float)myNames.size()};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        if (myPeerCount == 0)
            warning->setString("No peers connected (run the iOS sender app with the "
                               "same Service Type on the local network)");
    }

private:
    void ensureBridge(const OP_Inputs* inputs)
    {
        const bool active = inputs->getParInt("Active") != 0;
        const bool prefix = inputs->getParInt("Prefixpeer") != 0;
        std::string name, service;
        if (const char* n = inputs->getParString("Peername"))
            name = n;
        if (const char* s = inputs->getParString("Servicetype"))
            service = s;
        if (name.empty())
            name = "td-mac";

        if (active && (!myBridge || name != myName || service != myService ||
                       prefix != myPrefix)) {
            if (myBridge)
                [myBridge shutdown];
            myName = name;
            myService = service;
            myPrefix = prefix;
            myBridge = [[TDMultipeerChopBridge alloc]
                initWithName:[NSString stringWithUTF8String:name.c_str()]
                     service:[NSString stringWithUTF8String:service.c_str()]
                      prefix:prefix];
        } else if (!active && myBridge) {
            [myBridge shutdown];
            myBridge = nil;
            myPeerCount = 0;
        }
    }

    TDMultipeerChopBridge* myBridge = nil;
    std::string myName, myService;
    bool myPrefix = false;
    std::vector<std::string> myNames;
    std::vector<float> myVals;
    int myPeerCount = 0;
    std::atomic<int> myExecCount{0};
};

}   // namespace

extern "C" {

DLLEXPORT void
FillCHOPPluginInfo(CHOP_PluginInfo* info)
{
    if (!info->setAPIVersion(CHOPCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Multipeerin");
    info->customOPInfo.opLabel->setString("Apple Multipeer In");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("MPI");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT CHOP_CPlusPlusBase*
CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new MultipeerInCHOP(info);
}

DLLEXPORT void
DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (MultipeerInCHOP*)instance;
}

}   // extern "C"
