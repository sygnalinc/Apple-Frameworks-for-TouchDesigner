// MultipeerChopBridge.h — Multipeer In/Out CHOP 共有の ObjC ブリッジ
// (MultipeerConnectivity のセッション・受信パース・送信をまとめる)
//
// ワイヤープロトコル(リトルエンディアン):
//   "TDMP"(4B) | uint16 count | count×{ uint8 nameLen, name(UTF8), float32 value }
//
// In/Out はそれぞれ別バンドル(別 .plugin)としてこのヘッダを1回だけ include するため、
// @implementation をヘッダに置いても重複シンボルにはならない。

#import <Foundation/Foundation.h>
#import <MultipeerConnectivity/MultipeerConnectivity.h>

#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace tdmp {
inline std::string nsstr(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }
}

@interface TDMultipeerChopBridge
    : NSObject <MCSessionDelegate, MCNearbyServiceAdvertiserDelegate,
                MCNearbyServiceBrowserDelegate>
@property(nonatomic, strong) MCPeerID* peerID;
@property(nonatomic, strong) MCSession* session;
@property(nonatomic, strong) MCNearbyServiceAdvertiser* advertiser;
@property(nonatomic, strong) MCNearbyServiceBrowser* browser;
- (instancetype)initWithName:(NSString*)name service:(NSString*)service prefix:(bool)prefix;
- (void)shutdown;
- (void)sendCount:(uint16_t)count bytes:(const uint8_t*)bytes length:(size_t)length;
@end

@implementation TDMultipeerChopBridge {
  @public
    std::mutex lock;
    std::vector<std::pair<std::string, float>> values;   // 挿入順を保持
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

// TDMP バイナリをパースして values を更新(受信・In で使う)
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
            name = tdmp::nsstr(peer) + "/" + name;
        [self setValue:v forName:name];
    }
}

// TDMP バイナリを全ピアへ低遅延送信(Out で使う)
- (void)sendCount:(uint16_t)count bytes:(const uint8_t*)bytes length:(size_t)length
{
    if (_session.connectedPeers.count == 0)
        return;
    NSData* data = [NSData dataWithBytes:bytes length:length];
    [_session sendData:data
               toPeers:_session.connectedPeers
              withMode:MCSessionSendDataUnreliable
                 error:nil];
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
