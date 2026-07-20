// Gameplay Path SOP — GameplayKit の GKObstacleGraph で、始点→終点の障害物回避最短経路を計算し、
// 1本の Line primitive として出力する。障害物は入力SOPの各点(中心)を半径 Obstacle Radius の円
// (多角形近似)として扱う。入力が無ければ始点→終点の直線。
#import <Foundation/Foundation.h>
#import <GameplayKit/GameplayKit.h>
#include <vector>
#include <atomic>
#include <cmath>
#include "SOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
class GameplayPathSOP final : public SOP_CPlusPlusBase {
public:
    GameplayPathSOP(const OP_NodeInfo*) {}
    ~GameplayPathSOP() override {}

    void getGeneralInfo(SOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; }

    void execute(SOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        @autoreleasepool {
            float sx=(float)in->getParDouble("Start",0), sy=(float)in->getParDouble("Start",1);
            float ex=(float)in->getParDouble("End",0), ey=(float)in->getParDouble("End",1);
            float orad=(float)in->getParDouble("Obstacleradius");
            float buf=(float)in->getParDouble("Bufferradius");
            int sides=std::max(3,(int)in->getParInt("Sides"));

            // 障害物: 入力SOPの点を中心に多角形化
            NSMutableArray<GKPolygonObstacle*>* obstacles=[NSMutableArray array];
            const OP_SOPInput* sop = in->getInputSOP(0);
            if (sop) {
                int np = sop->getNumPoints();
                const Position* pos = sop->getPointPositions();
                std::vector<vector_float2> pts(sides);
                for (int i=0;i<np;i++){
                    // GKPolygonObstacle は反時計回り巻き順(CCW)が正しい(実測: CCWで迂回3ノード、
                    // CWは全遮蔽で経路0。radiusが小さく頂点が線分上に乗ると迂回しないことがあるので注意)
                    for (int k=0;k<sides;k++){ float a=2.f*(float)M_PI*k/sides; vector_float2 v={pos[i].x+orad*cosf(a), pos[i].y+orad*sinf(a)}; pts[k]=v; }
                    [obstacles addObject:[GKPolygonObstacle obstacleWithPoints:&pts[0] count:sides]];
                }
            }

            GKObstacleGraph* graph=[GKObstacleGraph graphWithObstacles:obstacles bufferRadius:buf];
            GKGraphNode2D* startN=[GKGraphNode2D nodeWithPoint:(vector_float2){sx,sy}];
            GKGraphNode2D* endN=[GKGraphNode2D nodeWithPoint:(vector_float2){ex,ey}];
            [graph connectNodeUsingObstacles:startN];
            [graph connectNodeUsingObstacles:endN];
            NSArray<GKGraphNode2D*>* path=[graph findPathFromNode:startN toNode:endN];

            std::vector<Position> positions; std::vector<float> pidx;
            if (path.count>=2) {
                for (NSUInteger i=0;i<path.count;i++){ vector_float2 p=path[i].position; float px=p.x, py=p.y; positions.emplace_back(px,py,0.f); pidx.push_back((float)i); }
                myFound=1; myLen=(int)path.count;
            } else {
                // 経路なし: 直線でフォールバック
                positions.emplace_back(sx,sy,0.f); positions.emplace_back(ex,ey,0.f);
                pidx.push_back(0); pidx.push_back(1); myFound=0; myLen=2;
            }
            out->addPoints(positions.data(), (int32_t)positions.size());
            SOP_CustomAttribData attr; attr.attribType=AttribType::Float; attr.numComponents=1;
            attr.name="pathindex"; attr.floatData=pidx.data(); out->setCustomAttribute(&attr,(int32_t)positions.size());
            std::vector<int32_t> indices(positions.size()); for(size_t i=0;i<positions.size();i++) indices[i]=(int32_t)i;
            int32_t sz=(int32_t)positions.size();
            out->addLines(indices.data(), &sz, 1);
        }
    }
    void executeVBO(SOP_VBOOutput*, const OP_Inputs*, void*) override {}

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="Gameplay Path";
        { OP_NumericParameter p("Start"); p.label="Start X/Y"; p.page=P; p.defaultValues[0]=-4; p.defaultValues[1]=0; m->appendXY(p); }
        { OP_NumericParameter p("End"); p.label="End X/Y"; p.page=P; p.defaultValues[0]=4; p.defaultValues[1]=0; m->appendXY(p); }
        { OP_NumericParameter p("Obstacleradius"); p.label="Obstacle Radius (per input point)"; p.page=P; p.defaultValues[0]=0.8; p.minSliders[0]=0.05; p.maxSliders[0]=5; p.minValues[0]=0.01; p.clampMins[0]=true; m->appendFloat(p); }
        { OP_NumericParameter p("Bufferradius"); p.label="Buffer Radius (agent size)"; p.page=P; p.defaultValues[0]=0.2; p.minSliders[0]=0; p.maxSliders[0]=3; m->appendFloat(p); }
        { OP_NumericParameter p("Sides"); p.label="Obstacle Polygon Sides"; p.page=P; p.defaultValues[0]=8; p.minSliders[0]=3; p.maxSliders[0]=16; p.minValues[0]=3; p.clampMins[0]=true; m->appendInt(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","found","length"}; float v[]={(float)myExec.load(),(float)myFound,(float)myLen};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if(myFound==0) s->setString("No obstacle-avoiding path found; output is a straight fallback line."); }

private:
    std::atomic<uint64_t> myExec{0}; int myFound=0, myLen=0;
};
} // namespace

extern "C" {
DLLEXPORT void FillSOPPluginInfo(SOP_PluginInfo* i) {
    if (!i->setAPIVersion(SOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Gameplaypath");
    i->customOPInfo.opLabel->setString("Gameplay Path");
    i->customOPInfo.opIcon->setString("GPP");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=1;
}
DLLEXPORT SOP_CPlusPlusBase* CreateSOPInstance(const OP_NodeInfo* i) { return new GameplayPathSOP(i); }
DLLEXPORT void DestroySOPInstance(SOP_CPlusPlusBase* i) { delete static_cast<GameplayPathSOP*>(i); }
}
