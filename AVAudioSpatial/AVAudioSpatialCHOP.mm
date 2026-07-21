// Spatial Audio CHOP — モノ音源を AVAudioEnvironmentNode で3D空間に配置し、HRTFバイノーラルの
// ステレオCHOPとして返す。入力オーディオCHOP(モノ)を AVAudioSourceNode でエンジンへ供給し、
// AVAudioEngine の manual rendering(offline)で1ブロックずつレンダしてTDのオーディオグラフに戻す。
// cook内でDSPを行う timeslice オーディオフィルタ(重い推論ではないので非ブロック)。
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
class AVAudioSpatialCHOP final : public CHOP_CPlusPlusBase {
public:
    AVAudioSpatialCHOP(const OP_NodeInfo*) {}
    ~AVAudioSpatialCHOP() override { @autoreleasepool { teardown(); } }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override {
        g->cookEveryFrame = false; g->cookEveryFrameIfAsked = true; g->timeslice = true;
    }
    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs*, void*) override {
        info->numChannels = 2; // binaural L/R。true を返して2chを明示(falseだと入力=モノ1chに一致し
        return true;           // channels[1] が範囲外になりクラッシュする)。numSamples は timeslice でTDが決める
    }
    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override {
        name->setString(i == 0 ? "left" : "right");
    }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        int n = out->numSamples;
        // 既定は無音
        for (int c = 0; c < out->numChannels; c++) memset(out->channels[c], 0, sizeof(float)*n);

        bool active = in->getParInt("Active") != 0;
        const OP_CHOPInput* ci = in->getInputCHOP(0);
        if (!active || out->numChannels < 2 || !ci || ci->numChannels < 1 || ci->numSamples < 1) return;

        double sr = ci->sampleRate > 0 ? ci->sampleRate : 44100.0;
        @autoreleasepool {
            if (!ensureEngine(sr, n)) return;
            updateSpatialParams(in);

            // 入力モノブロックを用意(多chなら平均してモノ化)
            int inN = ci->numSamples;
            myMono.assign(inN, 0.f);
            if (ci->numChannels == 1) {
                memcpy(myMono.data(), ci->getChannelData(0), sizeof(float)*inN);
            } else {
                float inv = 1.0f / ci->numChannels;
                for (int c = 0; c < ci->numChannels; c++) {
                    const float* s = ci->getChannelData(c);
                    for (int i = 0; i < inN; i++) myMono[i] += s[i]*inv;
                }
            }
            myInPos = 0; // source renderBlock がここから順に読む

            // 出力サンプル数ぶんレンダ(入力と出力のサンプル数はtimesliceで一致する)
            int render = n < inN ? n : inN;
            NSError* err = nil;
            AVAudioEngineManualRenderingStatus st =
                [myEngine renderOffline:(AVAudioFrameCount)render toBuffer:myOutBuf error:&err];
            if (st != AVAudioEngineManualRenderingStatusSuccess) { myWarn = "render failed"; return; }
            float* L = myOutBuf.floatChannelData[0];
            float* R = myOutBuf.floatChannelData[1];
            int copy = render < (int)myOutBuf.frameLength ? render : (int)myOutBuf.frameLength;
            memcpy(out->channels[0], L, sizeof(float)*copy);
            memcpy(out->channels[1], R, sizeof(float)*copy);
            myRenders++;
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P = "AVAudio Spatial";
        { OP_NumericParameter p("Active"); p.label="Active"; p.page=P; p.defaultValues[0]=1; m->appendToggle(p); }
        {
            OP_StringParameter p("Positionmode"); p.label="Position Mode"; p.page=P; p.defaultValue="Polar";
            const char* n[]={"Polar","Cartesian"}; const char* l[]={"Polar (Az/El/Dist)","Cartesian (X/Y/Z)"};
            m->appendMenu(p,2,n,l);
        }
        { OP_NumericParameter p("Azimuth"); p.label="Azimuth (deg, +right)"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=-180; p.maxSliders[0]=180; m->appendFloat(p); }
        { OP_NumericParameter p("Elevation"); p.label="Elevation (deg, +up)"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=-90; p.maxSliders[0]=90; m->appendFloat(p); }
        { OP_NumericParameter p("Distance"); p.label="Distance (m)"; p.page=P; p.defaultValues[0]=3; p.minSliders[0]=0.1; p.maxSliders[0]=30; p.minValues[0]=0.01; p.clampMins[0]=true; m->appendFloat(p); }
        { OP_NumericParameter p("Position"); p.label="Position X/Y/Z (m)"; p.page=P; p.defaultValues[0]=0; p.defaultValues[1]=0; p.defaultValues[2]=-3; m->appendXYZ(p); }
        {
            OP_StringParameter p("Algorithm"); p.label="Rendering Algorithm"; p.page=P; p.defaultValue="Hrtf";
            const char* n[]={"Hrtf","Hrtfhq","Sphericalhead","Equalpower"};
            const char* l[]={"HRTF","HRTF HQ","Spherical Head","Equal Power Panning"};
            m->appendMenu(p,4,n,l);
        }
        {
            OP_StringParameter p("Outputtype"); p.label="Output Type"; p.page=P; p.defaultValue="Headphones";
            const char* n[]={"Headphones","Speakers"}; const char* l[]={"Headphones (binaural)","External Speakers"};
            m->appendMenu(p,2,n,l);
        }
        { OP_NumericParameter p("Listeneryaw"); p.label="Listener Yaw (deg)"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=-180; p.maxSliders[0]=180; m->appendFloat(p); }
        { OP_NumericParameter p("Listenerpitch"); p.label="Listener Pitch (deg)"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=-90; p.maxSliders[0]=90; m->appendFloat(p); }
        { OP_NumericParameter p("Distanceatten"); p.label="Distance Attenuation"; p.page=P; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_NumericParameter p("Refdistance"); p.label="Reference Distance (m)"; p.page=P; p.defaultValues[0]=1; p.minSliders[0]=0.1; p.maxSliders[0]=10; p.minValues[0]=0.01; p.clampMins[0]=true; m->appendFloat(p); }
        { OP_NumericParameter p("Maxdistance"); p.label="Max Distance (m)"; p.page=P; p.defaultValues[0]=30; p.minSliders[0]=1; p.maxSliders[0]=200; m->appendFloat(p); }
        { OP_NumericParameter p("Reverb"); p.label="Reverb Blend"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=0; p.maxSliders[0]=1; m->appendFloat(p); }
        { OP_NumericParameter p("Occlusion"); p.label="Occlusion (dB)"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=-40; p.maxSliders[0]=0; m->appendFloat(p); }
        { OP_NumericParameter p("Gain"); p.label="Output Gain"; p.page=P; p.defaultValues[0]=1; p.minSliders[0]=0; p.maxSliders[0]=2; m->appendFloat(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","renders","samplerate","ready"};
        float v[]={(float)myExec.load(),(float)myRenders.load(),(float)mySampleRate,(float)(myEngine!=nil)};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if (!myWarn.empty()) s->setString(myWarn.c_str()); }

private:
    void teardown() {
        if (myEngine) { [myEngine stop]; }
        myEngine = nil; myEnv = nil; mySource = nil; myOutBuf = nil; mySampleRate = 0;
    }
    bool ensureEngine(double sr, int maxFrames) {
        int cap = maxFrames < 512 ? 4096 : (maxFrames*2 < 4096 ? 4096 : maxFrames*2);
        if (myEngine && fabs(mySampleRate - sr) < 0.5 && myMaxFrames >= maxFrames) return true;
        teardown();
        mySampleRate = sr; myMaxFrames = cap; myWarn.clear();
        myEngine = [[AVAudioEngine alloc] init];
        myEnv = [[AVAudioEnvironmentNode alloc] init];
        [myEngine attachNode:myEnv];
        AVAudioFormat* monoFmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sr channels:1];
        myMonoFmt = monoFmt;
        __block AVAudioSpatialCHOP* self_ = this;
        mySource = [[AVAudioSourceNode alloc] initWithFormat:monoFmt
            renderBlock:^OSStatus(BOOL* isSilence, const AudioTimeStamp* ts, AVAudioFrameCount frameCount, AudioBufferList* abl) {
                float* dst = (float*)abl->mBuffers[0].mData;
                int avail = (int)self_->myMono.size() - self_->myInPos;
                int give = (int)frameCount < avail ? (int)frameCount : (avail > 0 ? avail : 0);
                for (int i = 0; i < give; i++) dst[i] = self_->myMono[self_->myInPos + i];
                for (AVAudioFrameCount i = give; i < frameCount; i++) dst[i] = 0.f;
                self_->myInPos += give;
                *isSilence = (give == 0);
                return noErr;
            }];
        [myEngine attachNode:mySource];
        [myEngine connect:mySource to:myEnv format:monoFmt];
        [myEngine connect:myEnv to:myEngine.mainMixerNode format:nil];

        AVAudioFormat* outFmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sr channels:2];
        NSError* err = nil;
        if (![myEngine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:outFmt maximumFrameCount:(AVAudioFrameCount)cap error:&err]) {
            myWarn = err ? err.localizedDescription.UTF8String : "manual rendering failed"; teardown(); return false;
        }
        if (![myEngine startAndReturnError:&err]) {
            myWarn = err ? err.localizedDescription.UTF8String : "engine start failed"; teardown(); return false;
        }
        myOutBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt frameCapacity:(AVAudioFrameCount)cap];
        return true;
    }

    void updateSpatialParams(const OP_Inputs* in) {
        if (!myEnv || !mySource) return;
        id<AVAudio3DMixing> mix = (id<AVAudio3DMixing>)mySource;

        // 位置
        std::string pm = in->getParString("Positionmode") ? in->getParString("Positionmode") : "Polar";
        AVAudio3DPoint pos;
        if (pm == "Cartesian") {
            pos = AVAudioMake3DPoint((float)in->getParDouble("Position",0), (float)in->getParDouble("Position",1), (float)in->getParDouble("Position",2));
        } else {
            double az = in->getParDouble("Azimuth") * M_PI/180.0;
            double el = in->getParDouble("Elevation") * M_PI/180.0;
            double d  = in->getParDouble("Distance");
            // 右手系: +x右, +y上, 前方=-z。az=0で正面(-z)、+azで右(+x)
            float x = (float)( d * cos(el) * sin(az));
            float y = (float)( d * sin(el));
            float z = (float)(-d * cos(el) * cos(az));
            pos = AVAudioMake3DPoint(x,y,z);
        }
        mix.position = pos;

        std::string alg = in->getParString("Algorithm") ? in->getParString("Algorithm") : "Hrtf";
        if (alg=="Hrtfhq") mix.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmHRTFHQ;
        else if (alg=="Sphericalhead") mix.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmSphericalHead;
        else if (alg=="Equalpower") mix.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmEqualPowerPanning;
        else mix.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmHRTF;

        mix.reverbBlend = (float)in->getParDouble("Reverb");
        mix.occlusion = (float)in->getParDouble("Occlusion");

        // 距離減衰
        AVAudioEnvironmentDistanceAttenuationParameters* da = myEnv.distanceAttenuationParameters;
        bool atten = in->getParInt("Distanceatten") != 0;
        da.distanceAttenuationModel = atten ? AVAudioEnvironmentDistanceAttenuationModelInverse : AVAudioEnvironmentDistanceAttenuationModelExponential;
        da.referenceDistance = (float)in->getParDouble("Refdistance");
        da.maximumDistance = (float)in->getParDouble("Maxdistance");
        if (!atten) da.rolloffFactor = 0.0f; else da.rolloffFactor = 1.0f;

        // 出力タイプ
        std::string ot = in->getParString("Outputtype") ? in->getParString("Outputtype") : "Headphones";
        myEnv.outputType = (ot=="Speakers") ? AVAudioEnvironmentOutputTypeExternalSpeakers : AVAudioEnvironmentOutputTypeHeadphones;

        // リスナー向き
        float yaw = (float)in->getParDouble("Listeneryaw");
        float pitch = (float)in->getParDouble("Listenerpitch");
        myEnv.listenerAngularOrientation = AVAudioMake3DAngularOrientation(yaw, pitch, 0);

        // 出力ゲイン
        myEngine.mainMixerNode.outputVolume = (float)in->getParDouble("Gain");
    }

    AVAudioEngine* myEngine = nil;
    AVAudioEnvironmentNode* myEnv = nil;
    AVAudioSourceNode* mySource = nil;
    AVAudioPCMBuffer* myOutBuf = nil;
    AVAudioFormat* myMonoFmt = nil;
    std::vector<float> myMono;
    int myInPos = 0;
    double mySampleRate = 0;
    int myMaxFrames = 0;
    std::string myWarn;
    std::atomic<uint64_t> myExec{0}, myRenders{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Avaudiospatial");
    i->customOPInfo.opLabel->setString("AVAudio Spatial");
    i->customOPInfo.opIcon->setString("SPA");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs = 1; i->customOPInfo.maxInputs = 1;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new AVAudioSpatialCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<AVAudioSpatialCHOP*>(i); }
}
