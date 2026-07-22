// UI Widget DAT — SwiftUI Panel 用のUI部品を1つ定義する(TDのWidget COMPのプラグイン版)。
// Type(slider/toggle/button/text/header/divider)+ id/label/min/max/value を1行のJSON specとして
// 出力する。複数の UI Widget DAT を Merge DAT でまとめて SwiftUI Panel CHOP の Widgets に繋ぐと、
// 1つのウインドウに集約されて表示・操作できる(= Container にまとめるイメージ)。
//
// 出力は 1x1 テーブル(cell(0,0) = このウィジェットのJSON)。Merge DAT で縦に積むと、
// Panel が各行を1コントロールとして読む。
#import <Foundation/Foundation.h>
#include <string>
#include <atomic>
#include "DAT_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {

static std::string esc(const std::string& s) {   // JSON文字列エスケープ(最低限)
    std::string o;
    for (char c : s) {
        if (c == '"' || c == '\\') { o += '\\'; o += c; }
        else if (c == '\n') o += "\\n";
        else if (c == '\r') {}
        else if (c == '\t') o += "\\t";
        else o += c;
    }
    return o;
}

class UIWidgetDAT final : public DAT_CPlusPlusBase {
public:
    UIWidgetDAT(const OP_NodeInfo*) {}
    ~UIWidgetDAT() override {}
    void getGeneralInfo(DAT_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame=false; g->cookEveryFrameIfAsked=true; }

    void execute(DAT_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        std::string type = in->getParString("Type") ? in->getParString("Type") : "slider";
        std::string id = in->getParString("Id") ? in->getParString("Id") : "";
        std::string label = in->getParString("Label") ? in->getParString("Label") : "";
        double value = in->getParDouble("Value");
        double mn = in->getParDouble("Min"), mx = in->getParDouble("Max");
        double step = in->getParDouble("Step");
        double r,g,b,a; in->getParDouble4("Color", r,g,b,a);

        std::string j = "{\"type\":\"" + esc(type) + "\"";
        if (!id.empty())    j += ",\"id\":\"" + esc(id) + "\"";
        if (!label.empty()) j += ",\"label\":\"" + esc(label) + "\"";
        char b1[64];
        if (type == "slider" || type == "stepper") {
            snprintf(b1, sizeof b1, ",\"value\":%.6g,\"min\":%.6g,\"max\":%.6g", value, mn, mx); j += b1;
            if (type == "stepper") { snprintf(b1, sizeof b1, ",\"step\":%.6g", step); j += b1; }
        } else if (type == "toggle") {
            j += value > 0.5 ? ",\"on\":true" : ",\"on\":false";
        }
        // 色(既定の白 1,1,1,1 以外なら付与)
        if (!(r==1&&g==1&&b==1&&a==1)) {
            snprintf(b1, sizeof b1, ",\"color\":[%.4g,%.4g,%.4g,%.4g]", r,g,b,a); j += b1;
        }
        j += "}";

        out->setOutputDataType(DAT_OutDataType::Table);
        out->setTableSize(1, 1);
        out->setCellString(0, 0, j.c_str());
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "UI Widget";
        { OP_StringParameter p("Type"); p.label="Type"; p.page=P; p.defaultValue="slider";
          const char* n[]={"slider","toggle","button","stepper","text","header","divider"};
          const char* l[]={"Slider","Toggle","Button","Stepper","Text","Header","Divider"};
          m->appendMenu(p,7,n,l); }
        { OP_StringParameter p("Id"); p.label="ID (channel name)"; p.page=P; p.defaultValue="value"; m->appendString(p); }
        { OP_StringParameter p("Label"); p.label="Label"; p.page=P; p.defaultValue="Value"; m->appendString(p); }
        { OP_NumericParameter p("Value"); p.label="Default Value"; p.page=P; p.defaultValues[0]=0.5; m->appendFloat(p); }
        { OP_NumericParameter p("Min"); p.label="Min"; p.page=P; p.defaultValues[0]=0; m->appendFloat(p); }
        { OP_NumericParameter p("Max"); p.label="Max"; p.page=P; p.defaultValues[0]=1; m->appendFloat(p); }
        { OP_NumericParameter p("Step"); p.label="Step (stepper)"; p.page=P; p.defaultValues[0]=1; m->appendFloat(p); }
        { OP_NumericParameter p("Color"); p.label="Color"; p.page=P; p.defaultValues[0]=1; p.defaultValues[1]=1; p.defaultValues[2]=1; p.defaultValues[3]=1; m->appendRGBA(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 1; }
    void getInfoCHOPChan(int32_t, OP_InfoCHOPChan* c, void*) override
    { c->name->setString("executes"); c->value=(float)myExec.load(); }

private:
    std::atomic<uint64_t> myExec{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillDATPluginInfo(DAT_PluginInfo* i) {
    if (!i->setAPIVersion(DATCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Uiwidget");
    i->customOPInfo.opLabel->setString("UI Widget");
    i->customOPInfo.opIcon->setString("UIW");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/UIWidget/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
}
DLLEXPORT DAT_CPlusPlusBase* CreateDATInstance(const OP_NodeInfo* i) { return new UIWidgetDAT(i); }
DLLEXPORT void DestroyDATInstance(DAT_CPlusPlusBase* i) { delete static_cast<UIWidgetDAT*>(i); }
}
