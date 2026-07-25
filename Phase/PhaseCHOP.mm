// PHASE CHOP — Apple PHASE(Physical Audio Spatialization Engine)で入力オーディオを物理ベースに
// 空間化し、システム出力(ヘッドホン)へ再生する。PHASEは出力バッファ取得APIが無く、レンダ結果を
// TDに戻せない(start/stopでデバイスへ直接再生)ため、これは「TD入力→PHASE定位→デバイス再生」の
// 再生プラグイン。ドライ入力はそのまま出力にパススルーし、空間化版はデバイスで鳴る。
// PullStreamNode の renderBlock は**リアルタイムスレッド**なので、cookとの受け渡しはロックフリーの
// SPSCリングバッファで行う(renderBlockでlock/allocは禁止)。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <PHASE/PHASE.h>
#include <simd/simd.h>
#include <string>
#include <vector>
#include <atomic>
#include <cmath>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
static const int kRing = 1<<16; // 65536 samples (~1.4s @48k)。2の冪でマスク

class PhaseCHOP final : public CHOP_CPlusPlusBase {
public:
    PhaseCHOP(const OP_NodeInfo*) { myRing.assign(kRing, 0.f); }
    ~PhaseCHOP() override { @autoreleasepool { teardown(); } }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override {
        g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; g->timeslice=true;
    }
    bool getOutputInfo(CHOP_OutputInfo*, const OP_Inputs*, void*) override { return false; } // 入力一致(ドライパススルー)

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        const OP_CHOPInput* ci = in->getInputCHOP(0);
        // ドライパススルー(出力=入力と同数ch)
        for (int c=0;c<out->numChannels;c++){
            if (ci && c<ci->numChannels) memcpy(out->channels[c], ci->getChannelData(c), sizeof(float)*out->numSamples);
            else memset(out->channels[c], 0, sizeof(float)*out->numSamples);
        }
        bool active = in->getParInt("Active")!=0;
        bool play = in->getParInt("Play")!=0;
        myGain.store((float)in->getParDouble("Gain"));
        if (!active) { teardownIfNeeded(); return; }
        double sr = (ci && ci->sampleRate>0)?ci->sampleRate:48000.0;

        int flags = 0;
        if (in->getParInt("Directpath")) flags |= (int)PHASESpatialPipelineFlagDirectPathTransmission;
        if (in->getParInt("Earlyreflections")) flags |= (int)PHASESpatialPipelineFlagEarlyReflections;
        if (in->getParInt("Latereverb")) flags |= (int)PHASESpatialPipelineFlagLateReverb;
        if (flags==0) flags = (int)PHASESpatialPipelineFlagDirectPathTransmission;

        @autoreleasepool {
            if (!ensureEngine(sr, flags)) return;
            updatePosition(in);

            // 入力(モノ化)をリングへ書き込む
            if (ci && ci->numChannels>0 && ci->numSamples>0) {
                int n = ci->numSamples;
                uint64_t w = myWrite.load(std::memory_order_relaxed);
                if (ci->numChannels==1) {
                    const float* s=ci->getChannelData(0);
                    for (int i=0;i<n;i++) myRing[(w+i)&(kRing-1)] = s[i];
                } else {
                    float inv=1.f/ci->numChannels;
                    for (int i=0;i<n;i++){ float m=0; for(int c=0;c<ci->numChannels;c++) m+=ci->getChannelData(c)[i]; myRing[(w+i)&(kRing-1)]=m*inv; }
                }
                myWrite.store(w+n, std::memory_order_release);
            }

            // Play制御
            if (play && !myPlaying) { startEvent(); }
            else if (!play && myPlaying) { stopEvent(); }
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="PHASE";
        { OP_NumericParameter p("Active"); p.label="Active"; p.page=P; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_NumericParameter p("Play"); p.label="Play (to device)"; p.page=P; p.defaultValues[0]=0; m->appendToggle(p); }
        { OP_NumericParameter p("Azimuth"); p.label="Azimuth (deg, +right)"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=-180; p.maxSliders[0]=180; m->appendFloat(p); }
        { OP_NumericParameter p("Elevation"); p.label="Elevation (deg, +up)"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=-90; p.maxSliders[0]=90; m->appendFloat(p); }
        { OP_NumericParameter p("Distance"); p.label="Distance (m)"; p.page=P; p.defaultValues[0]=3; p.minSliders[0]=0.5; p.maxSliders[0]=30; p.minValues[0]=0.1; p.clampMins[0]=true; m->appendFloat(p); }
        { OP_NumericParameter p("Gain"); p.label="Gain"; p.page=P; p.defaultValues[0]=1; p.minSliders[0]=0; p.maxSliders[0]=2; m->appendFloat(p); }
        { OP_NumericParameter p("Directpath"); p.label="Direct Path"; p.page=P; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_NumericParameter p("Earlyreflections"); p.label="Early Reflections"; p.page=P; p.defaultValues[0]=0; m->appendToggle(p); }
        { OP_NumericParameter p("Latereverb"); p.label="Late Reverb"; p.page=P; p.defaultValues[0]=0; m->appendToggle(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        int64_t buffered = (int64_t)(myWrite.load() - myRead.load());
        const char* n[]={"executes","playing","buffered","underruns","rendering"};
        float v[]={(float)myExec.load(),(float)(myPlaying?1:0),(float)buffered,(float)myUnderruns.load(),(float)(myEngine!=nil && myEngine.renderingState==PHASERenderingStateStarted)};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override {
        if (!myWarn.empty()) s->setString(myWarn.c_str());
        else if (myEngine) s->setString("PHASE plays to the system output device (headphones); audio does NOT return to TD.");
    }

private:
    void teardownIfNeeded() { if (myEngine) teardown(); }
    void teardown() {
        if (myEvent) { [myEvent stopAndInvalidate]; myEvent=nil; }
        if (myEngine) { [myEngine stop]; }
        myEngine=nil; myMixer=nil; myStreamDef=nil; mySource=nil; myListener=nil; myNode=nil;
        myPlaying=false; mySampleRate=0; myFlags=0;
        myRead.store(0); myWrite.store(0);
    }
    bool ensureEngine(double sr, int flags) {
        if (myEngine && fabs(mySampleRate-sr)<0.5 && myFlags==flags) return true;
        teardown();
        mySampleRate=sr; myFlags=flags; myWarn.clear();
        NSError* err=nil;
        myEngine=[[PHASEEngine alloc] initWithUpdateMode:PHASEUpdateModeAutomatic];
        PHASESpatialPipeline* pipeline=[[PHASESpatialPipeline alloc] initWithFlags:(PHASESpatialPipelineFlags)flags];
        if(!pipeline){myWarn="PHASE pipeline init failed";teardown();return false;}
        myMixer=[[PHASESpatialMixerDefinition alloc] initWithSpatialPipeline:pipeline];
        AVAudioFormat* fmt=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:sr channels:1];
        myStreamDef=[[PHASEPullStreamNodeDefinition alloc] initWithMixerDefinition:myMixer format:fmt];
        myStreamDef.normalize=YES;
        if(![myEngine.assetRegistry registerSoundEventAssetWithRootNode:myStreamDef identifier:@"tdstream" error:&err]){myWarn=err?err.localizedDescription.UTF8String:"register failed";teardown();return false;}
        mySource=[[PHASESource alloc] initWithEngine:myEngine];
        [myEngine.rootObject addChild:mySource error:&err];
        myListener=[[PHASEListener alloc] initWithEngine:myEngine];
        myListener.transform=matrix_identity_float4x4;
        [myEngine.rootObject addChild:myListener error:&err];
        if(![myEngine startAndReturnError:&err]){myWarn=err?err.localizedDescription.UTF8String:"engine start failed";teardown();return false;}
        return true;
    }
    void startEvent() {
        if (!myEngine || myPlaying) return;
        NSError* err=nil;
        PHASEMixerParameters* params=[[PHASEMixerParameters alloc] init];
        [params addSpatialMixerParametersWithIdentifier:myMixer.identifier source:mySource listener:myListener];
        myEvent=[[PHASESoundEvent alloc] initWithEngine:myEngine assetIdentifier:@"tdstream" mixerParameters:params error:&err];
        if(!myEvent){myWarn=err?err.localizedDescription.UTF8String:"sound event failed";return;}
        myNode = myEvent.pullStreamNodes.allValues.firstObject;
        // リアルタイム renderBlock: リングから読む(lock/alloc禁止)
        __block PhaseCHOP* self_=this;
        myNode.renderBlock=^OSStatus(BOOL* sil,const AudioTimeStamp* ts,AVAudioFrameCount fc,AudioBufferList* abl){
            float* o=(float*)abl->mBuffers[0].mData;
            uint64_t r=self_->myRead.load(std::memory_order_relaxed);
            uint64_t w=self_->myWrite.load(std::memory_order_acquire);
            float g=self_->myGain.load(std::memory_order_relaxed);
            uint64_t avail = w>r ? (w-r) : 0;
            AVAudioFrameCount give = (AVAudioFrameCount)(avail<fc?avail:fc);
            for (AVAudioFrameCount i=0;i<give;i++) o[i]=self_->myRing[(r+i)&(kRing-1)]*g;
            for (AVAudioFrameCount i=give;i<fc;i++) o[i]=0.f;
            if (give<fc) self_->myUnderruns.fetch_add(1,std::memory_order_relaxed);
            self_->myRead.store(r+give, std::memory_order_release);
            *sil = (give==0);
            return noErr;
        };
        [myEvent startWithCompletion:^(PHASESoundEventStartHandlerReason){}];
        myPlaying=true;
    }
    void stopEvent() { if(myEvent){ [myEvent stopAndInvalidate]; myEvent=nil; myNode=nil; } myPlaying=false; }
    void updatePosition(const OP_Inputs* in) {
        if (!mySource) return;
        double az=in->getParDouble("Azimuth")*M_PI/180.0, el=in->getParDouble("Elevation")*M_PI/180.0, d=in->getParDouble("Distance");
        float x=(float)( d*cos(el)*sin(az)), y=(float)( d*sin(el)), z=(float)(-d*cos(el)*cos(az));
        simd_float4x4 t=matrix_identity_float4x4; t.columns[3]=(simd_float4){x,y,z,1};
        mySource.transform=t;
    }

    PHASEEngine* myEngine=nil; PHASESpatialMixerDefinition* myMixer=nil;
    PHASEPullStreamNodeDefinition* myStreamDef=nil; PHASESource* mySource=nil;
    PHASEListener* myListener=nil; PHASESoundEvent* myEvent=nil; PHASEPullStreamNode* myNode=nil;
    std::vector<float> myRing;
    std::atomic<uint64_t> myWrite{0}, myRead{0};
    std::atomic<float> myGain{1.f};
    std::atomic<uint64_t> myExec{0}, myUnderruns{0};
    bool myPlaying=false; double mySampleRate=0; int myFlags=0; std::string myWarn;
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Phase");
    i->customOPInfo.opLabel->setString("PHASE");
    i->customOPInfo.opIcon->setString("PHS");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/Phase/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs=1; i->customOPInfo.maxInputs=1;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new PhaseCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<PhaseCHOP*>(i); }
}
