// MultipeerDatBridge.h — Multipeer In/Out DAT 共有の ObjC ブリッジ(テキスト送受信)
//
// 同じ Service Type のピアを自動発見・自動接続し、UTF-8 テキストを送受信する。
// In/Out はそれぞれ別バンドル(別 .plugin)としてこのヘッダを1回だけ include するため、
// @implementation をヘッダに置いても重複シンボルにはならない。

#import <Foundation/Foundation.h>
#import <MultipeerConnectivity/MultipeerConnectivity.h>

#include <deque>
#include <mutex>
#include <string>
#include <vector>

namespace tdmp {
inline std::string nsstr(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }
struct Msg
{
    std::string peer, text;
};
}

@interface TDMultipeerDatBridge
    : NSObject <MCSessionDelegate, MCNearbyServiceAdvertiserDelegate,
                MCNearbyServiceBrowserDelegate>
@property(nonatomic, strong) MCPeerID* peerID;
@property(nonatomic, strong) MCSession* session;
@property(nonatomic, strong) MCNearbyServiceAdvertiser* advertiser;
@property(nonatomic, strong) MCNearbyServiceBrowser* browser;
- (instancetype)initWithName:(NSString*)name service:(NSString*)service;
- (void)shutdown;
- (bool)sendText:(const std::string&)text;
@end

@implementation TDMultipeerDatBridge {
  @public
    std::mutex lock;
    std::deque<tdmp::Msg> received;
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
        peers.push_back(tdmp::nsstr(p.displayName));
}

- (bool)sendText:(const std::string&)text
{
    if (_session.connectedPeers.count == 0)
        return false;
    NSData* data = [[NSString stringWithUTF8String:text.c_str()]
        dataUsingEncoding:NSUTF8StringEncoding];
    return [_session sendData:data
                      toPeers:_session.connectedPeers
                     withMode:MCSessionSendDataReliable
                        error:nil];
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
    received.push_back({tdmp::nsstr(peer.displayName), tdmp::nsstr(text)});
    while (received.size() > 200)
        received.pop_front();
}
- (void)session:(MCSession*)s didReceiveStream:(NSInputStream*)stream
        withName:(NSString*)name fromPeer:(MCPeerID*)peer {}
- (void)session:(MCSession*)s didStartReceivingResourceWithName:(NSString*)name
        fromPeer:(MCPeerID*)peer withProgress:(NSProgress*)p {}
- (void)session:(MCSession*)s didFinishReceivingResourceWithName:(NSString*)name
        fromPeer:(MCPeerID*)peer atURL:(NSURL*)url withError:(NSError*)e {}

// --- Advertiser: 招待は全て受ける(同一サービス前提の自動メッシュ)
- (void)advertiser:(MCNearbyServiceAdvertiser*)a
    didReceiveInvitationFromPeer:(MCPeerID*)peer
                     withContext:(NSData*)context
               invitationHandler:(void (^)(BOOL, MCSession*))handler
{
    handler(YES, self.session);
}
- (void)advertiser:(MCNearbyServiceAdvertiser*)a didNotStartAdvertisingPeer:(NSError*)e
{
    std::lock_guard<std::mutex> g(lock);
    error = tdmp::nsstr(e.localizedDescription);
}

// --- Browser: 発見したら招待(表示名の辞書順で片方向のみ=二重接続防止)
- (void)browser:(MCNearbyServiceBrowser*)b foundPeer:(MCPeerID*)peer
    withDiscoveryInfo:(NSDictionary*)info
{
    if ([self.peerID.displayName compare:peer.displayName] == NSOrderedAscending)
        [b invitePeer:peer toSession:self.session withContext:nil timeout:15];
}
- (void)browser:(MCNearbyServiceBrowser*)b lostPeer:(MCPeerID*)peer { [self refreshPeers]; }
- (void)browser:(MCNearbyServiceBrowser*)b didNotStartBrowsingForPeers:(NSError*)e
{
    std::lock_guard<std::mutex> g(lock);
    error = tdmp::nsstr(e.localizedDescription);
}
@end
