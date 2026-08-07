// Multipeer Out DAT — TouchDesigner カスタムオペレータ(macOS / MultipeerConnectivity)
//
// **Mac/iPhone/iPad 間ローカルP2Pテキストの送信側**。入力 DAT の内容(TSV文字列化)を
// 同じ Service Type の全ピアへ送る。内容が変わるたびに自動送信(Auto Send)、
// または Send パルスで手動送信。対になる受信側は Multipeer In DAT。
//
// 出力テーブル: key/value(status / peers / sends の診断)
//
// 実装: delegate はロックで保護して cook から読む。cook はブロックしない。

#include <atomic>
#include <cstring>
#include <string>
#include <vector>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include "MultipeerDatBridge.h"

using namespace TD;

namespace {

class MultipeerOutDAT final : public DAT_CPlusPlusBase
{
public:
    explicit MultipeerOutDAT(const OP_NodeInfo*) {}

    ~MultipeerOutDAT() override
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
            myBridge = [[TDMultipeerDatBridge alloc]
                initWithName:[NSString stringWithUTF8String:name.c_str()]
                     service:[NSString stringWithUTF8String:service.c_str()]];
        } else if (!active && myBridge) {
            [myBridge shutdown];
            myBridge = nil;
        }

        // 入力DATをTSV化し、変化していたら送信(またはSendパルス)
        std::string payload;
        const OP_DATInput* in = inputs->getInputDAT(0);
        if (in && in->numRows > 0 && in->numCols > 0) {
            for (int r = 0; r < in->numRows; r++) {
                for (int c = 0; c < in->numCols; c++) {
                    if (c)
                        payload += "\t";
                    payload += in->getCell(r, c) ? in->getCell(r, c) : "";
                }
                payload += "\n";
            }
        }
        const bool autoSend = inputs->getParInt("Autosend") != 0;
        if (myBridge && !payload.empty() &&
            ((autoSend && payload != myLastSent) || mySendRequested)) {
            if ([myBridge sendText:payload]) {
                myLastSent = payload;
                mySendCount++;
            }
        }
        mySendRequested = false;

        {
            std::lock_guard<std::mutex> g(myBridge ? myBridge->lock : myDummyLock);
            myPeerCount = myBridge ? (int)myBridge->peers.size() : 0;
            myError = myBridge ? myBridge->error : "";
        }

        // 診断テーブル(key/value)
        output->setOutputDataType(DAT_OutDataType::Table);
        output->setTableSize(4, 2);
        output->setCellString(0, 0, "key");
        output->setCellString(0, 1, "value");
        char buf[32];
        output->setCellString(1, 0, "status");
        output->setCellString(1, 1, myError.empty() ? "ok" : myError.c_str());
        snprintf(buf, sizeof(buf), "%d", myPeerCount);
        output->setCellString(2, 0, "peers");
        output->setCellString(2, 1, buf);
        snprintf(buf, sizeof(buf), "%d", (int)mySendCount);
        output->setCellString(3, 0, "sends");
        output->setCellString(3, 1, buf);
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
            p.defaultValue = "td-appleml";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Autosend");
            p.label = "Auto Send On Change";
            p.page = "Multipeer Out";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Send");
            p.label = "Send";
            p.page = "Multipeer Out";
            manager->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Send") == 0)
            mySendRequested = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t index, OP_InfoCHOPChan* chan, void*) override
    {
        const char* names[3] = {"executes", "peers", "sends"};
        float values[3] = {(float)myExecCount, (float)myPeerCount, (float)mySendCount};
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
    std::mutex myDummyLock;
    std::string myName, myService, myLastSent, myError;
    bool mySendRequested = false;
    int myPeerCount = 0;
    std::atomic<int> myExecCount{0}, mySendCount{0};
};

}   // namespace

extern "C" {

DLLEXPORT void
FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Multipeerout");
    info->customOPInfo.opLabel->setString("Multipeer Out");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
    info->customOPInfo.opIcon->setString("MPO");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/MultipeerDAT/README.md");
    info->customOPInfo.minInputs = 1;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new MultipeerOutDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete static_cast<MultipeerOutDAT*>(instance);
}

}   // extern "C"
