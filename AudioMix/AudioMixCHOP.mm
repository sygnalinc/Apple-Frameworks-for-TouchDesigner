// Audio Mix CHOP — macOS 26 の AUAudioMix('amix')で、空間音声(First-Order Ambisonics)から
// 前景(speech)/背景(ambience)を分離・再ミックスする。AVAudioEngine の manual rendering に
// 'amix' AudioUnit を差し込み、4ch FOA 入力を通して結果を出力する。
// 注意: このAUは **4ch First-Order Ambisonics 入力(layoutTag 0x930004)専用**で、標準ステレオ/モノは
// setFormat が -10868 で拒否する。意味のある分離には実際の空間音声(4chアンビソニックス)素材が要る。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <string>
#include <vector>
#include <atomic>
#include <cmath>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
class AudioMixCHOP final : public CHOP_CPlusPlusBase {
public:
    AudioMixCHOP(const OP_NodeInfo*) {}
    ~AudioMixCHOP() override { @autoreleasepool { teardown(); } }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override {
        g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; g->timeslice=true;
    }
    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override {
        info->numChannels = myOutCh>0?myOutCh:5; return true; // amix出力ch数(通常5)。falseは入力一致で危険
    }
    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override {
        char b[16]; snprintf(b,sizeof b,"out%d",i); name->setString(b);
    }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        for (int c=0;c<out->numChannels;c++) memset(out->channels[c],0,sizeof(float)*out->numSamples);
        bool active = in->getParInt("Active")!=0;
        const OP_CHOPInput* ci = in->getInputCHOP(0);
        if (!active || !ci || ci->numChannels<1 || ci->numSamples<1) return;
        double sr = ci->sampleRate>0?ci->sampleRate:48000.0;
        @autoreleasepool {
            if (!ensureEngine(sr, out->numSamples)) return;
            // Style / Remix Amount
            if (myStyleParam) myStyleParam.value = (float)in->getParInt("Style");
            if (myRemixParam) myRemixParam.value = (float)in->getParDouble("Remix");

            int inN = ci->numSamples;
            myIn.assign(myInCh, std::vector<float>(inN,0.f));
            for (int c=0;c<myInCh;c++){ if (c<ci->numChannels) memcpy(myIn[c].data(), ci->getChannelData(c), sizeof(float)*inN); }
            myPos.assign(myInCh,0);

            int render = out->numSamples<inN?out->numSamples:inN;
            NSError* err=nil;
            if ([myEngine renderOffline:(AVAudioFrameCount)render toBuffer:myOutBuf error:&err]!=AVAudioEngineManualRenderingStatusSuccess){myWarn="render failed";return;}
            int nc = out->numChannels<(int)myOutBuf.format.channelCount?out->numChannels:(int)myOutBuf.format.channelCount;
            int copy = render<(int)myOutBuf.frameLength?render:(int)myOutBuf.frameLength;
            for (int c=0;c<nc;c++) memcpy(out->channels[c], myOutBuf.floatChannelData[c], sizeof(float)*copy);
            myRenders++;
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="Audio Mix";
        { OP_NumericParameter p("Active"); p.label="Active"; p.page=P; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_NumericParameter p("Style"); p.label="Style (0-9)"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=0; p.maxSliders[0]=9; p.minValues[0]=0; p.maxValues[0]=9; p.clampMins[0]=true; p.clampMaxes[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Remix"); p.label="Remix Amount (0=orig, 1=full separate)"; p.page=P; p.defaultValues[0]=1; p.minSliders[0]=0; p.maxSliders[0]=1; m->appendFloat(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","renders","input_channels","output_channels","ready"};
        float v[]={(float)myExec.load(),(float)myRenders.load(),(float)myInCh,(float)myOutCh,(float)(myEngine!=nil)};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override {
        if (!myWarn.empty()) s->setString(myWarn.c_str());
        else if (myEngine && myInCh==4) s->setString("Requires 4ch First-Order Ambisonics input; synthetic/stereo audio yields silence.");
    }

private:
    void teardown() { if(myEngine)[myEngine stop]; myEngine=nil; myAmix=nil; myOutBuf=nil; myStyleParam=nil; myRemixParam=nil; mySampleRate=0; }
    bool ensureEngine(double sr, int maxFrames) {
        int cap = maxFrames<512?4096:(maxFrames*2<4096?4096:maxFrames*2);
        if (myEngine && fabs(mySampleRate-sr)<0.5 && myMaxFrames>=maxFrames) return true;
        teardown(); mySampleRate=sr; myMaxFrames=cap; myWarn.clear();

        // amix AU を同期取得
        AudioComponentDescription d={0}; d.componentType=kAudioUnitType_FormatConverter;
        d.componentSubType=kAudioUnitSubType_AUAudioMix; d.componentManufacturer=kAudioUnitManufacturer_Apple;
        if (!AudioComponentFindNext(NULL,&d)) { myWarn="AUAudioMix unavailable (needs macOS 26+)"; return false; }
        __block AVAudioUnit* au=nil; dispatch_semaphore_t sem=dispatch_semaphore_create(0);
        [AVAudioUnit instantiateWithComponentDescription:d options:0 completionHandler:^(AVAudioUnit* u,NSError* e){au=u;dispatch_semaphore_signal(sem);}];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC));
        if (!au) { myWarn="AUAudioMix instantiate failed"; return false; }
        myAmix=au;

        AUAudioUnit* aau=au.AUAudioUnit;
        AVAudioFormat* auIn = aau.inputBusses[0].format;    // 4ch FOA(AUが要求)
        AVAudioFormat* auOut = aau.outputBusses[0].format;  // 5ch
        myInCh=(int)auIn.channelCount; myOutCh=(int)auOut.channelCount;
        // AUの要求サンプルレートに合わせたフォーマットを作る(TDのsrで)
        AVAudioFormat* inFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:sr interleaved:NO channelLayout:auIn.channelLayout];
        AVAudioFormat* outFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:sr interleaved:NO channelLayout:auOut.channelLayout];

        myEngine=[[AVAudioEngine alloc] init];
        [myEngine attachNode:myAmix];
        __block AudioMixCHOP* self_=this;
        mySource=[[AVAudioSourceNode alloc] initWithFormat:inFmt
            renderBlock:^OSStatus(BOOL* sil,const AudioTimeStamp* ts,AVAudioFrameCount fc,AudioBufferList* abl){
                bool any=false;
                for (UInt32 c=0;c<abl->mNumberBuffers;c++){
                    float* dst=(float*)abl->mBuffers[c].mData;
                    int avail=0; const float* srcp=nullptr; int pos=0;
                    if ((int)c<(int)self_->myIn.size() && (int)c<(int)self_->myPos.size()){ pos=self_->myPos[c]; avail=(int)self_->myIn[c].size()-pos; srcp=self_->myIn[c].data(); }
                    int give=(int)fc<avail?(int)fc:(avail>0?avail:0);
                    for(int i=0;i<give;i++) dst[i]=srcp[pos+i];
                    for(AVAudioFrameCount i=give;i<fc;i++) dst[i]=0.f;
                    if ((int)c<(int)self_->myPos.size()) self_->myPos[c]+=give;
                    if (give>0) any=true;
                }
                *sil=!any; return noErr;
            }];
        [myEngine attachNode:mySource];
        [myEngine connect:mySource to:myAmix format:inFmt];
        [myEngine connect:myAmix to:myEngine.mainMixerNode format:outFmt];

        NSError* err=nil;
        if(![myEngine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:outFmt maximumFrameCount:(AVAudioFrameCount)cap error:&err]){myWarn=err?err.localizedDescription.UTF8String:"manual failed";teardown();return false;}
        if(![myEngine startAndReturnError:&err]){myWarn=err?err.localizedDescription.UTF8String:"start failed";teardown();return false;}
        myOutBuf=[[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt frameCapacity:(AVAudioFrameCount)cap];

        // パラメータ参照(Style addr=0, Remix Amount addr=1)
        AUParameterTree* tree=aau.parameterTree;
        if (tree){ myStyleParam=[tree parameterWithAddress:0]; myRemixParam=[tree parameterWithAddress:1]; }
        return true;
    }

    AVAudioEngine* myEngine=nil; AVAudioUnit* myAmix=nil; AVAudioSourceNode* mySource=nil;
    AVAudioPCMBuffer* myOutBuf=nil; AUParameter* myStyleParam=nil; AUParameter* myRemixParam=nil;
    std::vector<std::vector<float>> myIn; std::vector<int> myPos;
    double mySampleRate=0; int myMaxFrames=0, myInCh=0, myOutCh=0; std::string myWarn;
    std::atomic<uint64_t> myExec{0}, myRenders{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Audiomix");
    i->customOPInfo.opLabel->setString("Audio Mix");
    i->customOPInfo.opIcon->setString("AMX");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs=1; i->customOPInfo.maxInputs=1;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new AudioMixCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<AudioMixCHOP*>(i); }
}
