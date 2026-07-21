// Gameplay Agents CHOP — GameplayKit の GKAgent2D 群を GKGoal(seek/flee/separate/align/cohere/
// avoid/wander/target speed)で駆動する群集シミュレーション。各エージェントの位置/速度/角度を出力する。
// 障害物は任意の2番目の入力CHOP(x,y,radius を1サンプル=1障害物で)から取得。
#import <Foundation/Foundation.h>
#import <GameplayKit/GameplayKit.h>
#include <string>
#include <vector>
#include <atomic>
#include <cmath>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
static const int kMax = 500;

class GameplayKitAgentsCHOP final : public CHOP_CPlusPlusBase {
public:
    GameplayKitAgentsCHOP(const OP_NodeInfo*) { myTarget = [[GKAgent2D alloc] init]; }
    ~GameplayKitAgentsCHOP() override { @autoreleasepool { myAgents=nil; myTarget=nil; myBehavior=nil; } }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; g->timeslice=false; }
    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs* in, void*) override {
        myN = clampi((int)in->getParInt("Maxagents"),1,kMax);
        info->numChannels = myN*5; info->numSamples=1; info->sampleRate=60; return true;
    }
    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override {
        int slot=i/5+1, k=i%5; const char* s[]={"x","y","vx","vy","angle"};
        char b[32]; snprintf(b,sizeof b,"agent%d/%s",slot,s[k]); name->setString(b);
    }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        @autoreleasepool {
            int n = clampi((int)in->getParInt("Maxagents"),1,kMax);
            bool reset = myResetReq.exchange(false) || n!=myN || !myAgents;
            if (reset) reseed(in, n);
            myN = n;

            // 障害物(任意の入力CHOP: 1サンプル=1障害物、ch x,y,radius)
            NSMutableArray* obstacles=[NSMutableArray array];
            const OP_CHOPInput* obs = in->getInputCHOP(0);
            if (obs && obs->numChannels>=2) {
                int cx=chanIndex(obs,"x"), cy=chanIndex(obs,"y"), cr=chanIndex(obs,"radius");
                int cnt=obs->numSamples;
                for (int i=0;i<cnt;i++){
                    float r = cr>=0?obs->getChannelData(cr)[i]:0.3f;
                    GKCircleObstacle* o=[GKCircleObstacle obstacleWithRadius:r];
                    o.position=(vector_float2){ cx>=0?obs->getChannelData(cx)[i]:0, cy>=0?obs->getChannelData(cy)[i]:0 };
                    [obstacles addObject:o];
                }
            }

            // 目標点
            myTarget.position=(vector_float2){ (float)in->getParDouble("Target",0), (float)in->getParDouble("Target",1) };

            rebuildBehavior(in, obstacles);

            // エージェント属性 + 更新
            float maxSpeed=(float)in->getParDouble("Maxspeed"), maxAcc=(float)in->getParDouble("Maxaccel"), rad=(float)in->getParDouble("Radius");
            double dt = in->getParDouble("Speed") * (1.0/60.0);
            for (GKAgent2D* a in myAgents){ a.maxSpeed=maxSpeed; a.maxAcceleration=maxAcc; a.radius=rad; a.behavior=myBehavior; }
            for (GKAgent2D* a in myAgents){ [a updateWithDeltaTime:dt]; }

            // ソフト境界(はみ出したら反対側へ引き戻す力の代わりに位置をクランプ)
            float bx=(float)in->getParDouble("Bounds",0), by=(float)in->getParDouble("Bounds",1);
            bool bound = in->getParInt("Boundenable")!=0;
            for (int i=0;i<myN;i++){
                GKAgent2D* a=myAgents[i];
                vector_float2 p=a.position;
                if (bound){ if(p.x<-bx)p.x=-bx; if(p.x>bx)p.x=bx; if(p.y<-by)p.y=-by; if(p.y>by)p.y=by; a.position=p; }
                out->channels[i*5+0][0]=p.x;
                out->channels[i*5+1][0]=p.y;
                out->channels[i*5+2][0]=a.velocity.x;
                out->channels[i*5+3][0]=a.velocity.y;
                out->channels[i*5+4][0]=a.rotation;
            }
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="GameplayKit Agents";
        { OP_NumericParameter p("Maxagents"); p.label="Agent Count"; p.page=P; p.defaultValues[0]=30; p.minSliders[0]=1; p.maxSliders[0]=200; p.minValues[0]=1; p.maxValues[0]=kMax; p.clampMins[0]=true; p.clampMaxes[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Reset"); p.label="Reset"; p.page=P; m->appendPulse(p); }
        { OP_NumericParameter p("Seed"); p.label="Seed"; p.page=P; p.defaultValues[0]=1; m->appendInt(p); }
        { OP_NumericParameter p("Spawn"); p.label="Spawn Radius"; p.page=P; p.defaultValues[0]=4; p.minSliders[0]=0.1; p.maxSliders[0]=20; m->appendFloat(p); }
        { OP_NumericParameter p("Target"); p.label="Target X/Y"; p.page=P; p.defaultValues[0]=0; p.defaultValues[1]=0; m->appendXY(p); }
        { OP_NumericParameter p("Speed"); p.label="Sim Speed"; p.page=P; p.defaultValues[0]=1; p.minSliders[0]=0; p.maxSliders[0]=4; m->appendFloat(p); }
        { OP_NumericParameter p("Maxspeed"); p.label="Max Speed"; p.page=P; p.defaultValues[0]=3; p.minSliders[0]=0; p.maxSliders[0]=20; m->appendFloat(p); }
        { OP_NumericParameter p("Maxaccel"); p.label="Max Acceleration"; p.page=P; p.defaultValues[0]=8; p.minSliders[0]=0; p.maxSliders[0]=50; m->appendFloat(p); }
        { OP_NumericParameter p("Radius"); p.label="Agent Radius"; p.page=P; p.defaultValues[0]=0.3; p.minSliders[0]=0.01; p.maxSliders[0]=2; m->appendFloat(p); }
        { OP_NumericParameter p("Boundenable"); p.label="Bound to Region"; p.page=P; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_NumericParameter p("Bounds"); p.label="Bounds X/Y"; p.page=P; p.defaultValues[0]=6; p.defaultValues[1]=6; m->appendXY(p); }
        // 重み
        const char* W="Weights";
        auto wpar=[&](const char* nm,const char* lb,double dv){ OP_NumericParameter p(nm); p.label=lb; p.page=W; p.defaultValues[0]=dv; p.minSliders[0]=0; p.maxSliders[0]=5; m->appendFloat(p); };
        wpar("Wseek","Seek Target",1.0); wpar("Wseparate","Separate",1.0); wpar("Walign","Align",0.5);
        wpar("Wcohere","Cohere",0.5); wpar("Wavoid","Avoid Obstacles",1.5); wpar("Wwander","Wander",0.0);
        wpar("Wspeed","Reach Speed",0.0);
        { OP_NumericParameter p("Sepdist"); p.label="Separation Distance"; p.page=W; p.defaultValues[0]=1.0; p.minSliders[0]=0.1; p.maxSliders[0]=5; m->appendFloat(p); }
        { OP_NumericParameter p("Neighdist"); p.label="Neighbor Distance"; p.page=W; p.defaultValues[0]=2.5; p.minSliders[0]=0.1; p.maxSliders[0]=10; m->appendFloat(p); }
        { OP_NumericParameter p("Targetspeed"); p.label="Reach Speed Value"; p.page=W; p.defaultValues[0]=2; p.minSliders[0]=0; p.maxSliders[0]=20; m->appendFloat(p); }
    }
    void pulsePressed(const char* name, void*) override { if(strcmp(name,"Reset")==0) myResetReq=true; }

    int32_t getNumInfoCHOPChans(void*) override { return 2; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","agents"}; float v[]={(float)myExec.load(),(float)myN};
        c->name->setString(n[i]); c->value=v[i];
    }

private:
    static int clampi(int v,int lo,int hi){ return v<lo?lo:(v>hi?hi:v); }
    int chanIndex(const OP_CHOPInput* c, const char* nm){ for(int i=0;i<c->numChannels;i++) if(strcmp(c->getChannelName(i),nm)==0) return i; return -1; }
    void reseed(const OP_Inputs* in, int n) {
        uint32_t s = (uint32_t)in->getParInt("Seed"); if(!s) s=1;
        float spawn=(float)in->getParDouble("Spawn");
        NSMutableArray* arr=[NSMutableArray arrayWithCapacity:n];
        for (int i=0;i<n;i++){
            GKAgent2D* a=[[GKAgent2D alloc] init];
            float rx=(lcg(s)/4294967295.f*2-1)*spawn, ry=(lcg(s)/4294967295.f*2-1)*spawn;
            a.position=(vector_float2){rx,ry};
            a.mass=1.0f;
            [arr addObject:a];
        }
        myAgents=arr;
    }
    static float lcg(uint32_t& s){ s=s*1664525u+1013904223u; return (float)s; }
    void rebuildBehavior(const OP_Inputs* in, NSArray* obstacles) {
        GKBehavior* b=[[GKBehavior alloc] init];
        float sep=(float)in->getParDouble("Sepdist"), nb=(float)in->getParDouble("Neighdist");
        float wseek=(float)in->getParDouble("Wseek"), wsep=(float)in->getParDouble("Wseparate"), wal=(float)in->getParDouble("Walign");
        float wco=(float)in->getParDouble("Wcohere"), wav=(float)in->getParDouble("Wavoid"), wwa=(float)in->getParDouble("Wwander"), wsp=(float)in->getParDouble("Wspeed");
        if (wseek>0) [b setWeight:wseek forGoal:[GKGoal goalToSeekAgent:myTarget]];
        if (wsep>0 && myAgents.count) [b setWeight:wsep forGoal:[GKGoal goalToSeparateFromAgents:myAgents maxDistance:sep maxAngle:(float)(2*M_PI)]];
        if (wal>0 && myAgents.count)  [b setWeight:wal  forGoal:[GKGoal goalToAlignWithAgents:myAgents maxDistance:nb maxAngle:(float)(2*M_PI)]];
        if (wco>0 && myAgents.count)  [b setWeight:wco  forGoal:[GKGoal goalToCohereWithAgents:myAgents maxDistance:nb maxAngle:(float)(2*M_PI)]];
        if (wav>0 && obstacles.count) [b setWeight:wav  forGoal:[GKGoal goalToAvoidObstacles:obstacles maxPredictionTime:1.5]];
        if (wwa>0) [b setWeight:wwa forGoal:[GKGoal goalToWander:(float)in->getParDouble("Maxspeed")]];
        if (wsp>0) [b setWeight:wsp forGoal:[GKGoal goalToReachTargetSpeed:(float)in->getParDouble("Targetspeed")]];
        myBehavior=b;
    }

    NSMutableArray<GKAgent2D*>* myAgents=nil; GKAgent2D* myTarget=nil; GKBehavior* myBehavior=nil;
    int myN=0; std::atomic<bool> myResetReq{false}; std::atomic<uint64_t> myExec{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Gameplaykitagents");
    i->customOPInfo.opLabel->setString("GameKit Agents");
    i->customOPInfo.opIcon->setString("GPA");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/GameplayKitAgents/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=1;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new GameplayKitAgentsCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<GameplayKitAgentsCHOP*>(i); }
}
