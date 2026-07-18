// Multipeer DAT — TouchDesigner カスタムオペレータ(macOS / MultipeerConnectivity)
//
// **Mac/iPhone/iPad 間のローカルP2Pメッセージング**。同じ Service Type を名乗るピアを
// 自動発見・自動接続し、テキストを送受信する。マルチマシン展示の同期、iPhoneを
// センサー/リモコン化する用途(iOS側は MultipeerConnectivity の簡単なアプリ/
// Swift Playgroundsで書ける)。Wi-Fi/有線LAN/Bluetoothを自動選択、サーバー不要。
//
// 送信: 入力DATの内容(TSV文字列化)が変わるたびに全ピアへ送信。Send パルスで手動送信も可
// 受信: 出力テーブルに peer / message の履歴(最新 Maxmessages 行)+接続ピア一覧
//
// 実装: delegate はロックで保護して cook から読む。cook はブロックしない。

#import <Foundation/Foundation.h>
#import <MultipeerConnectivity/MultipeerConnectivity.h>

#include <atomic>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {
static std::string nsstr(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }
struct Msg
{
    std::string peer, text;
};
}   // namespace

// ------------------------------------------------------------------ delegate bridge

@interface TDMultipeerBridge
    : NSObject <MCSessionDelegate, MCNearbyServiceAdvertiserDelegate,
                MCNearbyServiceBrowserDelegate>
@property(nonatomic, strong) MCPeerID* peerID;
@property(nonatomic, strong) MCSession* session;
@property(nonatomic, strong) MCNearbyServiceAdvertiser* advertiser;
@property(nonatomic, strong) MCNearbyServiceBrowser* browser;
@end

@implementation TDMultipeerBridge {
  @public
    std::mutex lock;
    std::deque<Msg> received;
    std::vector<std::string> peers;
    std::string error;
}

- (instancetype)initWithName:(NSString*)name service:(NSString*)service
{
    self = [super init];
    if (self) {
        _peerID = [[MCPeerID alloc] initWithDisplayName:name];
        _session = [[MCSession alloc] initWithPeer:_peerID
                                  securityIdentity:nil
                              encryptionPreference:MCEncryptionOptional];
        _session.delegate = self;
        _advertiser = [[MCNearbyServiceAdvertiser alloc] initWithPeer:_peerID
                                                        discoveryInfo:nil
                                                          serviceType:service];
        _advertiser.delegate = self;
        _browser = [[MCNearbyServiceBrowser alloc] initWithPeer:_peerID
                                                    serviceType:service];
        _browser.delegate = self;
        [_advertiser startAdvertisingPeer];
        [_browser startBrowsingForPeers];
    }
    return self;
}

- (void)shutdown
{
    [_advertiser stopAdvertisingPeer];
    [_browser stopBrowsingForPeers];
    [_session disconnect];
}

- (void)refreshPeers
{
    std::lock_guard<std::mutex> g(lock);
    peers.clear();
    for (MCPeerID* p in _session.connectedPeers)
        peers.push_back(nsstr(p.displayName));
}

// --- MCSessionDelegate
- (void)session:(MCSession*)s peer:(MCPeerID*)peer didChangeState:(MCSessionState)state
{
    [self refreshPeers];
}
- (void)session:(MCSession*)s didReceiveData:(NSData*)data fromPeer:(MCPeerID*)peer
{
    NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    std::lock_guard<std::mutex> g(lock);
    received.push_back({nsstr(peer.displayName), nsstr(text)});
    while (received.size() > 200)
        received.pop_front();
}
- (void)session:(MCSession*)s
    didReceiveStream:(NSInputStream*)stream
            withName:(NSString*)name
            fromPeer:(MCPeerID*)peer {}
- (void)session:(MCSession*)s
    didStartReceivingResourceWithName:(NSString*)name
                             fromPeer:(MCPeerID*)peer
                         withProgress:(NSProgress*)p {}
- (void)session:(MCSession*)s
    didFinishReceivingResourceWithName:(NSString*)name
                              fromPeer:(MCPeerID*)peer
                                 atURL:(NSURL*)url
                             withError:(NSError*)e {}

// --- Advertiser: 招待は全て受ける(同一サービス前提の自動メッシュ)
- (void)advertiser:(MCNearbyServiceAdvertiser*)a
    didReceiveInvitationFromPeer:(MCPeerID*)peer
                     withContext:(NSData*)context
               invitationHandler:(void (^)(BOOL, MCSession*))handler
{
    handler(YES, self.session);
}
- (void)advertiser:(MCNearbyServiceAdvertiser*)a
    didNotStartAdvertisingPeer:(NSError*)e
{
    std::lock_guard<std::mutex> g(lock);
    error = nsstr(e.localizedDescription);
}

// --- Browser: 発見したら招待(表示名の辞書順で片方向のみ=二重接続防止)
- (void)browser:(MCNearbyServiceBrowser*)b
      foundPeer:(MCPeerID*)peer
    withDiscoveryInfo:(NSDictionary*)info
{
    if ([self.peerID.displayName compare:peer.displayName] == NSOrderedAscending)
        [b invitePeer:peer toSession:self.session withContext:nil timeout:15];
}
- (void)browser:(MCNearbyServiceBrowser*)b lostPeer:(MCPeerID*)peer
{
    [self refreshPeers];
}
- (void)browser:(MCNearbyServiceBrowser*)b didNotStartBrowsingForPeers:(NSError*)e
{
    std::lock_guard<std::mutex> g(lock);
    error = nsstr(e.localizedDescription);
}
@end

// ------------------------------------------------------------------ plugin

namespace {

class MultipeerDAT final : public DAT_CPlusPlusBase
{
public:
    explicit MultipeerDAT(const OP_NodeInfo*) {}

    ~MultipeerDAT() override
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

        // セッション生成/再生成
        if (active && (!myBridge || name != myName || service != myService)) {
            if (myBridge)
                [myBridge shutdown];
            myName = name;
            myService = service;
            myBridge = [[TDMultipeerBridge alloc]
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
            mySendRequested = false;
            NSData* data = [[NSString stringWithUTF8String:payload.c_str()]
                dataUsingEncoding:NSUTF8StringEncoding];
            NSArray* peers = myBridge.session.connectedPeers;
            if (peers.count > 0 &&
                [myBridge.session sendData:data
                                   toPeers:peers
                                  withMode:MCSessionSendDataReliable
                                     error:nil]) {
                myLastSent = payload;
                mySendCount++;
            }
        } else {
            mySendRequested = false;
        }

        // 出力テーブル: peers + 受信履歴
        std::vector<std::string> peers;
        std::vector<Msg> msgs;
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
            p.page = "Multipeer";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_StringParameter p("Peername");
            p.label = "Peer Name";
            p.page = "Multipeer";
            p.defaultValue = "td-mac";
            manager->appendString(p);
        }
        {
            // Bonjourサービス名の制約: 1〜15文字・英小文字数字とハイフン
            OP_StringParameter p("Servicetype");
            p.label = "Service Type";
            p.page = "Multipeer";
            p.defaultValue = "td-appleml";
            manager->appendString(p);
        }
        {
            OP_NumericParameter p("Autosend");
            p.label = "Auto Send On Change";
            p.page = "Multipeer";
            p.defaultValues[0] = 1;
            manager->appendToggle(p);
        }
        {
            OP_NumericParameter p("Send");
            p.label = "Send";
            p.page = "Multipeer";
            manager->appendPulse(p);
        }
        {
            OP_NumericParameter p("Maxmessages");
            p.label = "Max Messages";
            p.page = "Multipeer";
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
    TDMultipeerBridge* myBridge = nil;
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
    info->customOPInfo.opType->setString("Multipeer");
    info->customOPInfo.opLabel->setString("Multipeer");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("MPC");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT DAT_CPlusPlusBase*
CreateDATInstance(const OP_NodeInfo* info)
{
    return new MultipeerDAT(info);
}

DLLEXPORT void
DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete static_cast<MultipeerDAT*>(instance);
}

}   // extern "C"
