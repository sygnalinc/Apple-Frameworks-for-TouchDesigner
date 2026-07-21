// Semantic Index DAT — macOS の Spotlight ローカル索引を NSMetadataQuery で検索し、結果(名前/パス/
// 種別/更新日時)をテーブル出力する。名前検索・内容検索・自然文(kMDItem*)クエリに対応。
// 検索は専用スレッドの run loop で非同期実行し、cook は最新結果をスナップショットするだけ(非ブロック)。
// 注: CoreSpotlight の CSUserQuery はアプリ自身の索引/エンタイトルメントが要り、プラグイン文脈では
// 0件になるため、OS全体のファイル索引を返す NSMetadataQuery を使う。
#import <Foundation/Foundation.h>
#include <string>
#include <vector>
#include <atomic>
#include <mutex>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

@interface TDSpotlightRunner : NSObject
@property (nonatomic, strong) NSMetadataQuery* query;
@property (nonatomic, copy) void(^onDone)(NSArray*);
@end
@implementation TDSpotlightRunner
- (void)finished:(NSNotification*)n {
    [self.query disableUpdates];
    NSMutableArray* rows=[NSMutableArray array];
    NSUInteger cnt=self.query.resultCount;
    for (NSUInteger i=0;i<cnt;i++){
        NSMetadataItem* it=[self.query resultAtIndex:i];
        NSString* nm=[it valueForAttribute:@"kMDItemDisplayName"]?:@"";
        NSString* pth=[it valueForAttribute:@"kMDItemPath"]?:@"";
        NSString* kind=[it valueForAttribute:@"kMDItemKind"]?:@"";
        NSDate* dt=[it valueForAttribute:@"kMDItemContentModificationDate"];
        NSString* ds=dt?[NSString stringWithFormat:@"%.0f",dt.timeIntervalSince1970]:@"";
        [rows addObject:@[nm,pth,kind,ds]];
    }
    if (self.onDone) self.onDone(rows);
}
@end

namespace {
class SpotlightDAT final : public DAT_CPlusPlusBase {
public:
    SpotlightDAT(const OP_NodeInfo*) {}
    ~SpotlightDAT() override { stop(); }
    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; }

    void execute(DAT_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        std::string q = in->getParString("Query") ? in->getParString("Query") : "";
        std::string mode = in->getParString("Mode") ? in->getParString("Mode") : "Name";
        int maxr = (int)in->getParInt("Maxresults");
        bool go = myGoReq.exchange(false);
        std::string sig=q+"|"+mode+"|"+std::to_string(maxr);
        if (sig!=mySig) { mySig=sig; go=true; }
        if (go && !q.empty()) startSearch(q, mode, maxr);

        out->setOutputDataType(DAT_OutDataType::Table);
        std::vector<std::array<std::string,4>> rows;
        { std::lock_guard<std::mutex> l(myMutex); rows=myRows; }
        out->setTableSize((int)rows.size()+1, 4);
        const char* hdr[]={"name","path","kind","modified"};
        for (int j=0;j<4;j++) out->setCellString(0,j,hdr[j]);
        for (int i=0;i<(int)rows.size();i++) for(int j=0;j<4;j++) out->setCellString(i+1,j,rows[i][j].c_str());
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="Spotlight";
        { OP_StringParameter p("Query"); p.label="Query"; p.page=P; m->appendString(p); }
        { OP_StringParameter p("Mode"); p.label="Mode"; p.page=P; p.defaultValue="Name";
          const char* n[]={"Name","Content","Raw"}; const char* l[]={"Name contains","Content (full text)","Raw kMDItem predicate"};
          m->appendMenu(p,3,n,l); }
        { OP_NumericParameter p("Maxresults"); p.label="Max Results"; p.page=P; p.defaultValues[0]=100; p.minSliders[0]=1; p.maxSliders[0]=1000; p.minValues[0]=1; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Search"); p.label="Search"; p.page=P; m->appendPulse(p); }
    }
    void pulsePressed(const char* name, void*) override { if(strcmp(name,"Search")==0) myGoReq=true; }

    int32_t getNumInfoCHOPChans(void*) override { return 2; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","results"}; float v[]={(float)myExec.load(),(float)myCount.load()};
        c->name->setString(n[i]); c->value=v[i];
    }

private:
    void stop() {
        @autoreleasepool {
            if (myQuery) { [myQuery stopQuery]; }
            if (myObs) { [[NSNotificationCenter defaultCenter] removeObserver:myObs]; myObs=nil; }
            myQuery=nil; myRunner=nil;
        }
    }
    void startSearch(const std::string& q, const std::string& mode, int maxr) {
        @autoreleasepool {
            stop();
            NSString* qs=[NSString stringWithUTF8String:q.c_str()];
            NSPredicate* pred;
            if (mode=="Content") pred=[NSPredicate predicateWithFormat:@"kMDItemTextContent CONTAINS[cd] %@", qs];
            else if (mode=="Raw") pred=[NSPredicate predicateWithFormat:qs];
            else pred=[NSPredicate predicateWithFormat:@"kMDItemDisplayName LIKE[cd] %@", [NSString stringWithFormat:@"*%@*",qs]];
            NSMetadataQuery* mq=[[NSMetadataQuery alloc] init];
            mq.predicate=pred; mq.searchScopes=@[NSMetadataQueryLocalComputerScope];
            mq.sortDescriptors=@[[NSSortDescriptor sortDescriptorWithKey:@"kMDItemContentModificationDate" ascending:NO]];
            myQuery=mq;
            __block SpotlightDAT* self_=this; int cap=maxr;
            myObs=[[NSNotificationCenter defaultCenter] addObserverForName:NSMetadataQueryDidFinishGatheringNotification object:mq queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* n){
                [mq disableUpdates];
                std::vector<std::array<std::string,4>> rows;
                NSUInteger cnt=mq.resultCount; int lim=(int)cnt<cap?(int)cnt:cap;
                for (int i=0;i<lim;i++){
                    NSMetadataItem* it=[mq resultAtIndex:i];
                    NSString* nm=[it valueForAttribute:@"kMDItemDisplayName"]?:@"";
                    NSString* pth=[it valueForAttribute:@"kMDItemPath"]?:@"";
                    NSString* kind=[it valueForAttribute:@"kMDItemKind"]?:@"";
                    NSDate* dt=[it valueForAttribute:@"kMDItemContentModificationDate"];
                    NSString* ds=dt?[NSString stringWithFormat:@"%.0f",dt.timeIntervalSince1970]:@"";
                    rows.push_back({std::string(nm.UTF8String),std::string(pth.UTF8String),std::string(kind.UTF8String),std::string(ds.UTF8String)});
                }
                { std::lock_guard<std::mutex> l(self_->myMutex); self_->myRows=rows; }
                self_->myCount.store((uint64_t)rows.size());
                [mq enableUpdates];
            }];
            // startQuery は run loop のあるスレッド(メイン)で呼ぶ必要がある。TDのcookスレッドから
            // 直接呼ぶと通知が発火しないため、メインキューへdispatchする(TDがメインループをpump)。
            dispatch_async(dispatch_get_main_queue(), ^{ [mq startQuery]; });
        }
    }
    NSMetadataQuery* myQuery=nil; id myObs=nil; TDSpotlightRunner* myRunner=nil;
    std::mutex myMutex; std::vector<std::array<std::string,4>> myRows;
    std::string mySig; std::atomic<bool> myGoReq{false}; std::atomic<uint64_t> myExec{0}, myCount{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* i) {
    if (!i->setAPIVersion(DATCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Spotlight");
    i->customOPInfo.opLabel->setString("Spotlight");
    i->customOPInfo.opIcon->setString("SIX");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/Spotlight/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* i) { return new SpotlightDAT(i); }
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* i) { delete static_cast<SpotlightDAT*>(i); }
}
