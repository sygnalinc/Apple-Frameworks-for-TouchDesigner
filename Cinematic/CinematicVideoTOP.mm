// Cinematic TOP — iPhone Cinematicモード動画から、フレーム毎の深度(視差)マップ、または
// f値/ピントを差し替えて再レンダした映像を出す。デコード/レンダはワーカースレッドで行い
// cook をブロックしない(共有ヘルパ CinematicHelper が内部で latest を保持)。
#import <Foundation/Foundation.h>
#include <string>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

extern "C" {
    void* cn_create(void); void cn_destroy(void*);
    void  cn_open(void*, const char*);
    const char* cn_status(void*);
    int   cn_depth(void*, double timeSec, int flip, int normalize);
    int   cn_latest_depth_info(void*, int* w, int* h, unsigned long long* serial);
    void  cn_copy_depth(void*, void* dst);
    int   cn_render(void*, double timeSec, float fNumber, float focusOverride, int flip);
    int   cn_latest_render_info(void*, int* w, int* h, unsigned long long* serial);
    void  cn_copy_render(void*, void* dst);
}

namespace {
struct Job { std::string file; int mode; double time; float fnum, focus; bool flip, norm; };

class CinematicVideoTOP final : public TOP_CPlusPlusBase {
public:
    CinematicVideoTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c) { myState = cn_create(); myThread = std::thread([this]{ worker(); }); }
    ~CinematicVideoTOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit = true; } myCond.notify_all(); if (myThread.joinable()) myThread.join(); if (myState) cn_destroy(myState); }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked = true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        if (!myState) return;
        Job j;
        j.file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        j.mode = (int)in->getParInt("Mode");            // 0=Depth 1=Rendered
        j.time = std::clamp((double)in->getParDouble("Position"), 0.0, 1.0);
        j.fnum = (float)in->getParDouble("Fnumber");
        j.focus = (float)in->getParDouble("Focus");     // 0=script準拠, else 上書き
        j.flip = in->getParInt("Flip") != 0;
        j.norm = in->getParInt("Normalize") != 0;
        if (j.file != myFile) { myFile = j.file; if (!j.file.empty()) cn_open(myState, j.file.c_str()); }

        // status
        std::string st, err;
        { const char* s = cn_status(myState); if (s) { std::string all(s); free((void*)s);
            size_t a=all.find('|'); size_t c=all.rfind('|');
            if(a!=std::string::npos&&c!=std::string::npos){ st=all.substr(0,a); err=all.substr(c+1);} } }
        myStatus = st; myErr = err;

        // ジョブ投入(ready時・変化時)
        char b[256]; snprintf(b,sizeof b,"%d|%.5f|%.3f|%.4f|%d|%d",j.mode,j.time,j.fnum,j.focus,j.flip?1:0,j.norm?1:0);
        std::string sig = j.file + "|" + b;
        if (st == "ready" && sig != mySig) {
            mySig = sig;
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) { myJob = j; myPending = true; mySubmit++; l.unlock(); myCond.notify_one(); }
            else mySig.clear();
        }

        // 最新結果をアップロード
        int mode = j.mode;
        int lw=0, lh=0; unsigned long long serial=0;
        bool has = mode == 0 ? cn_latest_depth_info(myState,&lw,&lh,&serial) : cn_latest_render_info(myState,&lw,&lh,&serial);
        if (!has || serial == myUploaded || lw <= 0 || lh <= 0) return;
        if (mode == 0) {
            TOP_UploadInfo ui; ui.textureDesc.texDim=OP_TexDim::e2D; ui.textureDesc.width=lw; ui.textureDesc.height=lh; ui.textureDesc.pixelFormat=OP_PixelFormat::Mono32Float;
            auto buf = myContext->createOutputBuffer((size_t)lw*lh*sizeof(float), TOP_BufferFlags::None, nullptr); if(!buf) return;
            cn_copy_depth(myState, buf->data); out->uploadBuffer(&buf, ui, nullptr);
        } else {
            TOP_UploadInfo ui; ui.textureDesc.texDim=OP_TexDim::e2D; ui.textureDesc.width=lw; ui.textureDesc.height=lh; ui.textureDesc.pixelFormat=OP_PixelFormat::RGBA16Float;
            auto buf = myContext->createOutputBuffer((size_t)lw*lh*4*sizeof(uint16_t), TOP_BufferFlags::None, nullptr); if(!buf) return;
            cn_copy_render(myState, buf->data); out->uploadBuffer(&buf, ui, nullptr);
        }
        myUploaded = serial; myFrames++;
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "Cinematic";
        { OP_StringParameter p("File"); p.label = "Cinematic Video (iPhone)"; p.page = PAGE; m->appendFile(p); }
        { OP_StringParameter p("Mode"); p.label = "Mode"; p.page = PAGE;
          const char* n[] = {"Depth","Rendered"}; const char* l[] = {"Depth (disparity map)","Rendered (change focus/aperture)"};
          std::vector<const char*> nv(n,n+2), lv(l,l+2); p.defaultValue="Rendered"; m->appendMenu(p,2,nv.data(),lv.data()); }
        { OP_NumericParameter p("Position"); p.label="Position (0..1)"; p.page=PAGE; p.defaultValues[0]=0; p.minSliders[0]=0; p.maxSliders[0]=1; p.minValues[0]=0; p.maxValues[0]=1; p.clampMins[0]=p.clampMaxes[0]=true; m->appendFloat(p); }
        { OP_NumericParameter p("Fnumber"); p.label="Aperture (f-number)"; p.page=PAGE; p.defaultValues[0]=4.0; p.minSliders[0]=2; p.maxSliders[0]=16; m->appendFloat(p); }
        { OP_NumericParameter p("Focus"); p.label="Focus Disparity Override (0=use script)"; p.page=PAGE; p.defaultValues[0]=0; p.minSliders[0]=0; p.maxSliders[0]=1; m->appendFloat(p); }
        { OP_NumericParameter p("Normalize"); p.label="Normalize Depth (0..1)"; p.page=PAGE; p.defaultValues[0]=1; m->appendToggle(p); }
        { OP_NumericParameter p("Flip"); p.label="Flip Vertically"; p.page=PAGE; p.defaultValues[0]=1; m->appendToggle(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        int ready = (myStatus == "ready") ? 1 : 0;
        const char* n[] = {"executes","submits","frames","ready"};
        float v[] = {(float)myExec.load(),(float)mySubmit.load(),(float)myFrames.load(),(float)ready};
        c->name->setString(n[i]); c->value = v[i];
    }
    void getWarningString(OP_String* s, void*) override { if (myStatus == "error" && !myErr.empty()) s->setString(("Cinematic: " + myErr).c_str()); }

private:
    void worker() {
        while (true) {
            Job j;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l, [this]{ return myQuit || myPending; }); if (myQuit) return; j = myJob; myPending = false; myBusy = true; }
            if (j.mode == 0) cn_depth(myState, j.time, j.flip?1:0, j.norm?1:0);
            else cn_render(myState, j.time, j.fnum, j.focus, j.flip?1:0);
            { std::lock_guard<std::mutex> l(myMutex); myBusy = false; }
        }
    }

    TOP_Context* myContext; void* myState = nullptr;
    std::thread myThread; std::condition_variable myCond; std::mutex myMutex;
    bool myQuit=false, myPending=false, myBusy=false;
    Job myJob; std::string myFile, mySig, myStatus, myErr; unsigned long long myUploaded=0;
    std::atomic<uint64_t> myExec{0}, mySubmit{0}, myFrames{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Cinematicvideo");
    i->customOPInfo.opLabel->setString("Cinematic Video");
    i->customOPInfo.opIcon->setString("CNV");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/Cinematic/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs = 0; i->customOPInfo.maxInputs = 0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new CinematicVideoTOP(i, c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<CinematicVideoTOP*>(i); }
}
