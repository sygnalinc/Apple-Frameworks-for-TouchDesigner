// Network Discovery DAT — LAN内のデバイス/サービスを発見してテーブル出力する。
//
//  Mode:
//   - Bonjour   : NSNetServiceBrowser で「サービスを広告している機器」を発見(名前/ホスト/ポート/TXT)
//   - Active Scan: サブネットを総当たりして ARP を発火 → ARPテーブルを読み、**応答した全機器を
//                  MAC付き**で列挙(逆引きDNS/mDNSでホスト名も)。Bonjourを広告しない機器も見える
//   - Both      : 両方をマージ(既定)。同一IPはBonjour行にMACを補完し、ARPのみの機器は別行で追加
//
//  出力列: service_type / name / hostname / ip4 / ip6 / mac / port / txt / source
//
//  仕組み(Active Scan):
//   サブネット内の各ホストへ小さなUDPを投げると、カーネルが送信前に ARP 解決を行う。応答した
//   機器だけ ARP エントリが complete(MACあり)になる。sysctl(NET_RT_FLAGS) で ARPテーブルを
//   読めば、ICMP や特権ソケット無しで「LANに居る全機器」を列挙できる。全IPv4探索の高レベル
//   Apple API は無いためこの実装が現実的。IPv6全域スキャンはアドレス空間的に不可。
//
//  注意:
//   - Bonjour も Active Scan も macOS の**ローカルネットワーク権限**が要る(責任プロセスは TD 本体)。
//     初回は許可ダイアログが出るまで結果0のことがある
//   - Active Scan はサブネット全ホストへ1バイトUDPを送る(自分のLANのみ・最小限)。セキュリティ
//     ソフトがポートスキャンとみなす場合がある
//   - スリープ中/別VLAN/ファイアウォール越し/ARPに応答しない機器は見えない。ルータのDHCPリース
//     一覧を取るAPIは標準に無い
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/if_ether.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

// ============================== Bonjour(NDBrowser) ==============================
// 専用スレッドで常駐ランループを回し、Bonjour のブラウズ/リゾルブを行う。
// 結果は snapshot(NSDictionary配列)へ @synchronized で書き、cook 側が読む。
@interface NDBrowser : NSObject <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property (nonatomic, strong) NSThread* thread;
@property (nonatomic, strong) NSMutableArray<NSNetServiceBrowser*>* browsers;  // browserスレッド専用
@property (nonatomic, strong) NSMutableArray<NSNetService*>* services;         // browserスレッド専用
@property (nonatomic, strong) NSArray<NSDictionary*>* snapshot;          // @synchronized(self)
@property (nonatomic, strong) NSDictionary* pendingConfig;               // @synchronized(self)
@property (nonatomic, assign) BOOL hasPending;                           // @synchronized(self)
@property (nonatomic, assign) double timeout;
@property (nonatomic, assign) BOOL running;                             // @synchronized(self)
@end

@implementation NDBrowser
- (instancetype)init
{
    if ((self = [super init])) {
        _browsers = [NSMutableArray array];
        _services = [NSMutableArray array];
        _snapshot = @[];
        _timeout = 5.0;
        _running = YES;
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain)
                                            object:nil];
        _thread.name = @"NetworkDiscoveryBonjour";
        [_thread start];
    }
    return self;
}

- (BOOL)isRunning
{
    @synchronized(self) {
        return self.running;
    }
}

- (void)threadMain
{
    @autoreleasepool {
        // ランループを生かすためのポートを追加(即終了防止・ビジーループ防止)
        [[NSRunLoop currentRunLoop] addPort:[NSMachPort port] forMode:NSRunLoopCommonModes];
        while ([self isRunning] && !NSThread.currentThread.isCancelled) {
            @autoreleasepool {
                [[NSRunLoop currentRunLoop]
                    runMode:NSDefaultRunLoopMode
                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
                // 保留中の設定変更を this スレッドで適用(cross-thread performSelector を避ける)
                NSDictionary* cfg = nil;
                @synchronized(self) {
                    if (self.hasPending) {
                        cfg = self.pendingConfig;
                        self.pendingConfig = nil;
                        self.hasPending = NO;
                    }
                }
                if (cfg)
                    [self applyConfig:cfg];
            }
        }
        [self stopBrowsers];   // browserスレッド上で後始末
    }
}

// cook から呼ぶ(任意スレッド)。設定を保留にするだけ。実適用は browserスレッドが行う。
- (void)configure:(NSDictionary*)config
{
    @synchronized(self) {
        self.pendingConfig = config;
        self.hasPending = YES;
    }
}

// browserスレッド専用: 実際にブラウズを張り直す
- (void)applyConfig:(NSDictionary*)config
{
    [self stopBrowsers];
    NSString* domain = config[@"domain"] ?: @"local.";
    for (NSString* t in (NSArray*)config[@"types"]) {
        if (t.length == 0)
            continue;
        NSNetServiceBrowser* br = [[NSNetServiceBrowser alloc] init];
        [br scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        br.delegate = self;
        [self.browsers addObject:br];
        [br searchForServicesOfType:t inDomain:domain];
    }
    [self rebuildSnapshot];
}

- (void)stopBrowsers
{
    for (NSNetServiceBrowser* b in self.browsers) {
        b.delegate = nil;
        [b stop];
    }
    [self.browsers removeAllObjects];
    for (NSNetService* s in self.services) {
        s.delegate = nil;
        [s stop];
    }
    [self.services removeAllObjects];
}

- (void)shutdown
{
    // browserスレッドがループを抜け、自分で stopBrowsers して終了する
    @synchronized(self) {
        self.running = NO;
    }
}

- (void)netServiceBrowser:(NSNetServiceBrowser*)b didFindService:(NSNetService*)service
               moreComing:(BOOL)more
{
    for (NSNetService* s in self.services)
        if ([s.name isEqualToString:service.name] && [s.type isEqualToString:service.type])
            return;
    service.delegate = self;
    [self.services addObject:service];
    [service resolveWithTimeout:self.timeout];
    if (!more)
        [self rebuildSnapshot];
}
- (void)netServiceBrowser:(NSNetServiceBrowser*)b didRemoveService:(NSNetService*)service
               moreComing:(BOOL)more
{
    NSNetService* found = nil;
    for (NSNetService* s in self.services)
        if ([s.name isEqualToString:service.name] && [s.type isEqualToString:service.type]) {
            found = s;
            break;
        }
    if (found)
        [self.services removeObject:found];
    if (!more)
        [self rebuildSnapshot];
}
- (void)netServiceDidResolveAddress:(NSNetService*)sender { [self rebuildSnapshot]; }
- (void)netService:(NSNetService*)sender didNotResolve:(NSDictionary*)err { [self rebuildSnapshot]; }

- (void)rebuildSnapshot
{
    NSMutableArray<NSDictionary*>* snap = [NSMutableArray array];
    for (NSNetService* s in self.services) {
        NSString* ip4 = @"", *ip6 = @"";
        for (NSData* d in s.addresses) {
            const struct sockaddr* sa = (const struct sockaddr*)d.bytes;
            char buf[INET6_ADDRSTRLEN] = {0};
            if (sa->sa_family == AF_INET && ip4.length == 0) {
                const struct sockaddr_in* s4 = (const struct sockaddr_in*)sa;
                if (inet_ntop(AF_INET, &s4->sin_addr, buf, sizeof(buf)))
                    ip4 = [NSString stringWithUTF8String:buf];
            } else if (sa->sa_family == AF_INET6 && ip6.length == 0) {
                const struct sockaddr_in6* s6 = (const struct sockaddr_in6*)sa;
                if (inet_ntop(AF_INET6, &s6->sin6_addr, buf, sizeof(buf)))
                    ip6 = [NSString stringWithUTF8String:buf];
            }
        }
        NSString* txt = @"";
        if (s.TXTRecordData) {
            NSDictionary<NSString*, NSData*>* td =
                [NSNetService dictionaryFromTXTRecordData:s.TXTRecordData];
            NSMutableArray* parts = [NSMutableArray array];
            for (NSString* k in td) {
                NSString* v = [[NSString alloc] initWithData:td[k]
                                                    encoding:NSUTF8StringEncoding];
                [parts addObject:[NSString stringWithFormat:@"%@=%@", k, v ?: @""]];
            }
            txt = [parts componentsJoinedByString:@"; "];
        }
        [snap addObject:@{
            @"type" : s.type ?: @"",
            @"name" : s.name ?: @"",
            @"host" : s.hostName ?: @"",
            @"port" : s.port > 0 ? @(s.port).stringValue : @"",
            @"ip4" : ip4,
            @"ip6" : ip6,
            @"txt" : txt,
        }];
    }
    @synchronized(self) {
        self.snapshot = snap;
    }
}

- (NSArray<NSDictionary*>*)currentSnapshot
{
    @synchronized(self) {
        return self.snapshot;
    }
}
@end

// ============================== Active IPv4 Scan ==============================
namespace {

struct ScanHost { std::string ip4, mac, hostname; };

// sockaddr の 4byte アライン繰り上げ(route message 内のオフセット計算)
static inline uint32_t roundup4(uint32_t a)
{
    return a > 0 ? (1 + (((a) - 1) | (sizeof(uint32_t) - 1))) : (uint32_t)sizeof(uint32_t);
}

// ARP テーブルを sysctl(CTL_NET, PF_ROUTE, NET_RT_FLAGS) で読む(= `arp -an` 相当)
static std::vector<ScanHost> readArpTable()
{
    std::vector<ScanHost> out;
    int mib[6] = {CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS,
#ifdef RTF_LLINFO
                  RTF_LLINFO
#else
                  0
#endif
    };
    size_t needed = 0;
    if (sysctl(mib, 6, nullptr, &needed, nullptr, 0) < 0 || needed == 0)
        return out;
    std::vector<char> buf(needed);
    if (sysctl(mib, 6, buf.data(), &needed, nullptr, 0) < 0)
        return out;
    char* lim = buf.data() + needed;
    for (char* next = buf.data(); next < lim;) {
        struct rt_msghdr* rtm = (struct rt_msghdr*)next;
        struct sockaddr_inarp* sin = (struct sockaddr_inarp*)(rtm + 1);
        struct sockaddr_dl* sdl =
            (struct sockaddr_dl*)((char*)sin + roundup4(sin->sin_len));
        char ipbuf[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &sin->sin_addr, ipbuf, sizeof(ipbuf));
        ScanHost h;
        h.ip4 = ipbuf;
        if (sdl->sdl_alen == 6) {
            const unsigned char* m = (const unsigned char*)LLADDR(sdl);
            char mac[18];
            snprintf(mac, sizeof(mac), "%02x:%02x:%02x:%02x:%02x:%02x",
                     m[0], m[1], m[2], m[3], m[4], m[5]);
            h.mac = mac;
        }
        if (!h.ip4.empty() && !h.mac.empty())   // complete エントリのみ(= 応答した機器)
            out.push_back(std::move(h));
        next += rtm->rtm_msglen;
    }
    return out;
}

// 自ホストの en* IPv4 サブネットを取得(net/mask/self を host byte order で返す)
static bool autoSubnet(uint32_t& net, uint32_t& mask, uint32_t& self)
{
    struct ifaddrs* ifap = nullptr;
    if (getifaddrs(&ifap) != 0)
        return false;
    bool found = false;
    for (struct ifaddrs* ifa = ifap; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
            continue;
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK))
            continue;
        std::string nm = ifa->ifa_name ? ifa->ifa_name : "";
        if (nm.rfind("en", 0) != 0)   // en0/en1(Ethernet/Wi-Fi)のみ。utun/awdl/llw/bridge は除外
            continue;
        uint32_t a = ntohl(((struct sockaddr_in*)ifa->ifa_addr)->sin_addr.s_addr);
        uint32_t m = ifa->ifa_netmask
                         ? ntohl(((struct sockaddr_in*)ifa->ifa_netmask)->sin_addr.s_addr)
                         : 0xffffff00u;
        net = a & m;
        mask = m;
        self = a;
        found = true;
        break;
    }
    freeifaddrs(ifap);
    return found;
}

// 自機の en* IPv4 アドレス一覧(ip4 / mac / hostname)。「自分のIP」を必ず表に出すため。
static std::vector<ScanHost> localIPv4s()
{
    std::vector<ScanHost> out;
    struct ifaddrs* ifap = nullptr;
    if (getifaddrs(&ifap) != 0)
        return out;
    // まず AF_LINK から interface 名→MAC を集める
    std::map<std::string, std::string> macByIf;
    for (struct ifaddrs* ifa = ifap; ifa; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_LINK) {
            struct sockaddr_dl* sdl = (struct sockaddr_dl*)ifa->ifa_addr;
            if (sdl->sdl_alen == 6 && ifa->ifa_name) {
                const unsigned char* m = (const unsigned char*)LLADDR(sdl);
                char mac[18];
                snprintf(mac, sizeof(mac), "%02x:%02x:%02x:%02x:%02x:%02x",
                         m[0], m[1], m[2], m[3], m[4], m[5]);
                macByIf[ifa->ifa_name] = mac;
            }
        }
    }
    char hn[256] = {0};
    std::string host = (gethostname(hn, sizeof(hn)) == 0) ? hn : "";
    for (struct ifaddrs* ifa = ifap; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET)
            continue;
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK))
            continue;
        std::string nm = ifa->ifa_name ? ifa->ifa_name : "";
        if (nm.rfind("en", 0) != 0)
            continue;
        char buf[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &((struct sockaddr_in*)ifa->ifa_addr)->sin_addr, buf, sizeof(buf));
        ScanHost h;
        h.ip4 = buf;
        h.mac = macByIf.count(nm) ? macByIf[nm] : "";
        h.hostname = host;
        out.push_back(std::move(h));
    }
    freeifaddrs(ifap);
    return out;
}

// "a.b.c.d/nn" を net/mask/self に。self は不明なので 0。失敗で false。
static bool parseCidr(const std::string& s, uint32_t& net, uint32_t& mask, uint32_t& self)
{
    size_t slash = s.find('/');
    std::string ip = slash == std::string::npos ? s : s.substr(0, slash);
    int bits = slash == std::string::npos ? 24 : atoi(s.substr(slash + 1).c_str());
    if (bits < 0 || bits > 32)
        return false;
    struct in_addr a;
    if (inet_pton(AF_INET, ip.c_str(), &a) != 1)
        return false;
    mask = bits == 0 ? 0 : (0xffffffffu << (32 - bits));
    net = ntohl(a.s_addr) & mask;
    self = 0;
    return true;
}

// アクティブスキャナ(専用ワーカースレッド。Rescan/設定変更で一回のスイープを実行)
class ActiveScanner {
public:
    ActiveScanner() { myThread = std::thread([this] { loop(); }); }
    ~ActiveScanner()
    {
        {
            std::lock_guard<std::mutex> l(myMx);
            myQuit = true;
        }
        myCv.notify_all();
        if (myThread.joinable())
            myThread.join();
    }
    void request(const std::string& subnet, double timeout, int maxHosts, bool rdns)
    {
        std::lock_guard<std::mutex> l(myMx);
        mySubnet = subnet;
        myTimeout = timeout;
        myMax = maxHosts;
        myRdns = rdns;
        myPending = true;
        myCv.notify_all();
    }
    std::vector<ScanHost> snapshot()
    {
        std::lock_guard<std::mutex> l(myMx);
        return myResult;
    }
    bool busy()
    {
        std::lock_guard<std::mutex> l(myMx);
        return myBusy;
    }
    int scanned() const { return myScanned.load(); }

private:
    void loop()
    {
        for (;;) {
            std::string subnet;
            double timeout;
            int maxHosts;
            bool rdns;
            {
                std::unique_lock<std::mutex> l(myMx);
                myCv.wait(l, [this] { return myPending || myQuit; });
                if (myQuit)
                    return;
                myBusy = true;
                myPending = false;
                subnet = mySubnet;
                timeout = myTimeout;
                maxHosts = myMax;
                rdns = myRdns;
            }
            std::vector<ScanHost> res = scan(subnet, timeout, maxHosts, rdns);
            {
                std::lock_guard<std::mutex> l(myMx);
                myResult = std::move(res);
                myBusy = false;
            }
        }
    }

    std::vector<ScanHost> scan(const std::string& subnetStr, double timeout, int maxHosts,
                               bool rdns)
    {
        uint32_t net = 0, mask = 0, self = 0;
        bool ok = subnetStr.empty() ? autoSubnet(net, mask, self)
                                    : parseCidr(subnetStr, net, mask, self);
        if (!ok)
            return {};
        uint32_t hostmask = ~mask;                      // ホスト部ビット
        std::vector<uint32_t> hosts;
        for (uint32_t h = 1; h < hostmask; h++) {       // network(0)/broadcast(hostmask) を除外
            hosts.push_back(net | h);
            if ((int)hosts.size() >= maxHosts)
                break;
        }
        myScanned = (int)hosts.size();

        // スイープ: 各ホストへ 1byte UDP を送る → カーネルが ARP 解決(2パス)
        int us = socket(AF_INET, SOCK_DGRAM, 0);
        if (us >= 0) {
            int passes = 2;
            for (int p = 0; p < passes; p++) {
                for (uint32_t hip : hosts) {
                    if (hip == self)
                        continue;
                    struct sockaddr_in d;
                    memset(&d, 0, sizeof(d));
                    d.sin_family = AF_INET;
                    d.sin_port = htons(9);              // discard
                    d.sin_addr.s_addr = htonl(hip);
                    const char z = 0;
                    sendto(us, &z, 1, 0, (struct sockaddr*)&d, sizeof(d));
                }
                double half = std::max(0.2, timeout * 0.5);
                usleep((useconds_t)(half * 1e6));
            }
            close(us);
        }

        // ARP テーブルを読む(サブネット内の complete エントリに絞る)
        std::vector<ScanHost> arp = readArpTable();
        uint32_t bcast = net | hostmask;                // サブネットブロードキャストアドレス
        std::vector<ScanHost> out;
        for (ScanHost& e : arp) {
            struct in_addr a;
            if (inet_pton(AF_INET, e.ip4.c_str(), &a) != 1)
                continue;
            uint32_t iph = ntohl(a.s_addr);
            if ((iph & mask) != net)                    // 対象サブネット外は除外
                continue;
            if (iph == bcast)                           // ブロードキャストアドレス(MAC全ff)は除外
                continue;
            if (e.mac == "ff:ff:ff:ff:ff:ff")           // ブロードキャスト/マルチキャストMACは除外
                continue;
            out.push_back(std::move(e));
        }

        // 逆引き(DNS/mDNS)。LANの Apple 機器は .local 名が返る。ワーカースレッドなので block 可
        if (rdns) {
            for (ScanHost& h : out) {
                struct sockaddr_in sa;
                memset(&sa, 0, sizeof(sa));
                sa.sin_family = AF_INET;
                inet_pton(AF_INET, h.ip4.c_str(), &sa.sin_addr);
                char host[NI_MAXHOST] = {0};
                if (getnameinfo((struct sockaddr*)&sa, sizeof(sa), host, sizeof(host), nullptr,
                                0, NI_NAMEREQD) == 0)
                    h.hostname = host;
            }
        }
        return out;
    }

    std::thread myThread;
    std::mutex myMx;
    std::condition_variable myCv;
    bool myPending = false, myBusy = false, myQuit = false;
    std::string mySubnet;
    double myTimeout = 2.0;
    int myMax = 1024;
    bool myRdns = true;
    std::vector<ScanHost> myResult;
    std::atomic<int> myScanned{0};
};

// ============================== DAT ==============================

static inline std::string nsToStd(NSString* s) { return s ? std::string(s.UTF8String ?: "") : std::string(); }
static uint32_t ipKey(const std::string& ip)
{
    struct in_addr a;
    return inet_pton(AF_INET, ip.c_str(), &a) == 1 ? ntohl(a.s_addr) : 0xffffffffu;
}

struct Row {
    std::string type, name, host, ip4, ip6, mac, port, txt, source;
};

class NetworkDiscoveryDAT final : public DAT_CPlusPlusBase
{
public:
    explicit NetworkDiscoveryDAT(const OP_NodeInfo*)
    {
        myBrowser = [[NDBrowser alloc] init];
        myScanner = new ActiveScanner();
    }
    ~NetworkDiscoveryDAT() override
    {
        @autoreleasepool {
            [myBrowser shutdown];
            myBrowser = nil;
        }
        delete myScanner;
        myScanner = nullptr;
    }

    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrame = false;
        g->cookEveryFrameIfAsked = true;
    }

    void execute(DAT_Output* output, const OP_Inputs* inputs, void*) override
    {
        myExec++;
        @autoreleasepool {
            std::string mode = inputs->getParString("Mode") ? inputs->getParString("Mode") : "both";
            const bool wantBonjour = (mode == "bonjour" || mode == "both");
            const bool wantScan = (mode == "scan" || mode == "both");

            // --- Bonjour 設定 ---
            std::string types = inputs->getParString("Servicetypes")
                                    ? inputs->getParString("Servicetypes") : "";
            std::string domain = inputs->getParString("Domain")
                                     ? inputs->getParString("Domain") : "local.";
            myBrowser.timeout = inputs->getParDouble("Resolvetimeout");
            std::string bsig = (wantBonjour ? "1|" : "0|") + types + "|" + domain;

            // --- Scan 設定 ---
            std::string subnet = inputs->getParString("Subnet") ? inputs->getParString("Subnet") : "";
            double stimeout = inputs->getParDouble("Scantimeout");
            int maxhosts = std::max(1, (int)inputs->getParInt("Maxhosts"));
            bool rdns = inputs->getParInt("Reversedns") != 0;
            char sb[64];
            snprintf(sb, sizeof(sb), "|%s|%.2f|%d|%d", subnet.c_str(), stimeout, maxhosts, rdns ? 1 : 0);
            std::string ssig = (wantScan ? "1" : "0") + std::string(sb);

            if (myRestart) {
                myRestart = false;
                myBonjourSig.clear();
            }
            if (myRescan) {
                myRescan = false;
                myScanSig.clear();
            }

            // Bonjour: 設定変化でブラウズを張り直す
            if (bsig != myBonjourSig) {
                myBonjourSig = bsig;
                NSMutableArray* list = [NSMutableArray array];
                if (wantBonjour)
                    splitTypes(types, list);
                [myBrowser configure:@{
                    @"types" : list,
                    @"domain" : [NSString stringWithUTF8String:domain.c_str()],
                }];
            }
            // Scan: 設定変化 or 初回 or Rescan で一回スイープを起動(常時スキャンはしない)
            if (wantScan && ssig != myScanSig) {
                myScanSig = ssig;
                myScanner->request(subnet, stimeout, maxhosts, rdns);
            }
            if (!wantScan)
                myScanSig.clear();   // 次に有効化したとき確実に走るよう

            // --- スナップショット取得 ---
            NSArray<NSDictionary*>* bsnap = wantBonjour ? [myBrowser currentSnapshot] : @[];
            std::vector<ScanHost> ssnap = wantScan ? myScanner->snapshot() : std::vector<ScanHost>();

            // --- マージ(Bonjourサービスは各行維持。同一IPにMAC補完。ARPのみの機器は別行追加)---
            std::vector<Row> rows;
            std::multimap<std::string, int> ipToRows;   // ip4 -> 既存行index(Bonjour由来)
            for (NSDictionary* d in bsnap) {
                Row r;
                r.type = nsToStd(d[@"type"]);
                r.name = nsToStd(d[@"name"]);
                r.host = nsToStd(d[@"host"]);
                r.ip4 = nsToStd(d[@"ip4"]);
                r.ip6 = nsToStd(d[@"ip6"]);
                r.port = nsToStd(d[@"port"]);
                r.txt = nsToStd(d[@"txt"]);
                r.source = "bonjour";
                int idx = (int)rows.size();
                rows.push_back(std::move(r));
                if (!rows[idx].ip4.empty())
                    ipToRows.insert({rows[idx].ip4, idx});
            }
            int scanCount = 0;
            for (ScanHost& h : ssnap) {
                scanCount++;
                auto range = ipToRows.equal_range(h.ip4);
                if (range.first != range.second) {
                    // 既にBonjourで見えている機器 → 全該当行にMAC/ホスト名を補完
                    for (auto it = range.first; it != range.second; ++it) {
                        Row& r = rows[it->second];
                        if (r.mac.empty()) r.mac = h.mac;
                        if (r.host.empty()) r.host = h.hostname;
                        if (r.source.find("arp") == std::string::npos) r.source += "+arp";
                    }
                } else {
                    Row r;
                    r.ip4 = h.ip4;
                    r.mac = h.mac;
                    r.host = h.hostname;
                    r.source = "arp";
                    int idx = (int)rows.size();
                    ipToRows.insert({r.ip4, idx});
                    rows.push_back(std::move(r));
                }
            }

            // 自機のIP/MACを必ず表示(Bonjour/ARPで既に出ていれば source に "self" を足す)
            for (ScanHost& h : localIPv4s()) {
                auto range = ipToRows.equal_range(h.ip4);
                if (range.first != range.second) {
                    for (auto it = range.first; it != range.second; ++it) {
                        Row& r = rows[it->second];
                        if (r.mac.empty()) r.mac = h.mac;
                        if (r.host.empty()) r.host = h.hostname;
                        if (r.source.find("self") == std::string::npos) r.source += "+self";
                    }
                } else {
                    Row r;
                    r.ip4 = h.ip4;
                    r.mac = h.mac;
                    r.host = h.hostname;
                    r.source = "self";
                    int idx = (int)rows.size();
                    ipToRows.insert({r.ip4, idx});
                    rows.push_back(std::move(r));
                }
            }

            // ip4 昇順→type でソート(空IPは末尾)
            std::sort(rows.begin(), rows.end(), [](const Row& a, const Row& b) {
                uint32_t ka = a.ip4.empty() ? 0xffffffffu : ipKey(a.ip4);
                uint32_t kb = b.ip4.empty() ? 0xffffffffu : ipKey(b.ip4);
                if (ka != kb) return ka < kb;
                return a.type < b.type;
            });

            myBonjourCount = (int)bsnap.count;
            myScanCount = scanCount;
            myRows = (int)rows.size();

            // --- 出力 ---
            const char* hdr[9] = {"service_type", "name", "hostname", "ip4", "ip6",
                                  "mac", "port", "txt", "source"};
            output->setOutputDataType(DAT_OutDataType::Table);
            output->setTableSize((int)rows.size() + 1, 9);
            for (int c = 0; c < 9; c++)
                output->setCellString(0, c, hdr[c]);
            int row = 1;
            for (const Row& r : rows) {
                output->setCellString(row, 0, r.type.c_str());
                output->setCellString(row, 1, r.name.c_str());
                output->setCellString(row, 2, r.host.c_str());
                output->setCellString(row, 3, r.ip4.c_str());
                output->setCellString(row, 4, r.ip6.c_str());
                output->setCellString(row, 5, r.mac.c_str());
                output->setCellString(row, 6, r.port.c_str());
                output->setCellString(row, 7, r.txt.c_str());
                output->setCellString(row, 8, r.source.c_str());
                row++;
            }
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "Network Discovery";
        {
            OP_StringParameter p("Mode");
            p.label = "Mode";
            p.page = P;
            p.defaultValue = "both";
            const char* n[] = {"bonjour", "scan", "both"};
            const char* l[] = {"Bonjour services", "Active IPv4 scan", "Both"};
            m->appendMenu(p, 3, n, l);
        }
        {
            OP_NumericParameter p("Rescan");
            p.label = "Rescan Now";
            p.page = P;
            m->appendPulse(p);
        }
        // --- Bonjour ---
        {
            OP_StringParameter p("Servicetypes");
            p.label = "Service Types";
            p.page = P;
            p.defaultValue = "_ssh._tcp,_http._tcp,_osc._udp,_airplay._tcp,_raop._tcp,_googlecast._tcp";
            m->appendString(p);
        }
        {
            OP_StringParameter p("Domain");
            p.label = "Domain";
            p.page = P;
            p.defaultValue = "local.";
            m->appendString(p);
        }
        {
            OP_NumericParameter p("Resolvetimeout");
            p.label = "Resolve Timeout (s)";
            p.page = P;
            p.defaultValues[0] = 5.0;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 30;
            m->appendFloat(p);
        }
        // --- Active Scan ---
        {
            OP_StringParameter p("Subnet");
            p.label = "Subnet (blank = auto)";
            p.page = P;
            p.defaultValue = "";
            m->appendString(p);
        }
        {
            OP_NumericParameter p("Scantimeout");
            p.label = "Scan Timeout (s)";
            p.page = P;
            p.defaultValues[0] = 2.0;
            p.minSliders[0] = 1;
            p.maxSliders[0] = 10;
            m->appendFloat(p);
        }
        {
            OP_NumericParameter p("Maxhosts");
            p.label = "Max Hosts";
            p.page = P;
            p.defaultValues[0] = 1024;
            p.minSliders[0] = 16;
            p.maxSliders[0] = 4096;
            p.minValues[0] = 1;
            p.clampMins[0] = true;
            m->appendInt(p);
        }
        {
            OP_NumericParameter p("Reversedns");
            p.label = "Reverse DNS / mDNS";
            p.page = P;
            p.defaultValues[0] = 1;
            m->appendToggle(p);
        }
        {
            OP_NumericParameter p("Restart");
            p.label = "Restart Bonjour";
            p.page = P;
            m->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Restart") == 0)
            myRestart = true;
        else if (strcmp(name, "Rescan") == 0)
            myRescan = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        const char* n[5] = {"executes", "services", "scan_hosts", "rows", "scanning"};
        float v[5] = {(float)myExec.load(), (float)myBonjourCount, (float)myScanCount,
                      (float)myRows, (float)(myScanner && myScanner->busy() ? 1 : 0)};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    void getWarningString(OP_String* s, void*) override
    {
        if (myRows == 0)
            s->setString("No devices found yet. Needs macOS Local Network permission for "
                         "TouchDesigner. Active scan finds ARP-reachable hosts on the local "
                         "subnet; devices that ignore ARP / are on another VLAN are invisible.");
    }

private:
    static void splitTypes(const std::string& types, NSMutableArray* out)
    {
        std::string cur;
        auto flush = [&] {
            size_t a = cur.find_first_not_of(" \t");
            size_t b = cur.find_last_not_of(" \t");
            if (a != std::string::npos)
                [out addObject:[NSString stringWithUTF8String:cur.substr(a, b - a + 1).c_str()]];
            cur.clear();
        };
        for (char ch : types) {
            if (ch == ',' || ch == ';' || ch == '\n' || ch == ' ')
                flush();
            else
                cur.push_back(ch);
        }
        flush();
    }

    NDBrowser* myBrowser = nil;
    ActiveScanner* myScanner = nullptr;
    std::string myBonjourSig, myScanSig;
    bool myRestart = false, myRescan = false;
    int myBonjourCount = 0, myScanCount = 0, myRows = 0;
    std::atomic<int> myExec{0};
};

}   // namespace

extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* info)
{
    if (!info->setAPIVersion(DATCPlusPlusAPIVersion))
        return;
    info->customOPInfo.opType->setString("Networkdiscovery");
    info->customOPInfo.opLabel->setString("Network Discovery");
    info->customOPInfo.opIcon->setString("NWD");
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/NetworkDiscovery/README.md");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.minInputs = 0;
    info->customOPInfo.maxInputs = 0;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* info)
{
    return new NetworkDiscoveryDAT(info);
}
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* instance)
{
    delete static_cast<NetworkDiscoveryDAT*>(instance);
}
}
