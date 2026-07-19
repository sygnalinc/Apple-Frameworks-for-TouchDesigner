// RealityKit Splat TOP — RealityRenderer で USD/USDZ シーン(Gaussian Splat を含む)を
// オフスクリーン描画してTOPに出す。描画はSwiftヘルパ(RealityKitSplatHelper)がMainActorで実行。
// cook(execute)はTDのメインスレッドで呼ばれるため、そこから rk_render をスケジュールし、
// GPU完了でヘルパ側が latest バッファへ画素をコピーする(cookは非ブロック)。
#import <Foundation/Foundation.h>
#include <atomic>
#include <cmath>
#include <string>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

extern "C" {
    void* rk_create(void);
    void  rk_destroy(void*);
    void  rk_set_scene(void*, const char*);
    void  rk_set_camera(void*, float dist, float yaw, float pitch, float fov, float tx, float ty, float tz);
    void  rk_set_bg(void*, float r, float g, float b, float a);
    int   rk_render(void*, int w, int h, float dt, float spinSpeed);
    int   rk_latest_info(void*, int* w, int* h, unsigned long long* serial);
    void  rk_copy_latest(void*, void* dst, int flip);
    const char* rk_status_json(void*);
}

namespace {
static constexpr float kDeg2Rad = 3.14159265358979323846f / 180.f;

class RealityKitSplatTOP final : public TOP_CPlusPlusBase {
public:
    RealityKitSplatTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c) { myState = rk_create(); }
    ~RealityKitSplatTOP() override { if (myState) rk_destroy(myState); }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked = true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        if (!myState) return;
        if (!in->getParInt("Active")) return;

        std::string file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        rk_set_scene(myState, file.c_str());

        double d[3]; in->getParDouble3("Target", d[0], d[1], d[2]);
        float dist = (float)in->getParDouble("Distance");
        float yaw  = (float)in->getParDouble("Yaw")   * kDeg2Rad;
        float pitch= (float)in->getParDouble("Pitch") * kDeg2Rad;
        float fov  = (float)in->getParDouble("Fov");
        rk_set_camera(myState, dist, yaw, pitch, fov, (float)d[0], (float)d[1], (float)d[2]);

        double bg[4]; in->getParDouble4("Bgcolor", bg[0], bg[1], bg[2], bg[3]);
        rk_set_bg(myState, (float)bg[0], (float)bg[1], (float)bg[2], (float)bg[3]);

        int W = std::max(2, (int)in->getParInt("Resw"));
        int H = std::max(2, (int)in->getParInt("Resh"));
        float spin = (float)in->getParDouble("Autorotate") * kDeg2Rad; // deg/s → rad/s
        int rc = rk_render(myState, W, H, 1.f/60.f, spin);
        myRender = rc;

        int lw = 0, lh = 0; unsigned long long serial = 0;
        if (rk_latest_info(myState, &lw, &lh, &serial) && serial != myUploaded && lw > 0 && lh > 0) {
            size_t sz = (size_t)lw * lh * 4;
            TOP_UploadInfo ui;
            ui.textureDesc.texDim = OP_TexDim::e2D;
            ui.textureDesc.width = lw; ui.textureDesc.height = lh;
            ui.textureDesc.pixelFormat = OP_PixelFormat::BGRA8Fixed;
            auto b = myContext->createOutputBuffer(sz, TOP_BufferFlags::None, nullptr);
            if (!b) return;
            rk_copy_latest(myState, b->data, in->getParInt("Flip") ? 1 : 0);
            out->uploadBuffer(&b, ui, nullptr);
            myUploaded = serial; myFrames++;
        }
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "RealityKit Splat";
        { OP_NumericParameter p("Active"); p.label = "Active"; p.page = PAGE; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_StringParameter p("File"); p.label = "Scene File (USD / USDZ / Reality)"; p.page = PAGE; m->appendFile(p); }
        { OP_NumericParameter p("Resw"); p.label = "Resolution W"; p.page = PAGE; p.defaultValues[0] = 1280;
          p.minSliders[0] = 64; p.maxSliders[0] = 3840; p.minValues[0] = 2; p.clampMins[0] = true; m->appendInt(p); }
        { OP_NumericParameter p("Resh"); p.label = "Resolution H"; p.page = PAGE; p.defaultValues[0] = 720;
          p.minSliders[0] = 64; p.maxSliders[0] = 2160; p.minValues[0] = 2; p.clampMins[0] = true; m->appendInt(p); }
        { OP_NumericParameter p("Distance"); p.label = "Camera Distance (x content radius)"; p.page = PAGE; p.defaultValues[0] = 2.6;
          p.minSliders[0] = 0.1; p.maxSliders[0] = 10; m->appendFloat(p); }
        { OP_NumericParameter p("Yaw"); p.label = "Camera Yaw (deg)"; p.page = PAGE; p.defaultValues[0] = 30;
          p.minSliders[0] = -180; p.maxSliders[0] = 180; m->appendFloat(p); }
        { OP_NumericParameter p("Pitch"); p.label = "Camera Pitch (deg)"; p.page = PAGE; p.defaultValues[0] = 20;
          p.minSliders[0] = -89; p.maxSliders[0] = 89; m->appendFloat(p); }
        { OP_NumericParameter p("Fov"); p.label = "Field of View (deg)"; p.page = PAGE; p.defaultValues[0] = 50;
          p.minSliders[0] = 10; p.maxSliders[0] = 120; m->appendFloat(p); }
        { OP_NumericParameter p("Autorotate"); p.label = "Auto Rotate (deg/s)"; p.page = PAGE; p.defaultValues[0] = 0;
          p.minSliders[0] = -180; p.maxSliders[0] = 180; m->appendFloat(p); }
        { OP_NumericParameter p("Target"); p.label = "Look Target Offset"; p.page = PAGE;
          for (int i = 0; i < 3; i++) { p.defaultValues[i] = 0; p.minSliders[i] = -5; p.maxSliders[i] = 5; } m->appendXYZ(p); }
        { OP_NumericParameter p("Bgcolor"); p.label = "Background Color"; p.page = PAGE;
          double dv[4] = {0.03,0.03,0.05,1.0}; for (int i = 0; i < 4; i++) { p.defaultValues[i] = dv[i]; p.minValues[i]=0; p.maxValues[i]=1; p.clampMins[i]=p.clampMaxes[i]=true; } m->appendRGBA(p); }
        { OP_NumericParameter p("Flip"); p.label = "Flip Vertically"; p.page = PAGE; p.defaultValues[0] = 1; m->appendToggle(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[] = {"executes", "frames", "render_rc", "loaded"};
        std::string loaded;
        int isLoaded = 0;
        if (myState) { const char* j = rk_status_json(myState); if (j) { loaded = j; free((void*)j); } }
        isLoaded = (loaded.find("\"loaded\":\"\"") == std::string::npos && loaded.find("loaded") != std::string::npos) ? 1 : 0;
        float v[] = {(float)myExec.load(), (float)myFrames.load(), (float)myRender.load(), (float)isLoaded};
        c->name->setString(n[i]); c->value = v[i];
    }
    void getWarningString(OP_String* s, void*) override {
        if (!myState) { s->setString("helper unavailable"); return; }
        const char* j = rk_status_json(myState);
        if (j) { std::string js(j); free((void*)j);
            if (js.find("error") != std::string::npos && js.find("\"error\":\"\"") == std::string::npos)
                s->setString(js.c_str()); }
    }

private:
    TOP_Context* myContext;
    void* myState = nullptr;
    unsigned long long myUploaded = 0;
    std::atomic<uint64_t> myExec{0}, myFrames{0};
    std::atomic<int> myRender{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Realitykitsplat");
    i->customOPInfo.opLabel->setString("RealityKit Splat");
    i->customOPInfo.opIcon->setString("RKS");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs = 0;
    i->customOPInfo.maxInputs = 0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new RealityKitSplatTOP(i, c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<RealityKitSplatTOP*>(i); }
}
