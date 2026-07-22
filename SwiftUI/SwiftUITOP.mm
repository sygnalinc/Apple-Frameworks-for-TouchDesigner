// SwiftUI TOP — SwiftUI ビューをパラメータ駆動でテクスチャにレンダして TOP に出す。
// SF Symbols・システムフォント・Gauge/ProgressView など**ネイティブUIの見た目**を TD の映像として
// 使える。値は TD 側(パラメータ)から流し込む一方向。SwiftUI のレンダは Swift ヘルパ
// (SwiftUIHelper・C ABI su_)がメインスレッドで行い、cook は最新テクスチャを非ブロックでアップロード。
#import <Foundation/Foundation.h>
#include <string>
#include <atomic>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

extern "C" {
    void* su_create(void);
    void  su_destroy(void*);
    void  su_submit(void*, int32_t mode, const char* text, const char* symbol,
                    double value, double fontSize,
                    double fr, double fg, double fb, double fa,
                    double br, double bg, double bb, double ba,
                    int32_t w, int32_t h);
    int   su_latest_info(void*, int32_t* w, int32_t* h, unsigned long long* serial);
    void  su_copy(void*, void* dst);
}

namespace {
class SwiftUITOP final : public TOP_CPlusPlusBase {
public:
    SwiftUITOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c) { myState = su_create(); }
    ~SwiftUITOP() override { if (myState) su_destroy(myState); }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked = true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        if (!myState) return;

        int mode = (int)in->getParInt("Mode");
        std::string text = in->getParString("Text") ? in->getParString("Text") : "";
        std::string symbol = in->getParString("Symbol") ? in->getParString("Symbol") : "";
        double value = in->getParDouble("Value");
        double fontSize = in->getParDouble("Fontsize");
        double fr, fg, fb, fa, br, bg, bb, ba;
        in->getParDouble4("Textcolor", fr, fg, fb, fa);
        in->getParDouble4("Bgcolor", br, bg, bb, ba);
        int w = std::max(1, (int)in->getParInt("Resw"));
        int h = std::max(1, (int)in->getParInt("Resh"));

        // 変化検知して再レンダ依頼(su_submit は内部で main.async・即return)
        char sig[512];
        snprintf(sig, sizeof sig, "%d|%s|%s|%.4f|%.2f|%.3f,%.3f,%.3f,%.3f|%.3f,%.3f,%.3f,%.3f|%d,%d",
                 mode, text.c_str(), symbol.c_str(), value, fontSize, fr, fg, fb, fa, br, bg, bb, ba, w, h);
        if (mySig != sig) {
            mySig = sig;
            su_submit(myState, mode, text.c_str(), symbol.c_str(), value, fontSize,
                      fr, fg, fb, fa, br, bg, bb, ba, w, h);
            mySubmit++;
        }

        // 最新テクスチャをアップロード
        int lw = 0, lh = 0; unsigned long long serial = 0;
        if (!su_latest_info(myState, &lw, &lh, &serial) || serial == myUploaded || lw <= 0 || lh <= 0)
            return;
        TOP_UploadInfo ui; ui.textureDesc.texDim = OP_TexDim::e2D;
        ui.textureDesc.width = lw; ui.textureDesc.height = lh;
        ui.textureDesc.pixelFormat = OP_PixelFormat::BGRA8Fixed;
        auto buf = myContext->createOutputBuffer((size_t)lw * lh * 4, TOP_BufferFlags::None, nullptr);
        if (!buf) return;
        su_copy(myState, buf->data);
        out->uploadBuffer(&buf, ui, nullptr);
        myUploaded = serial; myFrames++;
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* P = "SwiftUI";
        { OP_StringParameter p("Mode"); p.label = "Mode"; p.page = P; p.defaultValue = "text";
          const char* n[] = {"text","symbol","gauge","progress"};
          const char* l[] = {"Text","SF Symbol","Gauge (circular)","Progress (bar)"};
          m->appendMenu(p, 4, n, l); }
        { OP_StringParameter p("Text"); p.label = "Text"; p.page = P; p.defaultValue = "Hello TD"; m->appendString(p); }
        { OP_StringParameter p("Symbol"); p.label = "SF Symbol"; p.page = P; p.defaultValue = "star.fill"; m->appendString(p); }
        { OP_NumericParameter p("Value"); p.label = "Value (0..1)"; p.page = P; p.defaultValues[0]=0.5; p.minSliders[0]=0; p.maxSliders[0]=1; p.minValues[0]=0; p.maxValues[0]=1; p.clampMins[0]=p.clampMaxes[0]=true; m->appendFloat(p); }
        { OP_NumericParameter p("Fontsize"); p.label = "Font / Symbol Size"; p.page = P; p.defaultValues[0]=64; p.minSliders[0]=8; p.maxSliders[0]=300; p.minValues[0]=1; p.clampMins[0]=true; m->appendFloat(p); }
        { OP_NumericParameter p("Textcolor"); p.label = "Foreground"; p.page = P;
          p.defaultValues[0]=1; p.defaultValues[1]=1; p.defaultValues[2]=1; p.defaultValues[3]=1; m->appendRGBA(p); }
        { OP_NumericParameter p("Bgcolor"); p.label = "Background"; p.page = P;
          p.defaultValues[0]=0.10; p.defaultValues[1]=0.10; p.defaultValues[2]=0.12; p.defaultValues[3]=1; m->appendRGBA(p); }
        { OP_NumericParameter p("Resw"); p.label = "Width"; p.page = P; p.defaultValues[0]=512; p.minSliders[0]=16; p.maxSliders[0]=2048; p.minValues[0]=1; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Resh"); p.label = "Height"; p.page = P; p.defaultValues[0]=256; p.minSliders[0]=16; p.maxSliders[0]=2048; p.minValues[0]=1; p.clampMins[0]=true; m->appendInt(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        const char* n[] = {"executes","submits","frames"};
        float v[] = {(float)myExec.load(),(float)mySubmit.load(),(float)myFrames.load()};
        c->name->setString(n[i]); c->value = v[i];
    }

private:
    TOP_Context* myContext = nullptr; void* myState = nullptr;
    std::string mySig; unsigned long long myUploaded = 0;
    std::atomic<uint64_t> myExec{0}, mySubmit{0}, myFrames{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Swiftui");
    i->customOPInfo.opLabel->setString("SwiftUI");
    i->customOPInfo.opIcon->setString("SUI");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/SwiftUI/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs = 0; i->customOPInfo.maxInputs = 0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new SwiftUITOP(i, c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<SwiftUITOP*>(i); }
}
