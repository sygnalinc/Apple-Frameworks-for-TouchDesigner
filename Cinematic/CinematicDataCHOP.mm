// Cinematic CHOP — iPhone Cinematicモード動画のメタデータ(フォーカス深度・被写体)を
// CNScript から時刻指定で取り出して CHOP チャンネルにする(ピクセルデコード不要)。
#import <Foundation/Foundation.h>
#include <string>
#include <vector>
#include <atomic>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

extern "C" {
    void* cn_create(void); void cn_destroy(void*);
    void  cn_open(void*, const char*);
    const char* cn_status(void*);
    const char* cn_meta(void*, double timeSec);
}

namespace {
static int typeCode(const std::string& t) {
    if (t.find("Face") != std::string::npos) return 1;
    if (t.find("Head") != std::string::npos) return 2;
    if (t.find("Torso") != std::string::npos || t.find("Body") != std::string::npos) return 3;
    if (t.find("Cat") != std::string::npos) return 4;
    if (t.find("Dog") != std::string::npos) return 5;
    if (t.find("Ball") != std::string::npos) return 6;
    return 0;
}

class CinematicDataCHOP final : public CHOP_CPlusPlusBase {
public:
    CinematicDataCHOP(const OP_NodeInfo*) { myState = cn_create(); }
    ~CinematicDataCHOP() override { if (myState) cn_destroy(myState); }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame = false; g->cookEveryFrameIfAsked = true; g->timeslice = false; }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs* in, void*) override {
        myMax = std::max(1, (int)in->getParInt("Maxsubjects"));
        info->numChannels = 3 + myMax * 8; // focus, strong, count + 8/slot
        info->numSamples = 1; info->sampleRate = 60;
        return true;
    }
    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override {
        if (i == 0) { name->setString("focus_disparity"); return; }
        if (i == 1) { name->setString("focus_strong"); return; }
        if (i == 2) { name->setString("subjects"); return; }
        int k = i - 3, slot = k / 8 + 1, f = k % 8;
        const char* fn[] = {"valid","type","u","v","w","h","depth","trackid"};
        char b[32]; snprintf(b, sizeof b, "subject%d/%s", slot, fn[f]); name->setString(b);
    }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        if (!myState) return;
        std::string file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        if (file != myFile) { myFile = file; if (!file.empty()) cn_open(myState, file.c_str()); }

        // status
        double dur = 0, fps = 30; std::string st, err;
        { const char* s = cn_status(myState); if (s) { std::string all(s); free((void*)s);
            size_t a=all.find('|'), b=all.find('|',a+1), c=all.rfind('|');
            if(a!=std::string::npos&&b!=std::string::npos&&c!=std::string::npos){ st=all.substr(0,a); dur=atof(all.substr(a+1,b-a-1).c_str()); fps=atof(all.substr(b+1,c-b-1).c_str()); err=all.substr(c+1);} } }
        myStatus = st; myErr = err; myDur = dur;

        for (int c = 0; c < out->numChannels; c++) out->channels[c][0] = 0;
        if (st != "ready") return;

        double pos = std::clamp((double)in->getParDouble("Position"), 0.0, 1.0);
        double t = pos * dur;
        const char* j = cn_meta(myState, t);
        if (!j) return; std::string js(j); free((void*)j);

        @autoreleasepool {
            NSData* d = [NSData dataWithBytes:js.data() length:js.size()];
            NSDictionary* m = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if (![m isKindOfClass:[NSDictionary class]]) return;
            out->channels[0][0] = [m[@"focus"] floatValue];
            out->channels[1][0] = [m[@"strong"] floatValue];
            NSArray* subs = m[@"subjects"];
            int n = [subs isKindOfClass:[NSArray class]] ? (int)subs.count : 0;
            out->channels[2][0] = (float)n;
            for (int i = 0; i < myMax && i < n; i++) {
                NSDictionary* s = subs[i]; int base = 3 + i * 8;
                std::string ty = s[@"type"] ? [[s[@"type"] description] UTF8String] : "";
                out->channels[base+0][0] = 1;
                out->channels[base+1][0] = (float)typeCode(ty);
                out->channels[base+2][0] = [s[@"x"] floatValue];
                out->channels[base+3][0] = [s[@"y"] floatValue];
                out->channels[base+4][0] = [s[@"w"] floatValue];
                out->channels[base+5][0] = [s[@"h"] floatValue];
                out->channels[base+6][0] = [s[@"depth"] floatValue];
                out->channels[base+7][0] = [s[@"id"] floatValue];
            }
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "Cinematic";
        { OP_StringParameter p("File"); p.label = "Cinematic Video (iPhone)"; p.page = PAGE; m->appendFile(p); }
        { OP_NumericParameter p("Position"); p.label = "Position (0..1)"; p.page = PAGE; p.defaultValues[0] = 0; p.minSliders[0]=0; p.maxSliders[0]=1; p.minValues[0]=0; p.maxValues[0]=1; p.clampMins[0]=p.clampMaxes[0]=true; m->appendFloat(p); }
        { OP_NumericParameter p("Maxsubjects"); p.label = "Max Subjects"; p.page = PAGE; p.defaultValues[0]=10; p.minSliders[0]=1; p.maxSliders[0]=20; p.minValues[0]=1; p.clampMins[0]=true; m->appendInt(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        int ready = (myStatus == "ready") ? 1 : 0, loading = (myStatus == "loading") ? 1 : 0;
        const char* n[] = {"executes","ready","loading","duration"};
        float v[] = {(float)myExec.load(), (float)ready, (float)loading, (float)myDur};
        c->name->setString(n[i]); c->value = v[i];
    }
    void getWarningString(OP_String* s, void*) override { if (myStatus == "error" && !myErr.empty()) s->setString(("Cinematic: " + myErr).c_str()); }

private:
    void* myState = nullptr; std::string myFile, myStatus, myErr; double myDur = 0; int myMax = 10;
    std::atomic<uint64_t> myExec{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Cinematicdata");
    i->customOPInfo.opLabel->setString("Cinematic Data");
    i->customOPInfo.opIcon->setString("CND");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/Cinematic/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs = 0; i->customOPInfo.maxInputs = 0;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new CinematicDataCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<CinematicDataCHOP*>(i); }
}
