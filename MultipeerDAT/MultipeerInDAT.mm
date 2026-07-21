// Multipeer In DAT — TouchDesigner カスタムオペレータ(macOS / MultipeerConnectivity)
//
// **Mac/iPhone/iPad 間ローカルP2Pテキストの受信側**。同じ Service Type のピアを
// 自動発見・自動接続し、受信テキストを出力テーブルに並べる。
// 対になる送信側は Multipeer Out DAT。数値(センサー)版は Multipeer In/Out CHOP。
//
// 出力テーブル: type(peer=接続中ピア / msg=受信メッセージ)/ peer / message
//
// 実装: delegate はロックで保護して cook から読む。cook はブロックしない。

#include <atomic>
#include <string>
#include <vector>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include "MultipeerDatBridge.h"

using namespace TD;

namespace {

class MultipeerInDAT final : public DAT_CPlusPlusBase
{
public:
    explicit MultipeerInDAT(const OP_NodeInfo*) {}

    ~MultipeerInDAT() override
    {
        if (myBridge)
            [myBridge shutdown];
        myBridge = nil;
    }

    void getGeneralInfo(DAT_GeneralInfo* ginfo, const OP_Inputs*, void*) override
    {
        ginfo->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        const bool active = inputs->getParInt("Active") != 0;
        const int maxMsgs = (int)inputs->getParInt("Maxmessages");
        std::string name, service;
        if (const char* n = inputs->getParString("Peername"))
            name = n;
        if (const char* s = inputs->getParString("Servicetype"))
            service = s;
        if (name.empty())
            name = "td-peer";

        if (active && (!myBridge || name != myName || service != myService)) {
            if (myBridge)
                [myBridge shutdown];
            myName = name;
            myService = service;
            myBridge = [[TDMultipeerDatBridge alloc]
                initWithName:[NSString stringWithUTF8String:name.c_str()]
                     service:[NSString stringWithUTF8String:service.c_str()]];
        } else if (!active && myBridge) {
            [myBridge shutdown];
            myBridge = nil;
        }

        std::vector<std::string> peers;
        std::vector<tdmp::Msg> msgs;
        std::string error;
        if (myBridge) {
            std::lock_guard<std::mutex> g(myBridge->lock);
            peers = myBridge->peers;
            const int n = std::min((int)myBridge->received.size(), maxMsgs);
            for (int i = (int)myBridge->received.size() - n;
                 i < (int)myBridge->received.size(); i++)
                msgs.push_back(myBridge->received[i]);
            error = myBridge->error;
        }
        myPeerCount = (int)peers.size();
        myError = error;

        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize((int32_t)(1 + peers.size() + msgs.size()), 3);
        output->setCellString(0, 0, "type");
        output->setCellString(0, 1, "peer");
        output->setCellString(0, 2, "message");
        int row = 1;
        for (auto& p : peers) {
            output->setCellString(row, 0, "peer");
            output->setCellString(row, 1, p.c_str());
            output->setCellString(row, 2, "");
            row++;
        }
        for (auto& m : msgs) {
            output->setCellString(row, 0, "msg");
            output->setCellString(row, 1, m.peer.c_str());
            output->setCellString(row, 2, m.text.c_str());
            row++;
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
            // Bonjourサービス名の制約: 1〜15文字・英小文字数字とハイフン
            OP_StringParameter p("Servicetype");
            p.label = "Service Type";
            p.page = "Multipeer In";
            p.defaultValue = "td-appleml";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Maxmessages");
            p.label = "Max Messages";
            p.page = "Multipeer In";
            p.defaultValues[0] = 20;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 100;
            p.minValues[0] = 1;
            p.maxValues[0] = 200;
            p.clampMins[0] = true;
            p.clampMaxes[0] = true;
            manager->appendInt(p);
        }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 2; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[2] = {"executes", "peers"};
        float values[2] = {(float)myExecCount, (float)myPeerCount};
        chan->name->setString(names[index]);
        chan->value = values[index];
    }

    void getWarningString(OP_String* warning, void*) override
    {
        if (!myError.empty())
            warning->setString(myError.c_str());
        else if (myPeerCount == 0)
            warning->setString("No peers connected (same Service Type on the "
                               "local network required)");
    }

private:
    TDMultipeerDatBridge* myBridge = nil;
    std::string myName, myService, myError;
    int myPeerCount = 0;
    std::atomic<int> myExecCount{0};
};

}   // namespace

extern "C" {

DLLEXPORT void
FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Multipeerin");
    info->customOPInfo.opLabel->setString("Multipeer In");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.opIcon->setString("MPI");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/MultipeerDAT/README.md");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new MultipeerInDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete static_cast<MultipeerInDAT*>(instance);
}

}   // extern "C"
