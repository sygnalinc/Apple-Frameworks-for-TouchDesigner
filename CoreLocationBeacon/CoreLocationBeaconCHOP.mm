// Beacon CHOP — CoreLocation で iBeacon を測距(ranging)し、各ビーコンの major/minor/rssi/近接度/
// 推定距離を出力する。展示内の近接検出に。CLBeaconIdentityConstraint(UUID+任意のmajor/minor)で対象を絞る。
// 注: Location 権限が必要(TDのInfo.plistに NSLocationUsageDescription が無いと権限取得に失敗しうる)。
// 実ビーコンが必要。
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#include <string>
#include <vector>
#include <atomic>
#include <mutex>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

struct BeaconRow { int major, minor, rssi; double accuracy; int proximity; };
static std::mutex gBMutex;

API_AVAILABLE(macos(10.15))
@interface TDBeaconDelegate : NSObject <CLLocationManagerDelegate>
@property (nonatomic, assign) std::vector<BeaconRow>* rows;
@property (nonatomic, assign) int* authStatus;
@end
@implementation TDBeaconDelegate
- (void)locationManager:(CLLocationManager*)m didRangeBeacons:(NSArray<CLBeacon*>*)beacons satisfyingConstraint:(CLBeaconIdentityConstraint*)c {
    std::lock_guard<std::mutex> l(gBMutex);
    if (!self.rows) return;
    self.rows->clear();
    for (CLBeacon* b in beacons) {
        BeaconRow r; r.major=b.major.intValue; r.minor=b.minor.intValue; r.rssi=(int)b.rssi; r.accuracy=b.accuracy; r.proximity=(int)b.proximity;
        self.rows->push_back(r);
    }
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager*)m {
    if (self.authStatus) *self.authStatus=(int)m.authorizationStatus;
}
@end

namespace {
class CoreLocationBeaconCHOP final : public CHOP_CPlusPlusBase {
public:
    CoreLocationBeaconCHOP(const OP_NodeInfo*) {}
    ~CoreLocationBeaconCHOP() override { stop(); }
    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; g->timeslice=false; }
    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs* in, void*) override {
        myMax=std::max(1,(int)in->getParInt("Maxbeacons"));
        info->numChannels=myMax*6; info->numSamples=1; info->sampleRate=60; return true;
    }
    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override {
        int slot=i/6+1,k=i%6; const char* s[]={"valid","major","minor","rssi","accuracy","proximity"};
        char b[32]; snprintf(b,sizeof b,"beacon%d/%s",slot,s[k]); name->setString(b);
    }
    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        ensure(in);
        for (int c=0;c<out->numChannels;c++) out->channels[c][0]=0;
        std::vector<BeaconRow> rows; { std::lock_guard<std::mutex> l(gBMutex); rows=myRows; }
        int n=std::min((int)rows.size(), myMax);
        for (int i=0;i<n;i++){
            out->channels[i*6+0][0]=1;
            out->channels[i*6+1][0]=(float)rows[i].major;
            out->channels[i*6+2][0]=(float)rows[i].minor;
            out->channels[i*6+3][0]=(float)rows[i].rssi;
            out->channels[i*6+4][0]=(float)rows[i].accuracy;
            out->channels[i*6+5][0]=(float)rows[i].proximity;
        }
        myCount=n;
    }
    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="Corelocationbeacon";
        { OP_NumericParameter p("Active"); p.label="Active"; p.page=P; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_StringParameter p("Uuid"); p.label="Beacon UUID"; p.page=P; p.defaultValue="00000000-0000-0000-0000-000000000000"; m->appendString(p); }
        { OP_NumericParameter p("Major"); p.label="Major (0=any)"; p.page=P; p.defaultValues[0]=0; p.minValues[0]=0; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Minor"); p.label="Minor (0=any)"; p.page=P; p.defaultValues[0]=0; p.minValues[0]=0; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Maxbeacons"); p.label="Max Beacons"; p.page=P; p.defaultValues[0]=10; p.minSliders[0]=1; p.maxSliders[0]=50; p.minValues[0]=1; p.clampMins[0]=true; m->appendInt(p); }
    }
    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","beacons","auth"}; float v[]={(float)myExec.load(),(float)myCount,(float)myAuth};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override {
        if (@available(macos 10.15,*)) { if (myCount==0) s->setString("No beacons ranged. Needs Location permission (NSLocationUsageDescription) + physical iBeacons."); }
        else s->setString("Beacon ranging requires macOS 10.15+.");
    }
private:
    void ensure(const OP_Inputs* in) {
        bool active=in->getParInt("Active")!=0;
        std::string uuid=in->getParString("Uuid")?in->getParString("Uuid"):"";
        int maj=(int)in->getParInt("Major"), mnr=(int)in->getParInt("Minor");
        std::string sig=std::to_string(active)+"|"+uuid+"|"+std::to_string(maj)+"|"+std::to_string(mnr);
        if (sig==mySig) return; mySig=sig; stop();
        if (active) start(uuid,maj,mnr);
    }
    void start(const std::string& uuid, int maj, int mnr) {
        if (@available(macos 10.15,*)) {
            @autoreleasepool {
                NSUUID* u=[[NSUUID alloc] initWithUUIDString:[NSString stringWithUTF8String:uuid.c_str()]];
                if (!u) return;
                if (maj>0 && mnr>0) myConstraint=[[CLBeaconIdentityConstraint alloc] initWithUUID:u major:maj minor:mnr];
                else if (maj>0) myConstraint=[[CLBeaconIdentityConstraint alloc] initWithUUID:u major:maj];
                else myConstraint=[[CLBeaconIdentityConstraint alloc] initWithUUID:u];
                myDelegate=[[TDBeaconDelegate alloc] init]; myDelegate.rows=&myRows; myDelegate.authStatus=&myAuth;
                myMgr=[[CLLocationManager alloc] init]; myMgr.delegate=myDelegate;
                [myMgr requestWhenInUseAuthorization];
                [myMgr startRangingBeaconsSatisfyingConstraint:myConstraint];
            }
        }
    }
    void stop() {
        if (@available(macos 10.15,*)) { @autoreleasepool { if(myMgr && myConstraint) [myMgr stopRangingBeaconsSatisfyingConstraint:myConstraint]; if(myMgr) myMgr.delegate=nil; myMgr=nil; myConstraint=nil; myDelegate.rows=nullptr; myDelegate=nil; } }
        std::lock_guard<std::mutex> l(gBMutex); myRows.clear();
    }
    CLLocationManager* myMgr=nil; TDBeaconDelegate* myDelegate=nil; CLBeaconIdentityConstraint* myConstraint=nil;
    std::vector<BeaconRow> myRows; int myMax=10,myCount=0,myAuth=0; std::string mySig; std::atomic<uint64_t> myExec{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Corelocationbeacon");
    i->customOPInfo.opLabel->setString("CoreLocation Beacon");
    i->customOPInfo.opIcon->setString("BCN");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new CoreLocationBeaconCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<CoreLocationBeaconCHOP*>(i); }
}
