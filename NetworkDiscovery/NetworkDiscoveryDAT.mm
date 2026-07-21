// Network Discovery DAT — Bonjour(NSNetServiceBrowser)でLAN内のサービスを発見し、
// service_type / name / hostname / ip4 / ip6 / port / txt をテーブル出力する。
//
// Service Types に列挙したタイプ(例 _ssh._tcp, _http._tcp, _osc._udp, _airplay._tcp)を
// 同時にブラウズし、見つかったサービスを resolve して host/IP/port/TXT を得る。
// 会場の機器一覧の可視化・OSC/HTTP機器の自動発見・品質連動演出などに。
//
// NSNetServiceBrowser はランループ駆動なので、TDのcookスレッド任せにせず**専用スレッド+
// 常駐ランループ**でブラウズし、結果は @synchronized スナップショットで cook に渡す。
//
// 注意: Bonjour のブラウズは macOS の**ローカルネットワーク権限**が要る(責任プロセスは
// TouchDesigner 本体)。初回は許可ダイアログが出るまで結果0のことがある。
// Bonjour は「サービスを広告している機器」だけが見える(全端末一覧ではない)。
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <atomic>
#include <string>
#include <vector>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

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

namespace {

class NetworkDiscoveryDAT final : public DAT_CPlusPlusBase
{
public:
    explicit NetworkDiscoveryDAT(const OP_NodeInfo*)
    {
        myBrowser = [[NDBrowser alloc] init];
    }
    ~NetworkDiscoveryDAT() override
    {
        @autoreleasepool {
            [myBrowser shutdown];
            myBrowser = nil;
        }
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
            const bool active = inputs->getParInt("Active") != 0;
            std::string types = inputs->getParString("Servicetypes")
                                    ? inputs->getParString("Servicetypes") : "";
            std::string domain = inputs->getParString("Domain")
                                     ? inputs->getParString("Domain") : "local.";
            myBrowser.timeout = inputs->getParDouble("Resolvetimeout");

            std::string sig = (active ? "1|" : "0|") + types + "|" + domain;
            if (myRestart) {
                myRestart = false;
                mySig.clear();
            }
            if (sig != mySig) {
                mySig = sig;
                NSMutableArray* list = [NSMutableArray array];
                if (active)
                    splitTypes(types, list);
                [myBrowser configure:@{
                    @"types" : list,
                    @"domain" : [NSString stringWithUTF8String:domain.c_str()],
                }];
            }

            NSArray<NSDictionary*>* snap = [myBrowser currentSnapshot];
            myCount = (int)snap.count;
            myResolved = 0;
            for (NSDictionary* d in snap)
                if ([d[@"host"] length] > 0)
                    myResolved++;

            const char* keys[7] = {"type", "name", "host", "ip4", "ip6", "port", "txt"};
            const char* hdr[7] = {"service_type", "name", "hostname",
                                  "ip4", "ip6", "port", "txt"};
            output->setOutputDataType(DAT_OutDataType::Table);
            output->setTableSize((int)snap.count + 1, 7);
            for (int c = 0; c < 7; c++)
                output->setCellString(0, c, hdr[c]);
            int row = 1;
            for (NSDictionary* d in snap) {
                for (int c = 0; c < 7; c++) {
                    NSString* v = d[[NSString stringWithUTF8String:keys[c]]];
                    output->setCellString(row, c, v ? (v.UTF8String ?: "") : "");
                }
                row++;
            }
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "Network Discovery";
        {
            OP_NumericParameter p("Active");
            p.label = "Active";
            p.page = P;
            p.defaultValues[0] = 1;
            m->appendToggle(p);
        }
        {
            OP_StringParameter p("Servicetypes");
            p.label = "Service Types";
            p.page = P;
            p.defaultValue = "_ssh._tcp,_http._tcp,_osc._udp,_airplay._tcp";
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
        {
            OP_NumericParameter p("Restart");
            p.label = "Restart";
            p.page = P;
            m->appendPulse(p);
        }
    }

    void pulsePressed(const char* name, void*) override
    {
        if (strcmp(name, "Restart") == 0)
            myRestart = true;
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        const char* n[3] = {"executes", "services", "resolved"};
        float v[3] = {(float)myExec.load(), (float)myCount, (float)myResolved};
        c->name->setString(n[i]);
        c->value = v[i];
    }

    void getWarningString(OP_String* s, void*) override
    {
        if (myCount == 0)
            s->setString("No Bonjour services found yet (needs macOS Local Network "
                         "permission for TouchDesigner; only advertised services are visible).");
    }

private:
    static void splitTypes(const std::string& types, NSMutableArray* out)
    {
        std::string cur;
        auto flush = [&] {
            size_t a = cur.find_first_not_of(" \t");
            size_t b = cur.find_last_not_of(" \t");
            if (a != std::string::npos)
                [out addObject:[NSString stringWithUTF8String:
                                            cur.substr(a, b - a + 1).c_str()]];
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
    std::string mySig;
    bool myRestart = false;
    int myCount = 0, myResolved = 0;
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
