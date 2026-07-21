// Process Audio CHOP — Core Audio Process Tap(macOS 14.4+)で、システム全体または指定プロセス(PID)の
// 音声だけをタップし、CHOPのオーディオとして出力する。SystemAudio(ScreenCaptureKit)より粒度が細かく、
// 「特定アプリの音だけ」を取れる。IOProc(リアルタイムスレッド)→ ロックフリーSPSCリングバッファ →
// timeslice CHOP出力。cook はブロックしない。
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include <string>
#include <vector>
#include <atomic>
#include <cmath>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
static const int kRing = 1<<18; // 262144 frames/ch

class CoreAudioTapCHOP final : public CHOP_CPlusPlusBase {
public:
    CoreAudioTapCHOP(const OP_NodeInfo*) { for(int c=0;c<2;c++) myRing[c].assign(kRing,0.f); }
    ~CoreAudioTapCHOP() override { @autoreleasepool { teardown(); } }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; g->timeslice=true; }
    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override { info->numChannels=2; info->sampleRate=(float)(mySR>0?mySR:48000); return true; }
    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override { name->setString(i==0?"left":"right"); }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        for (int c=0;c<out->numChannels;c++) memset(out->channels[c],0,sizeof(float)*out->numSamples);
        bool active = in->getParInt("Active")!=0;
        std::string mode = in->getParString("Mode") ? in->getParString("Mode") : "Global";
        int pid = (int)in->getParInt("Pid");
        bool excludeSelf = in->getParInt("Excludeself")!=0;
        std::string sig = (active?"1":"0")+mode+"|"+std::to_string(pid)+(excludeSelf?"|x":"");
        if (sig!=mySig) { mySig=sig; if(active) setup(mode,pid,excludeSelf); else teardown(); }
        if (!active || !myRunning || out->numChannels<2) return;

        int n = out->numSamples;
        uint64_t r=myRead.load(std::memory_order_relaxed), w=myWrite.load(std::memory_order_acquire);
        uint64_t avail = w>r ? (w-r) : 0;
        // 消費が遅れてリング容量に近づいたら最新へ追いつく(リング溢れ=データ喪失を防ぎ、常に直近音を出す)
        if (avail > (uint64_t)(kRing - (kRing>>3))) { r = (w>(uint64_t)n)? w-(uint64_t)n : 0; myRead.store(r); avail = w>r?(w-r):0; }
        int give = (int)(avail<(uint64_t)n?avail:(uint64_t)n);
        for (int i=0;i<give;i++){ out->channels[0][i]=myRing[0][(r+i)&(kRing-1)]; out->channels[1][i]=myRing[1][(r+i)&(kRing-1)]; }
        myRead.store(r+give, std::memory_order_release);
        if (give<n) myUnderruns++;
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="CoreAudio Tap";
        { OP_NumericParameter p("Active"); p.label="Active"; p.page=P; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_StringParameter p("Mode"); p.label="Mode"; p.page=P; p.defaultValue="Global";
          const char* n[]={"Global","Process"}; const char* l[]={"Global (all system audio)","Single Process (PID)"};
          m->appendMenu(p,2,n,l); }
        { OP_NumericParameter p("Pid"); p.label="Process PID (Process mode)"; p.page=P; p.defaultValues[0]=0; p.minValues[0]=0; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Excludeself"); p.label="Exclude TouchDesigner (Global)"; p.page=P; p.defaultValues[0]=0; m->appendToggle(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        int64_t buffered=(int64_t)(myWrite.load()-myRead.load());
        const char* n[]={"executes","running","buffered","underruns","samplerate"};
        float v[]={(float)myExec.load(),(float)(myRunning?1:0),(float)buffered,(float)myUnderruns.load(),(float)mySR};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if(!myWarn.empty()) s->setString(myWarn.c_str()); }

private:
    void teardown() {
        if (myProc && myAgg) { AudioDeviceStop(myAgg, myProc); AudioDeviceDestroyIOProcID(myAgg, myProc); }
        if (myAgg) AudioHardwareDestroyAggregateDevice(myAgg);
        if (myTap) AudioHardwareDestroyProcessTap(myTap);
        myProc=nullptr; myAgg=0; myTap=0; myRunning=false; myRead.store(0); myWrite.store(0);
    }
    AudioObjectID processForPID(int pid) {
        AudioObjectPropertyAddress pa={kAudioHardwarePropertyTranslatePIDToProcessObject,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        AudioObjectID obj=0; UInt32 sz=sizeof(obj); pid_t p=(pid_t)pid;
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject,&pa,sizeof(p),&p,&sz,&obj)==noErr) return obj;
        return 0;
    }
    void setup(const std::string& mode, int pid, bool excludeSelf) {
        teardown(); myWarn.clear();
        @autoreleasepool {
            CATapDescription* desc=nil;
            if (mode=="Process" && pid>0) {
                AudioObjectID po=processForPID(pid);
                if (!po){ myWarn="PID not found or not producing audio"; return; }
                desc=[[CATapDescription alloc] initStereoMixdownOfProcesses:@[@(po)]];
            } else {
                NSMutableArray* excl=[NSMutableArray array];
                if (excludeSelf) { AudioObjectID po=processForPID((int)getpid()); if(po) [excl addObject:@(po)]; }
                desc=[[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:excl];
            }
            desc.name=@"TDAppleML Process Audio";
            OSStatus st=AudioHardwareCreateProcessTap(desc,&myTap);
            if (st!=noErr||!myTap){ myWarn="CreateProcessTap failed"; myTap=0; return; }
            CFStringRef tapUID=NULL; UInt32 sz=sizeof(tapUID);
            AudioObjectPropertyAddress pa={kAudioTapPropertyUID,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
            AudioObjectGetPropertyData(myTap,&pa,0,NULL,&sz,&tapUID);
            // tap format(サンプルレート)
            AudioStreamBasicDescription asbd={0}; UInt32 fsz=sizeof(asbd);
            AudioObjectPropertyAddress fa={kAudioTapPropertyFormat,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
            if (AudioObjectGetPropertyData(myTap,&fa,0,NULL,&fsz,&asbd)==noErr) mySR=(int)asbd.mSampleRate;
            NSDictionary* dict=@{ @(kAudioAggregateDeviceUIDKey):[NSString stringWithFormat:@"TDAppleML-agg-%d",(int)getpid()],
                @(kAudioAggregateDeviceIsPrivateKey):@1,
                @(kAudioAggregateDeviceTapListKey):@[@{@(kAudioSubTapUIDKey):(__bridge NSString*)tapUID,@(kAudioSubTapDriftCompensationKey):@1}] };
            st=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)dict,&myAgg);
            if (st!=noErr||!myAgg){ myWarn="CreateAggregateDevice failed"; teardown(); return; }
            __block CoreAudioTapCHOP* self_=this;
            st=AudioDeviceCreateIOProcIDWithBlock(&myProc,myAgg,NULL,^(const AudioTimeStamp* now,const AudioBufferList* in,const AudioTimeStamp* it,AudioBufferList* out,const AudioTimeStamp* ot){
                if (!in||in->mNumberBuffers==0) return;
                // タップ出力は 1バッファにインターリーブ or 2バッファ(非インターリーブ)の可能性。両対応。
                uint64_t w=self_->myWrite.load(std::memory_order_relaxed);
                if (in->mNumberBuffers>=2) {
                    const float* L=(const float*)in->mBuffers[0].mData; const float* R=(const float*)in->mBuffers[1].mData;
                    UInt32 nf=in->mBuffers[0].mDataByteSize/sizeof(float);
                    for (UInt32 i=0;i<nf;i++){ self_->myRing[0][(w+i)&(kRing-1)]=L[i]; self_->myRing[1][(w+i)&(kRing-1)]=R?R[i]:L[i]; }
                    self_->myWrite.store(w+nf, std::memory_order_release);
                } else {
                    const float* d=(const float*)in->mBuffers[0].mData; UInt32 ch=in->mBuffers[0].mNumberChannels; if(ch<1)ch=1;
                    UInt32 nf=(in->mBuffers[0].mDataByteSize/sizeof(float))/ch;
                    for (UInt32 i=0;i<nf;i++){ self_->myRing[0][(w+i)&(kRing-1)]=d[i*ch]; self_->myRing[1][(w+i)&(kRing-1)]=d[i*ch+(ch>1?1:0)]; }
                    self_->myWrite.store(w+nf, std::memory_order_release);
                }
            });
            if (st!=noErr){ myWarn="CreateIOProc failed"; teardown(); return; }
            st=AudioDeviceStart(myAgg,myProc);
            if (st!=noErr){ myWarn="DeviceStart failed"; teardown(); return; }
            myRunning=true;
        }
    }
    AudioObjectID myTap=0, myAgg=0; AudioDeviceIOProcID myProc=nullptr;
    std::vector<float> myRing[2]; std::atomic<uint64_t> myWrite{0}, myRead{0};
    bool myRunning=false; int mySR=48000; std::string mySig, myWarn;
    std::atomic<uint64_t> myExec{0}, myUnderruns{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Coreaudiotap");
    i->customOPInfo.opLabel->setString("CA Process Tap");
    i->customOPInfo.opIcon->setString("PAU");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/CoreAudioTap/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new CoreAudioTapCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<CoreAudioTapCHOP*>(i); }
}
