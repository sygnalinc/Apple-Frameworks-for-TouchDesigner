// Multipeer CHOP — TouchDesigner カスタムオペレータ(macOS / MultipeerConnectivity)
//
// **iPhone/iPad をワイヤレスセンサーにする**。同じ Service Type のピア(iOS サンプルアプリ
// 等)から、名前付き float チャンネルのバイナリパケットを**低遅延(unreliable)で毎フレーム
// 受信**し、CHOP チャンネルとして出力する。ジャイロ/加速度/姿勢/タッチなどを
// そのまま TD のパラメータに使える。テキスト用の Multipeer DAT の CHOP(数値)版。
//
// ワイヤープロトコル(リトルエンディアン):
//   "TDMP"(4B) | uint16 count | count×{ uint8 nameLen, name(UTF8), float32 value }
//   ※ 送信元名でプレフィックスするオプション(複数台を区別)あり
//
// 送信: 入力 CHOP がある場合、その各チャンネルを毎フレーム全ピアへ送る
//       (iPhone を出力先=ハプティクス/表示にも使える)。
//
// 実装: 受信は delegate(ロック保護)。cook は最新値を読むだけでブロックしない。

#import <Foundation/Foundation.h>
#import <MultipeerConnectivity/MultipeerConnectivity.h>

#include <atomic>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"

using namespace TD;

namespace {
static std::string nsstr(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }
}   // namespace

// ------------------------------------------------------------------ delegate bridge

@interface TDMultipeerCHOPBridge
    : NSObject <MCSessionDelegate, MCNearbyServiceAdvertiserDelegate,
                MCNearbyServiceBrowserDelegate>
@property(nonatomic, strong) MCPeerID* peerID;
@property(nonatomic, strong) MCSession* session;
@property(nonatomic, strong) MCNearbyServiceAdvertiser* advertiser;
@property(nonatomic, strong) MCNearbyServiceBrowser* browser;
@end

@implementation TDMultipeerCHOPBridge {
  @public
    std::mutex lock;
    // 挿入順を保つため vector<pair> + 名前→indexの索引
    std::vector<std::pair<std::string, float>> values;
    std::map<std::string, size_t> index;
    int peerCount;
    bool prefixPeer;
}

- (instancetype)initWithName:(NSString*)name service:(NSString*)service prefix:(bool)prefix
{
    self = [super init];
    if (self) {
        peerCount = 0;
        prefixPeer = prefix;
        _peerID = [[MCPeerID alloc] initWithDisplayName:name];
        _session = [[MCSession alloc] initWithPeer:_peerID
                                  securityIdentity:nil
                              encryptionPreference:MCEncryptionNone];
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

- (void)setValue:(float)v forName:(const std::string&)name
{
    auto it = index.find(name);
    if (it == index.end()) {
        index[name] = values.size();
        values.push_back({name, v});
    } else {
        values[it->second].second = v;
    }
}

// TDMP バイナリをパースして values を更新
- (void)parsePacket:(NSData*)data fromPeer:(NSString*)peer
{
    const uint8_t* p = (const uint8_t*)data.bytes;
    NSUInteger len = data.length;
    if (len < 6 || memcmp(p, "TDMP", 4) != 0)
        return;
    NSUInteger off = 4;
    uint16_t count;
    memcpy(&count, p + off, 2);
    off += 2;
    std::lock_guard<std::mutex> g(lock);
    for (uint16_t i = 0; i < count && off < len; i++) {
        const uint8_t nlen = p[off++];
        if (off + nlen + 4 > len)
            break;
        std::string name((const char*)(p + off), nlen);
        off += nlen;
        float v;
        memcpy(&v, p + off, 4);
        off += 4;
        if (prefixPeer)
            name = nsstr(peer) + "/" + name;
        [self setValue:v forName:name];
    }
}

// --- MCSessionDelegate
- (void)session:(MCSession*)s peer:(MCPeerID*)peer didChangeState:(MCSessionState)state
{
    std::lock_guard<std::mutex> g(lock);
    peerCount = (int)s.connectedPeers.count;
}
- (void)session:(MCSession*)s didReceiveData:(NSData*)data fromPeer:(MCPeerID*)peer
{
    [self parsePacket:data fromPeer:peer.displayName];
}
- (void)session:(MCSession*)s didReceiveStream:(NSInputStream*)st withName:(NSString*)n
        fromPeer:(MCPeerID*)peer {}
- (void)session:(MCSession*)s didStartReceivingResourceWithName:(NSString*)n
        fromPeer:(MCPeerID*)peer withProgress:(NSProgress*)pr {}
- (void)session:(MCSession*)s didFinishReceivingResourceWithName:(NSString*)n
        fromPeer:(MCPeerID*)peer atURL:(NSURL*)u withError:(NSError*)e {}

// --- Advertiser
- (void)advertiser:(MCNearbyServiceAdvertiser*)a
    didReceiveInvitationFromPeer:(MCPeerID*)peer
                     withContext:(NSData*)context
               invitationHandler:(void (^)(BOOL, MCSession*))handler
{
    handler(YES, self.session);
}
- (void)advertiser:(MCNearbyServiceAdvertiser*)a didNotStartAdvertisingPeer:(NSError*)e {}

// --- Browser(表示名の辞書順で片方向招待=二重接続防止)
- (void)browser:(MCNearbyServiceBrowser*)b
      foundPeer:(MCPeerID*)peer
    withDiscoveryInfo:(NSDictionary*)info
{
    if ([self.peerID.displayName compare:peer.displayName] == NSOrderedAscending)
        [b invitePeer:peer toSession:self.session withContext:nil timeout:15];
}
- (void)browser:(MCNearbyServiceBrowser*)b lostPeer:(MCPeerID*)peer {}
- (void)browser:(MCNearbyServiceBrowser*)b didNotStartBrowsingForPeers:(NSError*)e {}
@end

// ------------------------------------------------------------------ plugin

namespace {

class MultipeerCHOP : public CHOP_CPlusPlusBase
{
public:
    explicit MultipeerCHOP(const OP_NodeInfo*) {}

    ~MultipeerCHOP() override
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
        if (myNames.empty()) {
            // まだ受信が無いときは1chダミー(TDは0ch出力を嫌う)
            info->numChannels = 1;
        } else {
            info->numChannels = (int32_t)myNames.size();
        }
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

    void execute(CHOP_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExecCount++;
        if (myNames.empty()) {
            output->channels[0][0] = (myPeerCount > 0) ? 1.0f : 0.0f;
        } else {
            for (int i = 0; i < (int)myNames.size() && i < output->numChannels; i++)
                output->channels[i][0] = myVals[i];
        }

        // 入力CHOPがあれば全ピアへ送信(iPhoneを出力先にも使える)
        const OP_CHOPInput* in = inputs->getInputCHOP(0);
        if (myBridge && in && in->numChannels > 0 && in->numSamples > 0 &&
            myBridge.session.connectedPeers.count > 0) {
            sendChannels(in);
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
            OP_StringParameter p("Servicetype");
            p.label = "Service Type";
            p.page = "Multipeer";
            p.defaultValue = "td-sensor";
            manager->appendString(p);
        }
        {
            // 複数台を区別: チャンネル名に "<peer>/" を付ける
            OP_NumericParameter p("Prefixpeer");
            p.label = "Prefix Peer Name";
            p.page = "Multipeer";
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
            myBridge = [[TDMultipeerCHOPBridge alloc]
                initWithName:[NSString stringWithUTF8String:name.c_str()]
                     service:[NSString stringWithUTF8String:service.c_str()]
                      prefix:prefix];
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
            NSData* data = [NSData dataWithBytes:buf.data() length:buf.size()];
            [myBridge.session sendData:data
                               toPeers:myBridge.session.connectedPeers
                              withMode:MCSessionSendDataUnreliable
                                 error:nil];
        }
    }

    TDMultipeerCHOPBridge* myBridge = nil;
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
    info->customOPInfo.opType->setString("Multipeer");
    info->customOPInfo.opLabel->setString("Multipeer");
    info->customOPInfo.authorName->setString("sygnal");
    info->customOPInfo.opIcon->setString("MPS");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 1;
}

DLLEXPORT CHOP_CPlusPlusBase*
CreateCHOPInstance(const OP_NodeInfo* info)
{
    return new MultipeerCHOP(info);
}

DLLEXPORT void
DestroyCHOPInstance(CHOP_CPlusPlusBase* instance)
{
    delete (MultipeerCHOP*)instance;
}

}   // extern "C"
