// Gaussian Splat SOP — 3D Gaussian Splatting の .ply(INRIA形式: x,y,z,nx,ny,nz,f_dc_*,f_rest_*,
// opacity,scale_*,rot_*)を直接パースし、TDの点群(SOP)として出力する。位置に加え、球面調和の
// DC項から色(Cd)、scaleから点サイズ(pscale)、opacity(sigmoid)を点属性で出す。TDはこれを
// ネイティブに色付き点群として描画できる(RealityRendererは点を描かないため、TD側で描く)。
// パースは重い(数十MB)のでワーカースレッドで行い、cookは最新の点群を出すだけ(非ブロック)。
#import <Foundation/Foundation.h>
#include <atomic>
#include <condition_variable>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>
#include "SOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
struct Cloud { std::vector<Position> pts; std::vector<Color> cd; std::vector<float> pscale, opacity; uint64_t serial=0; std::string warn; };

class GaussianSplatSOP final : public SOP_CPlusPlusBase {
public:
    GaussianSplatSOP(const OP_NodeInfo*) { myThread=std::thread([this]{ worker(); }); }
    ~GaussianSplatSOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit=true; } myCond.notify_all(); if(myThread.joinable()) myThread.join(); }

    void getGeneralInfo(SOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; }

    void execute(SOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        std::string file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        int maxp = (int)in->getParInt("Maxpoints");
        std::string sig=file+"|"+std::to_string(maxp);
        if (sig!=mySig) {
            mySig=sig;
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myBusy) { myFile=file; myMaxp=maxp; myPending=true; l.unlock(); myCond.notify_one(); }
            else mySig.clear();
        }
        Cloud c; { std::lock_guard<std::mutex> l(myMutex); c=myResult; myWarn=c.warn; myCount=(int)c.pts.size(); }
        if (c.pts.empty()) return;
        out->addPoints(c.pts.data(), (int32_t)c.pts.size());
        SOP_CustomAttribData a; a.attribType=AttribType::Float;
        a.numComponents=3; a.name="Cd"; a.floatData=(float*)c.cd.data(); out->setCustomAttribute(&a,(int32_t)c.pts.size());
        a.numComponents=1; a.name="pscale"; a.floatData=c.pscale.data(); out->setCustomAttribute(&a,(int32_t)c.pts.size());
        a.numComponents=1; a.name="opacity"; a.floatData=c.opacity.data(); out->setCustomAttribute(&a,(int32_t)c.pts.size());
    }
    void executeVBO(SOP_VBOOutput*, const OP_Inputs*, void*) override {}

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="Gaussian Splat";
        { OP_StringParameter p("File"); p.label="Splat File (.ply, 3DGS)"; p.page=P; m->appendFile(p); }
        { OP_NumericParameter p("Maxpoints"); p.label="Max Points (subsample)"; p.page=P; p.defaultValues[0]=200000; p.minSliders[0]=1000; p.maxSliders[0]=1000000; p.minValues[0]=1; p.clampMins[0]=true; m->appendInt(p); }
    }
    int32_t getNumInfoCHOPChans(void*) override { return 2; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","points"}; float v[]={(float)myExec.load(),(float)myCount};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if(!myWarn.empty()) s->setString(myWarn.c_str()); }

private:
    static float sigmoid(float x){ return 1.f/(1.f+expf(-x)); }
    void worker() {
        for(;;){
            std::string file; int maxp;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l,[this]{return myPending||myQuit;}); if(myQuit) return; myBusy=true; myPending=false; file=myFile; maxp=myMaxp; }
            Cloud c; c.serial=++mySerial;
            parse(file, maxp, c);
            { std::lock_guard<std::mutex> l(myMutex); myResult=c; myBusy=false; }
        }
    }
    void parse(const std::string& file, int maxp, Cloud& c) {
        if (file.empty()) return;
        FILE* f=fopen(file.c_str(),"rb");
        if (!f){ c.warn="cannot open file"; return; }
        // ヘッダ読み(テキスト)
        std::string header; char ch; int endcount=0;
        std::string want="end_header\n";
        while ((ch=fgetc(f))!=EOF) { header+=ch; if (header.size()>=want.size() && header.compare(header.size()-want.size(),want.size(),want)==0) break; if(header.size()>65536){ fclose(f); c.warn="not a ply / header too large"; return; } }
        // プロパティ名→インデックス
        std::vector<std::string> props; long nverts=0;
        { std::istringstream ss(header); std::string line;
          while (std::getline(ss,line)) {
            if (line.rfind("element vertex",0)==0) nverts=atol(line.c_str()+15);
            else if (line.rfind("property float",0)==0) props.push_back(line.substr(15));
            else if (line.rfind("property double",0)==0) props.push_back(line.substr(16)); // 稀
          }
        }
        auto idx=[&](const char* nm)->int{ for(size_t i=0;i<props.size();i++) if(props[i]==nm) return (int)i; return -1; };
        int ix=idx("x"),iy=idx("y"),iz=idx("z"),ir=idx("f_dc_0"),ig=idx("f_dc_1"),ib=idx("f_dc_2"),iop=idx("opacity"),isc=idx("scale_0");
        int stride=(int)props.size();
        if (ix<0||iy<0||iz<0||nverts<=0){ fclose(f); c.warn="unexpected ply layout (need x/y/z float properties)"; return; }
        int sub = maxp>0 ? std::max(1L, nverts/(long)maxp) : 1;
        const float C0=0.28209479177387814f;
        std::vector<float> row(stride);
        long i=0;
        while (i<nverts) {
            if (fread(row.data(), sizeof(float), stride, f)!=(size_t)stride) break;
            c.pts.emplace_back(row[ix],row[iy],row[iz]);
            float r = ir>=0?std::min(1.f,std::max(0.f,0.5f+C0*row[ir])):0.8f;
            float g = ig>=0?std::min(1.f,std::max(0.f,0.5f+C0*row[ig])):0.8f;
            float b = ib>=0?std::min(1.f,std::max(0.f,0.5f+C0*row[ib])):0.8f;
            c.cd.push_back(Color(r,g,b,1));
            c.pscale.push_back(isc>=0?std::min(0.1f,std::max(0.001f,expf(row[isc]))):0.01f);
            c.opacity.push_back(iop>=0?sigmoid(row[iop]):1.f);
            // subsample: 残りをスキップ
            if (sub>1 && i+sub<=nverts) { fseek(f, (long)(sub-1)*stride*sizeof(float), SEEK_CUR); i+=sub; }
            else i++;
        }
        fclose(f);
    }

    std::thread myThread; std::mutex myMutex; std::condition_variable myCond;
    bool myPending=false, myBusy=false, myQuit=false;
    std::string myFile, mySig, myWarn; int myMaxp=200000, myCount=0;
    Cloud myResult; std::atomic<uint64_t> mySerial{0}, myExec{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillSOPPluginInfo(SOP_PluginInfo* i) {
    if (!i->setAPIVersion(SOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Gaussiansplat");
    i->customOPInfo.opLabel->setString("Gaussian Splat");
    i->customOPInfo.opIcon->setString("GSP");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
}
DLLEXPORT SOP_CPlusPlusBase* CreateSOPInstance(const OP_NodeInfo* i) { return new GaussianSplatSOP(i); }
DLLEXPORT void DestroySOPInstance(SOP_CPlusPlusBase* i) { delete static_cast<GaussianSplatSOP*>(i); }
}
