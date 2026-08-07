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
#include <dlfcn.h>
#include <dns_sd.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/if_ether.h>
#include <sys/select.h>
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
#include <unordered_map>
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

struct ScanHost { std::string ip4, mac, dns, mdns, smbName, smbDomain; };

// ---- MACベンダー(OUI)ルックアップ。プラグイン同梱の oui.txt を1回だけ読む ----
// oui.txt: "prefixhex(小文字)\tvendor" 各行。prefix は 24/28/36bit(6/7/9桁)。
static std::unordered_map<std::string, std::string>& ouiMap()
{
    static std::unordered_map<std::string, std::string> m;
    static std::once_flag once;
    std::call_once(once, [] {
        // 自分(このバンドル)の実行ファイルパスから Resources/oui.txt を導く
        Dl_info info;
        std::string path;
        if (dladdr((const void*)&ouiMap, &info) && info.dli_fname) {
            std::string exe = info.dli_fname;   // .../Contents/MacOS/NetworkDiscoveryDAT
            size_t pos = exe.rfind("/MacOS/");
            if (pos != std::string::npos)
                path = exe.substr(0, pos) + "/Resources/oui.txt";
        }
        if (path.empty())
            return;
        FILE* f = fopen(path.c_str(), "rb");
        if (!f)
            return;
        char line[512];
        while (fgets(line, sizeof(line), f)) {
            char* tab = strchr(line, '\t');
            if (!tab)
                continue;
            *tab = 0;
            std::string pfx = line;
            std::string ven = tab + 1;
            while (!ven.empty() && (ven.back() == '\n' || ven.back() == '\r'))
                ven.pop_back();
            if (!pfx.empty() && !ven.empty())
                m.emplace(std::move(pfx), std::move(ven));
        }
        fclose(f);
    });
    return m;
}

// "aa:bb:cc:dd:ee:ff" → ベンダー名(longest-match 36→28→24bit)。不明/ランダム化MACは空。
static std::string vendorForMac(const std::string& mac)
{
    if (mac.empty())
        return "";
    std::string h;
    for (char c : mac)
        if (c != ':')
            h.push_back((char)tolower(c));
    if (h.size() < 6)
        return "";
    auto& m = ouiMap();
    for (int L : {9, 7, 6}) {
        if ((int)h.size() < L)
            continue;
        auto it = m.find(h.substr(0, L));
        if (it != m.end())
            return it->second;
    }
    return "";
}

// ---- mDNS 逆引き(強制マルチキャストの PTR クエリ)。Bonjour非広告の機器の .local 名を得る ----
namespace {
struct PtrCtx { std::string name; bool got = false; };
static void ptrCallback(DNSServiceRef, DNSServiceFlags, uint32_t, DNSServiceErrorType err,
                        const char*, uint16_t rrtype, uint16_t, uint16_t rdlen,
                        const void* rdata, uint32_t, void* ctx)
{
    PtrCtx* c = (PtrCtx*)ctx;
    if (err || rrtype != kDNSServiceType_PTR || !rdata)
        return;
    // PTR rdata = DNS wire-format ドメイン名。単純ラベル列のみ扱う(圧縮ポインタが来たら中断)
    const uint8_t* p = (const uint8_t*)rdata;
    const uint8_t* end = p + rdlen;
    std::string name;
    while (p < end) {
        uint8_t len = *p++;
        if (len == 0)
            break;
        if (len > 63 || p + len > end)
            return;   // 圧縮/不正 → 破棄
        if (!name.empty())
            name += '.';
        name.append((const char*)p, len);
        p += len;
    }
    // 末尾の ".local" は残す(LanScanのmDNS列に合わせ、短縮はしない)
    c->name = name;
    c->got = true;
}
}   // namespace

static std::string mdnsReverse(const std::string& ip, double timeoutSec)
{
    struct in_addr a;
    if (inet_pton(AF_INET, ip.c_str(), &a) != 1)
        return "";
    uint32_t h = ntohl(a.s_addr);
    char rev[64];
    snprintf(rev, sizeof(rev), "%u.%u.%u.%u.in-addr.arpa.", h & 0xff, (h >> 8) & 0xff,
             (h >> 16) & 0xff, (h >> 24) & 0xff);
    DNSServiceRef sd = nullptr;
    PtrCtx ctx;
    if (DNSServiceQueryRecord(&sd, kDNSServiceFlagsForceMulticast, 0, rev,
                              kDNSServiceType_PTR, kDNSServiceClass_IN, ptrCallback,
                              &ctx) != kDNSServiceErr_NoError)
        return "";
    int fd = DNSServiceRefSockFD(sd);
    double deadline = timeoutSec;
    while (!ctx.got && deadline > 0) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval tv;
        double slice = std::min(0.3, deadline);
        tv.tv_sec = (int)slice;
        tv.tv_usec = (int)((slice - tv.tv_sec) * 1e6);
        int r = select(fd + 1, &rfds, nullptr, nullptr, &tv);
        if (r > 0 && FD_ISSET(fd, &rfds))
            DNSServiceProcessResult(sd);
        else if (r == 0)
            deadline -= slice;
        else
            break;
        if (r > 0)
            deadline -= slice;
    }
    DNSServiceRefDeallocate(sd);
    return ctx.name;
}

// ---- NetBIOS Name Service(UDP 137)の Node Status クエリで SMB名/ドメインを得る ----
// Windows/NAS/Samba 機器の コンピュータ名(unique 0x00)と ワークグループ/ドメイン(group 0x00)。
static void nbnsQuery(const std::string& ip, double timeoutSec, std::string& smbName,
                      std::string& smbDomain)
{
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0)
        return;
    unsigned char req[64];
    int n = 0;
    req[n++] = 0x00; req[n++] = 0x00;   // transaction id
    req[n++] = 0x00; req[n++] = 0x00;   // flags(query)
    req[n++] = 0x00; req[n++] = 0x01;   // QDCOUNT=1
    req[n++] = 0x00; req[n++] = 0x00;   // ANCOUNT
    req[n++] = 0x00; req[n++] = 0x00;   // NSCOUNT
    req[n++] = 0x00; req[n++] = 0x00;   // ARCOUNT
    req[n++] = 0x20;                    // QNAME length = 32
    unsigned char nb[16] = {0};
    nb[0] = '*';                        // 特殊名 "*" + null15
    for (int i = 0; i < 16; i++) {      // first-level encoding(各バイト→2ニブル+'A')
        req[n++] = 'A' + ((nb[i] >> 4) & 0xF);
        req[n++] = 'A' + (nb[i] & 0xF);
    }
    req[n++] = 0x00;                    // QNAME terminator
    req[n++] = 0x00; req[n++] = 0x21;   // QTYPE = NBSTAT(0x21)
    req[n++] = 0x00; req[n++] = 0x01;   // QCLASS = IN

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(137);
    if (inet_pton(AF_INET, ip.c_str(), &dst.sin_addr) != 1) {
        close(s);
        return;
    }
    sendto(s, req, n, 0, (struct sockaddr*)&dst, sizeof(dst));

    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(s, &rfds);
    struct timeval tv;
    tv.tv_sec = (int)timeoutSec;
    tv.tv_usec = (int)((timeoutSec - tv.tv_sec) * 1e6);
    if (select(s + 1, &rfds, nullptr, nullptr, &tv) <= 0) {
        close(s);
        return;
    }
    unsigned char buf[1500];
    ssize_t len = recv(s, buf, sizeof(buf), 0);
    close(s);
    if (len < 57)
        return;

    int p = 12;                                  // ヘッダをスキップ
    while (p < len && buf[p] != 0x00)            // 質問名(ラベル列)をスキップ
        p += buf[p] + 1;
    p += 1 + 4;                                  // 0x00 + QTYPE + QCLASS
    if (p + 2 > len)
        return;
    if ((buf[p] & 0xC0) == 0xC0)                 // 応答名(圧縮ポインタ or ラベル列)
        p += 2;
    else {
        while (p < len && buf[p] != 0x00)
            p += buf[p] + 1;
        p += 1;
    }
    p += 8;                                       // TYPE + CLASS + TTL
    if (p + 2 > len)
        return;
    p += 2;                                       // RDLENGTH
    if (p + 1 > len)
        return;
    int numNames = buf[p++];
    for (int i = 0; i < numNames && p + 18 <= len; i++) {
        std::string name((const char*)(buf + p), 15);
        unsigned char suffix = buf[p + 15];
        bool group = (buf[p + 16] & 0x80) != 0;   // flags 上位バイトの GROUP ビット
        p += 18;
        size_t e = name.find_last_not_of(" \t");
        name = (e == std::string::npos) ? "" : name.substr(0, e + 1);
        if (name.empty() || name == "__MSBROWSE__")
            continue;
        if (!group && suffix == 0x00 && smbName.empty())
            smbName = name;                       // unique 0x00 = コンピュータ名
        else if (group && suffix == 0x00 && smbDomain.empty())
            smbDomain = name;                     // group 0x00 = ワークグループ/ドメイン
    }
}

// 逆引き結果を dns / mdns に振り分ける(.local 系は mdns、それ以外は dns)
static void assignRevName(const std::string& name, std::string& dns, std::string& mdns)
{
    if (name.empty())
        return;
    std::string n = name;
    if (!n.empty() && n.back() == '.')
        n.pop_back();   // 末尾ドット除去
    bool isLocal = n.size() >= 6 && n.compare(n.size() - 6, 6, ".local") == 0;
    if (isLocal) {
        if (mdns.empty())
            mdns = n;
    } else {
        if (dns.empty())
            dns = n;
    }
}

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
        assignRevName(host, h.dns, h.mdns);   // gethostname は通常 .local → mdns
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
    void request(const std::string& subnet, double timeout, int maxHosts, bool rdns, bool netbios)
    {
        std::lock_guard<std::mutex> l(myMx);
        mySubnet = subnet;
        myTimeout = timeout;
        myMax = maxHosts;
        myRdns = rdns;
        myNetbios = netbios;
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
            bool rdns, netbios;
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
                netbios = myNetbios;
            }
            std::vector<ScanHost> res = scan(subnet, timeout, maxHosts, rdns, netbios);
            {
                std::lock_guard<std::mutex> l(myMx);
                myResult = std::move(res);
                myBusy = false;
            }
        }
    }

    std::vector<ScanHost> scan(const std::string& subnetStr, double timeout, int maxHosts,
                               bool rdns, bool netbios)
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

        // 逆引き: dns_name = 標準リゾルバ(ユニキャストPTR。ルータ提供名など)、
        //         mdns_name = 強制マルチキャストPTR(.local 名。Bonjour非広告機器も拾う)
        if (rdns) {
            for (ScanHost& h : out) {
                struct sockaddr_in sa;
                memset(&sa, 0, sizeof(sa));
                sa.sin_family = AF_INET;
                inet_pton(AF_INET, h.ip4.c_str(), &sa.sin_addr);
                char host[NI_MAXHOST] = {0};
                if (getnameinfo((struct sockaddr*)&sa, sizeof(sa), host, sizeof(host), nullptr,
                                0, NI_NAMEREQD) == 0)
                    assignRevName(host, h.dns, h.mdns);
                if (h.mdns.empty())
                    assignRevName(mdnsReverse(h.ip4, 1.0), h.dns, h.mdns);
            }
        }
        // NetBIOS(SMB)名/ドメイン
        if (netbios) {
            for (ScanHost& h : out)
                nbnsQuery(h.ip4, 0.6, h.smbName, h.smbDomain);
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
    bool myRdns = true, myNetbios = true;
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
    std::string type, name, dns, mdns, smbName, smbDomain, ip4, ip6, mac, vendor, port, txt, source;
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
            bool netbios = inputs->getParInt("Netbios") != 0;
            char sb[80];
            snprintf(sb, sizeof(sb), "|%s|%.2f|%d|%d|%d", subnet.c_str(), stimeout, maxhosts,
                     rdns ? 1 : 0, netbios ? 1 : 0);
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
                myScanner->request(subnet, stimeout, maxhosts, rdns, netbios);
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
                r.mdns = nsToStd(d[@"host"]);   // Bonjour解決名は .local(mDNS名)
                if (!r.mdns.empty() && r.mdns.back() == '.')
                    r.mdns.pop_back();
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
                    // 既にBonjourで見えている機器 → 全該当行にMAC/名前を補完
                    for (auto it = range.first; it != range.second; ++it) {
                        Row& r = rows[it->second];
                        if (r.mac.empty()) r.mac = h.mac;
                        if (r.dns.empty()) r.dns = h.dns;
                        if (r.mdns.empty()) r.mdns = h.mdns;
                        if (r.smbName.empty()) r.smbName = h.smbName;
                        if (r.smbDomain.empty()) r.smbDomain = h.smbDomain;
                        if (r.source.find("arp") == std::string::npos) r.source += "+arp";
                    }
                } else {
                    Row r;
                    r.ip4 = h.ip4;
                    r.mac = h.mac;
                    r.dns = h.dns;
                    r.mdns = h.mdns;
                    r.smbName = h.smbName;
                    r.smbDomain = h.smbDomain;
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
                        if (r.dns.empty()) r.dns = h.dns;
                        if (r.mdns.empty()) r.mdns = h.mdns;
                        if (r.source.find("self") == std::string::npos) r.source += "+self";
                    }
                } else {
                    Row r;
                    r.ip4 = h.ip4;
                    r.mac = h.mac;
                    r.dns = h.dns;
                    r.mdns = h.mdns;
                    r.source = "self";
                    int idx = (int)rows.size();
                    ipToRows.insert({r.ip4, idx});
                    rows.push_back(std::move(r));
                }
            }

            // MACからベンダー(OUI)を補完
            for (Row& r : rows)
                if (r.vendor.empty() && !r.mac.empty())
                    r.vendor = vendorForMac(r.mac);

            // 実体のない行(IP/MAC/名前が全て空 = 未解決Bonjour等)を除外
            rows.erase(std::remove_if(rows.begin(), rows.end(), [](const Row& r) {
                           return r.ip4.empty() && r.mac.empty() && r.name.empty();
                       }), rows.end());

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
            const char* hdr[13] = {"ip4", "mac", "vendor", "dns_name", "mdns_name",
                                   "smb_name", "smb_domain", "service_type", "name",
                                   "ip6", "port", "txt", "source"};
            output->setOutputDataType(DAT_OutDataType::Table);
            output->setTableSize((int)rows.size() + 1, 13);
            for (int c = 0; c < 13; c++)
                output->setCellString(0, c, hdr[c]);
            int row = 1;
            for (const Row& r : rows) {
                output->setCellString(row, 0, r.ip4.c_str());
                output->setCellString(row, 1, r.mac.c_str());
                output->setCellString(row, 2, r.vendor.c_str());
                output->setCellString(row, 3, r.dns.c_str());
                output->setCellString(row, 4, r.mdns.c_str());
                output->setCellString(row, 5, r.smbName.c_str());
                output->setCellString(row, 6, r.smbDomain.c_str());
                output->setCellString(row, 7, r.type.c_str());
                output->setCellString(row, 8, r.name.c_str());
                output->setCellString(row, 9, r.ip6.c_str());
                output->setCellString(row, 10, r.port.c_str());
                output->setCellString(row, 11, r.txt.c_str());
                output->setCellString(row, 12, r.source.c_str());
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
            OP_NumericParameter p("Netbios");
            p.label = "NetBIOS / SMB Name";
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
    if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/NetworkDiscovery/README.md");
    info->customOPInfo.authorName->setString("SYGNAL Inc.");
    info->customOPInfo.majorVersion = 0;
    info->customOPInfo.minorVersion = 9;
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
