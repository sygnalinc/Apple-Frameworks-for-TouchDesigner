// SwiftUI Panel CHOP — 本物の macOS ウインドウに**操作可能な** SwiftUI コントロールを表示し、
// ユーザーが操作した値を CHOP チャンネルとして出す。TD の外部コントロールパネル/オペレータUIに。
//
// JSON でコントロールを定義(id 付き)。id がチャンネル名になる:
//   slider → その値(min..max) / toggle → 0 or 1 / button → 押した瞬間だけ 1(モーメンタリ) /
//   stepper → その値。text/header/divider は表示のみ(チャンネルにならない)。
//
// 値の読み戻しは Swift ヘルパ(SwiftUIPanelHelper・C ABI sp_)。ウインドウはメインスレッドで
// 表示(TDがメインrunloopをpump)。cook は値を読むだけで非ブロック。
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <string>
#include <vector>
#include <atomic>
#include "CHOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

extern "C" {
    void*  sp_create(void);
    void   sp_destroy(void*);
    void   sp_configure(void*, const char* json, const char* title,
                        double x, double y, double w, double h, int show);
    double sp_value(void*, const char* id);
    int    sp_take_button(void*, const char* id);
}

namespace {

struct Ctrl { std::string id; int type; };   // type: 0 slider, 1 toggle, 2 button, 3 stepper

static void parseControls(const std::string& json, std::vector<Ctrl>& out)
{
    out.clear();
    @autoreleasepool {
        NSData* d = [NSData dataWithBytes:json.data() length:json.size()];
        id o = json.empty() ? nil : [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![o isKindOfClass:[NSDictionary class]]) return;
        NSArray* arr = ((NSDictionary*)o)[@"controls"];
        if (![arr isKindOfClass:[NSArray class]]) return;
        for (id ce in arr) {
            if (![ce isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary* c = ce;
            NSString* type = c[@"type"]; NSString* cid = c[@"id"];
            if (![cid isKindOfClass:[NSString class]]) continue;
            int t = -1;
            if ([type isEqualToString:@"slider"]) t = 0;
            else if ([type isEqualToString:@"toggle"]) t = 1;
            else if ([type isEqualToString:@"button"]) t = 2;
            else if ([type isEqualToString:@"stepper"]) t = 3;
            if (t < 0) continue;
            out.push_back({std::string(cid.UTF8String ? cid.UTF8String : ""), t});
        }
    }
}

class SwiftUIPanelCHOP final : public CHOP_CPlusPlusBase {
public:
    SwiftUIPanelCHOP(const OP_NodeInfo*) { myState = sp_create(); }
    ~SwiftUIPanelCHOP() override { if (myState) sp_destroy(myState); }

    void getGeneralInfo(CHOP_GeneralInfo* g, const OP_Inputs*, void*) override
    { g->cookEveryFrame = false; g->cookEveryFrameIfAsked = true; g->timeslice = false; }

    // Widgets DAT が繋がっていれば各行のcell(r,0)を1コントロールJSONとして集約、なければ Json パラメータ
    static std::string buildJson(const OP_Inputs* in)
    {
        const OP_DATInput* wd = in->getParDAT("Widgets");
        if (wd && wd->numRows > 0 && wd->numCols > 0) {
            std::string j = "{\"controls\":[";
            bool first = true;
            for (int r = 0; r < wd->numRows; r++) {
                const char* cell = wd->getCell(r, 0);
                if (!cell || !*cell) continue;
                // 空白のみの行はスキップ
                std::string c = cell; size_t a = c.find_first_not_of(" \t\r\n");
                if (a == std::string::npos) continue;
                if (!first) j += ",";
                j += cell; first = false;
            }
            j += "]}";
            return j;
        }
        return in->getParString("Json") ? in->getParString("Json") : "";
    }

    bool getOutputInfo(CHOP_OutputInfo* info, const OP_Inputs* in, void*) override
    {
        parseControls(buildJson(in), myChannels);
        info->numChannels = std::max(1, (int)myChannels.size());
        info->numSamples = 1; info->sampleRate = 60;
        return true;
    }
    void getChannelName(int32_t i, OP_String* name, const OP_Inputs*, void*) override
    {
        if (myChannels.empty() || i >= (int)myChannels.size()) { name->setString("panel"); return; }
        name->setString(myChannels[i].id.c_str());
    }

    void execute(CHOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        if (!myState) return;
        std::string json = buildJson(in);
        std::string title = in->getParString("Title") ? in->getParString("Title") : "Panel";
        bool show = in->getParInt("Show") != 0;
        double x = in->getParDouble("Winx"), y = in->getParDouble("Winy");
        double w = in->getParDouble("Winw"), h = in->getParDouble("Winh");

        char pos[128]; snprintf(pos, sizeof pos, "%.0f,%.0f,%.0f,%.0f", x, y, w, h);
        std::string sig = (show ? "1|" : "0|") + title + "|" + pos + "|" + json;
        if (sig != mySig) {
            mySig = sig;
            sp_configure(myState, json.c_str(), title.c_str(), x, y, w, h, show ? 1 : 0);
        }

        parseControls(json, myChannels);   // getOutputInfoと同じチャンネル並びを保つ
        int n = std::min((int)myChannels.size(), out->numChannels);
        for (int i = 0; i < n; i++) {
            const Ctrl& c = myChannels[i];
            double v = (c.type == 2) ? (double)sp_take_button(myState, c.id.c_str())
                                     : sp_value(myState, c.id.c_str());
            out->channels[i][0] = (float)v;
        }
        for (int i = n; i < out->numChannels; i++) out->channels[i][0] = 0;
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "SwiftUI Panel";
        { OP_NumericParameter p("Show"); p.label = "Show Window"; p.page = P; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_StringParameter p("Title"); p.label = "Window Title"; p.page = P; p.defaultValue = "TD Panel"; m->appendString(p); }
        { OP_StringParameter p("Widgets"); p.label = "Widgets DAT"; p.page = P; m->appendDAT(p); }
        { OP_StringParameter p("Json"); p.label = "Controls JSON (if no Widgets DAT)"; p.page = P;
          p.defaultValue = "{\"controls\":[{\"type\":\"header\",\"label\":\"Controls\"},{\"type\":\"slider\",\"id\":\"level\",\"label\":\"Level\",\"value\":0.5},{\"type\":\"toggle\",\"id\":\"enable\",\"label\":\"Enable\",\"on\":true},{\"type\":\"button\",\"id\":\"trigger\",\"label\":\"Trigger\"}]}";
          m->appendString(p); }
        { OP_NumericParameter p("Winx"); p.label = "Window X"; p.page = P; p.defaultValues[0] = 120; p.minSliders[0]=0; p.maxSliders[0]=3000; m->appendFloat(p); }
        { OP_NumericParameter p("Winy"); p.label = "Window Y"; p.page = P; p.defaultValues[0] = 400; p.minSliders[0]=0; p.maxSliders[0]=2000; m->appendFloat(p); }
        { OP_NumericParameter p("Winw"); p.label = "Window Width"; p.page = P; p.defaultValues[0] = 300; p.minSliders[0]=120; p.maxSliders[0]=1200; m->appendFloat(p); }
        { OP_NumericParameter p("Winh"); p.label = "Window Height"; p.page = P; p.defaultValues[0] = 260; p.minSliders[0]=80; p.maxSliders[0]=1200; m->appendFloat(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 2; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        const char* n[] = {"executes", "controls"};
        float v[] = {(float)myExec.load(), (float)myChannels.size()};
        c->name->setString(n[i]); c->value = v[i];
    }

private:
    void* myState = nullptr;
    std::string mySig;
    std::vector<Ctrl> myChannels;
    std::atomic<uint64_t> myExec{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillCHOPPluginInfo(CHOP_PluginInfo* i) {
    if (!i->setAPIVersion(CHOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Swiftuipanel");
    i->customOPInfo.opLabel->setString("SwiftUI Panel");
    i->customOPInfo.opIcon->setString("SUP");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/SwiftUIPanel/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 0; i->customOPInfo.maxInputs = 0;
}
DLLEXPORT CHOP_CPlusPlusBase* CreateCHOPInstance(const OP_NodeInfo* i) { return new SwiftUIPanelCHOP(i); }
DLLEXPORT void DestroyCHOPInstance(CHOP_CPlusPlusBase* i) { delete static_cast<SwiftUIPanelCHOP*>(i); }
}
