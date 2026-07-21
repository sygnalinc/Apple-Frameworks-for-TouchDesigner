// Spatial Mixer CHOP — 多チャンネル(サラウンドベッド)入力を、各チャンネルを標準スピーカー位置に
// 配置したモノ音源として AVAudioEnvironmentNode でバイノーラル(HRTF)にレンダし、ステレオCHOPで返す。
// AUSpatialMixer('3dem')の多ch生設定は manual-render で不安定(実測segfault)なため、実証済みの
// AVAudioEnvironmentNode + チャンネル毎の positioned mono source で同等の空間ミックスを実現する。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include <string>
#include <vector>
#include <atomic>
#include <cmath>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
struct Spk { float az, el; }; // azimuth(+right), elevation(deg)

// レイアウト別の標準スピーカー角度(チャンネル順)
static std::vector<Spk> layoutFor(const std::string& name, int nch) {
    if (name=="Stereo" || (name=="Auto" && nch==2)) return {{-30,0},{30,0}};
    if (name=="Quad"   || (name=="Auto" && nch==4)) return {{-45,0},{45,0},{-135,0},{135,0}};
    if (name=="Fivepoint1" || (name=="Auto" && nch==6)) return {{-30,0},{30,0},{0,0},{0,0},{-110,0},{110,0}}; // L R C LFE Ls Rs
    if (name=="Sevenpoint1" || (name=="Auto" && nch==8)) return {{-30,0},{30,0},{0,0},{0,0},{-135,0},{135,0},{-90,0},{90,0}}; // L R C LFE Lrs Rrs Ls Rs
    // Auto フォールバック: 等間隔に円周配置
    std::vector<Spk> v; for (int i=0;i<nch;i++){ float a=-180.f + 360.f*(i+0.5f)/nch; v.push_back({a,0}); } return v;
}

class AVAudioMixerCHOP final : public CHOP_CPlusPlusBase {
public:
    AVAudioMixerCHOP(const OP_NodeInfo*) {}
    ~AVAudioMixerCHOP() override { @autoreleasepool { teardown(); } }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override {
        g->cookEveryFrame = false; g->cookEveryFrameIfAsked = true; g->timeslice = true;
    }
    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override { info->numChannels = 2; return true; }
    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override { name->setString(i==0?"left":"right"); }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        int n = out->numSamples;
        for (int c=0;c<out->numChannels;c++) memset(out->channels[c],0,sizeof(float)*n);
        bool active = in->getParInt("Active")!=0;
        const OP_CHOPInput* ci = in->getInputCHOP(0);
        if (!active || out->numChannels<2 || !ci || ci->numChannels<1 || ci->numSamples<1) return;
        double sr = ci->sampleRate>0 ? ci->sampleRate : 44100.0;
        std::string layout = in->getParString("Layout") ? in->getParString("Layout") : "Auto";
        @autoreleasepool {
            if (!ensureEngine(sr, n, ci->numChannels, layout)) return;
            updateParams(in);

            int inN = ci->numSamples;
            // 各chのブロックをコピー
            myBlocks.assign(myNumCh, std::vector<float>(inN,0.f));
            for (int c=0;c<myNumCh && c<ci->numChannels;c++)
                memcpy(myBlocks[c].data(), ci->getChannelData(c), sizeof(float)*inN);
            myPos.assign(myNumCh, 0); // 音源ごとに独立(プル順に依存しない)

            int render = n<inN?n:inN;
            NSError* err=nil;
            if ([myEngine renderOffline:(AVAudioFrameCount)render toBuffer:myOutBuf error:&err]!=AVAudioEngineManualRenderingStatusSuccess){myWarn="render failed";return;}
            int copy = render<(int)myOutBuf.frameLength?render:(int)myOutBuf.frameLength;
            memcpy(out->channels[0], myOutBuf.floatChannelData[0], sizeof(float)*copy);
            memcpy(out->channels[1], myOutBuf.floatChannelData[1], sizeof(float)*copy);
            myRenders++;
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="AVAudio Mixer";
        { OP_NumericParameter p("Active"); p.label="Active"; p.page=P; p.defaultValues[0]=1; m->appendToggle(p); }
        {
            OP_StringParameter p("Layout"); p.label="Input Layout"; p.page=P; p.defaultValue="Auto";
            const char* n[]={"Auto","Stereo","Quad","Fivepoint1","Sevenpoint1"};
            const char* l[]={"Auto (by channel count)","Stereo (L R)","Quad (L R Ls Rs)","5.1 (L R C LFE Ls Rs)","7.1 (L R C LFE Lrs Rrs Ls Rs)"};
            m->appendMenu(p,5,n,l);
        }
        { OP_NumericParameter p("Distance"); p.label="Speaker Distance (m)"; p.page=P; p.defaultValues[0]=2; p.minSliders[0]=0.3; p.maxSliders[0]=10; p.minValues[0]=0.05; p.clampMins[0]=true; m->appendFloat(p); }
        {
            OP_StringParameter p("Algorithm"); p.label="Rendering Algorithm"; p.page=P; p.defaultValue="Hrtf";
            const char* n[]={"Hrtf","Hrtfhq","Sphericalhead"}; const char* l[]={"HRTF","HRTF HQ","Spherical Head"};
            m->appendMenu(p,3,n,l);
        }
        {
            OP_StringParameter p("Outputtype"); p.label="Output Type"; p.page=P; p.defaultValue="Headphones";
            const char* n[]={"Headphones","Speakers"}; const char* l[]={"Headphones (binaural)","External Speakers"};
            m->appendMenu(p,2,n,l);
        }
        { OP_NumericParameter p("Listeneryaw"); p.label="Listener Yaw (deg)"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=-180; p.maxSliders[0]=180; m->appendFloat(p); }
        { OP_NumericParameter p("Reverb"); p.label="Reverb Blend"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=0; p.maxSliders[0]=1; m->appendFloat(p); }
        { OP_NumericParameter p("Gain"); p.label="Output Gain"; p.page=P; p.defaultValues[0]=1; p.minSliders[0]=0; p.maxSliders[0]=2; m->appendFloat(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","renders","sources","ready"};
        float v[]={(float)myExec.load(),(float)myRenders.load(),(float)myNumCh,(float)(myEngine!=nil)};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if(!myWarn.empty()) s->setString(myWarn.c_str()); }

private:
    void teardown() { if(myEngine)[myEngine stop]; myEngine=nil; myEnv=nil; mySources=nil; myOutBuf=nil; mySampleRate=0; myNumCh=0; }
    bool ensureEngine(double sr, int maxFrames, int nch, const std::string& layout) {
        int cap = maxFrames<512?4096:(maxFrames*2<4096?4096:maxFrames*2);
        if (myEngine && fabs(mySampleRate-sr)<0.5 && myNumCh==nch && myLayout==layout && myMaxFrames>=maxFrames) return true;
        teardown();
        mySampleRate=sr; myMaxFrames=cap; myNumCh=nch; myLayout=layout; myWarn.clear();
        std::vector<Spk> spk = layoutFor(layout, nch);
        myEngine=[[AVAudioEngine alloc] init];
        myEnv=[[AVAudioEnvironmentNode alloc] init];
        [myEngine attachNode:myEnv];
        AVAudioFormat* mono=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:sr channels:1];
        NSMutableArray<AVAudioSourceNode*>* srcs=[NSMutableArray array];
        __block AVAudioMixerCHOP* self_=this;
        for (int c=0;c<nch;c++) {
            __block int ch=c;
            AVAudioSourceNode* s=[[AVAudioSourceNode alloc] initWithFormat:mono
                renderBlock:^OSStatus(BOOL* sil,const AudioTimeStamp* ts,AVAudioFrameCount fc,AudioBufferList* abl){
                    float* d=(float*)abl->mBuffers[0].mData;
                    int avail=0; const float* srcp=nullptr; int pos=0;
                    if (ch<(int)self_->myBlocks.size() && ch<(int)self_->myPos.size()){ pos=self_->myPos[ch]; avail=(int)self_->myBlocks[ch].size()-pos; srcp=self_->myBlocks[ch].data(); }
                    int give=(int)fc<avail?(int)fc:(avail>0?avail:0);
                    for(int i=0;i<give;i++) d[i]=srcp[pos+i];
                    for(AVAudioFrameCount i=give;i<fc;i++) d[i]=0.f;
                    if (ch<(int)self_->myPos.size()) self_->myPos[ch]+=give;
                    *sil=(give==0); return noErr;
                }];
            [myEngine attachNode:s];
            [myEngine connect:s to:myEnv format:mono];
            id<AVAudio3DMixing> mix=(id<AVAudio3DMixing>)s;
            mix.renderingAlgorithm=AVAudio3DMixingRenderingAlgorithmHRTF;
            float az=spk[c].az*M_PI/180.f, el=spk[c].el*M_PI/180.f, d=2.0f;
            mix.position=AVAudioMake3DPoint(d*cos(el)*sin(az), d*sin(el), -d*cos(el)*cos(az));
            [srcs addObject:s];
        }
        mySources=srcs;
        // 全source更新後にInPosを進めるため、renderBlockは共有InPosを読むが、各blockは同数fcで呼ばれる。
        // ここではInPos進行を最後のsourceでは行わず、execute側でrender前に0リセット・各blockが同じ範囲を読む設計。
        [myEngine connect:myEnv to:myEngine.mainMixerNode format:nil];
        AVAudioFormat* outFmt=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:sr channels:2];
        NSError* err=nil;
        if(![myEngine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:outFmt maximumFrameCount:(AVAudioFrameCount)cap error:&err]){myWarn=err?err.localizedDescription.UTF8String:"manual failed";teardown();return false;}
        if(![myEngine startAndReturnError:&err]){myWarn=err?err.localizedDescription.UTF8String:"start failed";teardown();return false;}
        myOutBuf=[[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt frameCapacity:(AVAudioFrameCount)cap];
        return true;
    }
    void updateParams(const OP_Inputs* in) {
        if(!myEnv) return;
        std::string alg=in->getParString("Algorithm")?in->getParString("Algorithm"):"Hrtf";
        AVAudio3DMixingRenderingAlgorithm ra = alg=="Hrtfhq"?AVAudio3DMixingRenderingAlgorithmHRTFHQ : (alg=="Sphericalhead"?AVAudio3DMixingRenderingAlgorithmSphericalHead:AVAudio3DMixingRenderingAlgorithmHRTF);
        float dist=(float)in->getParDouble("Distance"), rev=(float)in->getParDouble("Reverb");
        std::vector<Spk> spk=layoutFor(myLayout,myNumCh);
        for (int c=0;c<(int)mySources.count;c++){
            id<AVAudio3DMixing> mix=(id<AVAudio3DMixing>)mySources[c];
            mix.renderingAlgorithm=ra; mix.reverbBlend=rev;
            float az=spk[c].az*M_PI/180.f, el=spk[c].el*M_PI/180.f;
            mix.position=AVAudioMake3DPoint(dist*cos(el)*sin(az), dist*sin(el), -dist*cos(el)*cos(az));
        }
        std::string ot=in->getParString("Outputtype")?in->getParString("Outputtype"):"Headphones";
        myEnv.outputType=(ot=="Speakers")?AVAudioEnvironmentOutputTypeExternalSpeakers:AVAudioEnvironmentOutputTypeHeadphones;
        myEnv.listenerAngularOrientation=AVAudioMake3DAngularOrientation((float)in->getParDouble("Listeneryaw"),0,0);
        myEngine.mainMixerNode.outputVolume=(float)in->getParDouble("Gain");
    }

    AVAudioEngine* myEngine=nil; AVAudioEnvironmentNode* myEnv=nil;
    NSArray<AVAudioSourceNode*>* mySources=nil; AVAudioPCMBuffer* myOutBuf=nil;
    std::vector<std::vector<float>> myBlocks; std::vector<int> myPos;
    double mySampleRate=0; int myMaxFrames=0, myNumCh=0; std::string myLayout, myWarn;
    std::atomic<uint64_t> myExec{0}, myRenders{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Avaudiomixer");
    i->customOPInfo.opLabel->setString("AVAudio Mixer");
    i->customOPInfo.opIcon->setString("SPM");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs=1; i->customOPInfo.maxInputs=1;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new AVAudioMixerCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<AVAudioMixerCHOP*>(i); }
}
