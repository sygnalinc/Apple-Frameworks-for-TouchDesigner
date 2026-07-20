// Quick Look TOP — 任意ファイル(PDF/動画/3D/書類/画像等)を QuickLookThumbnailing で
// OS標準のサムネイル画像にして BGRA8 TOP として出力する。cook はブロックせずワーカーで生成。
#import <Foundation/Foundation.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
struct Result { std::vector<uint8_t> bgra; uint32_t w=0,h=0; uint64_t serial=0; bool ok=false; };

class QuickLookTOP final : public TOP_CPlusPlusBase {
public:
    QuickLookTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c) { myThread=std::thread([this]{ worker(); }); }
    ~QuickLookTOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit=true; } myCond.notify_all(); if(myThread.joinable()) myThread.join(); }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked=true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        std::string file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        int w=(int)in->getParInt("Width"), h=(int)in->getParInt("Height");
        int icon = in->getParInt("Iconmode");
        std::string sig=file+"|"+std::to_string(w)+"|"+std::to_string(h)+"|"+std::to_string(icon);
        if (sig!=mySig) {
            mySig=sig;
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) { myFile=file; myW=w; myH=h; myIcon=icon; myPending=true; mySubmit++; l.unlock(); myCond.notify_one(); }
            else mySig.clear();
        }
        Result r;
        { std::lock_guard<std::mutex> l(myMutex); if (myResult.serial==myUploaded || !myResult.ok || myResult.bgra.empty()) return; r=myResult; myUploaded=r.serial; }
        TOP_UploadInfo ui; ui.textureDesc.texDim=OP_TexDim::e2D; ui.textureDesc.width=r.w; ui.textureDesc.height=r.h;
        ui.textureDesc.pixelFormat=OP_PixelFormat::BGRA8Fixed;
        auto b=myContext->createOutputBuffer((size_t)r.w*r.h*4, TOP_BufferFlags::None, nullptr);
        if(!b) return;
        memcpy(b->data, r.bgra.data(), r.bgra.size());
        out->uploadBuffer(&b, ui, nullptr);
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="Quick Look";
        { OP_StringParameter p("File"); p.label="File"; p.page=P; m->appendFile(p); }
        { OP_NumericParameter p("Width"); p.label="Width"; p.page=P; p.defaultValues[0]=512; p.minSliders[0]=16; p.maxSliders[0]=2048; p.minValues[0]=1; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Height"); p.label="Height"; p.page=P; p.defaultValues[0]=512; p.minSliders[0]=16; p.maxSliders[0]=2048; p.minValues[0]=1; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Iconmode"); p.label="Icon Mode (badge/frame)"; p.page=P; p.defaultValues[0]=0; m->appendToggle(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","submits","width","height"};
        float v[]={(float)myExec.load(),(float)mySubmit.load(),(float)myOutW,(float)myOutH};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if(!myWarn.empty()) s->setString(myWarn.c_str()); }

private:
    void worker() {
        for(;;){
            std::string file; int w,h,icon;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l,[this]{return myPending||myQuit;}); if(myQuit) return; myBusy=true; myPending=false; file=myFile; w=myW; h=myH; icon=myIcon; }
            Result r; r.serial=++mySerial;
            @autoreleasepool {
                if (!file.empty()) {
                    NSURL* url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:file.c_str()]];
                    QLThumbnailGenerationRequestRepresentationTypes types = icon ? QLThumbnailGenerationRequestRepresentationTypeIcon : (QLThumbnailGenerationRequestRepresentationTypeThumbnail|QLThumbnailGenerationRequestRepresentationTypeLowQualityThumbnail);
                    QLThumbnailGenerationRequest* req=[[QLThumbnailGenerationRequest alloc] initWithFileAtURL:url size:CGSizeMake(w,h) scale:1.0 representationTypes:types];
                    dispatch_semaphore_t sem=dispatch_semaphore_create(0);
                    __block CGImageRef cg=NULL; __block std::string err;
                    [[QLThumbnailGenerator sharedGenerator] generateBestRepresentationForRequest:req completionHandler:^(QLThumbnailRepresentation* rep, NSError* e){
                        if (rep) cg=CGImageRetain(rep.CGImage); else if (e) err=e.localizedDescription.UTF8String;
                        dispatch_semaphore_signal(sem);
                    }];
                    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15*NSEC_PER_SEC));
                    if (cg) {
                        int iw=(int)CGImageGetWidth(cg), ih=(int)CGImageGetHeight(cg);
                        r.bgra.assign((size_t)iw*ih*4, 0);
                        CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
                        CGContextRef ctx=CGBitmapContextCreate(r.bgra.data(), iw, ih, 8, iw*4, cs, kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
                        // TOPは bottom-up。上下反転して描画
                        CGContextTranslateCTM(ctx, 0, ih); CGContextScaleCTM(ctx, 1, -1);
                        CGContextDrawImage(ctx, CGRectMake(0,0,iw,ih), cg);
                        CGContextRelease(ctx); CGColorSpaceRelease(cs); CGImageRelease(cg);
                        r.w=iw; r.h=ih; r.ok=true;
                    } else { std::lock_guard<std::mutex> l(myMutex); myWarn = err.empty()?"thumbnail failed":err; }
                }
            }
            { std::lock_guard<std::mutex> l(myMutex); myResult=r; if(r.ok){ myOutW=r.w; myOutH=r.h; myWarn.clear(); } myBusy=false; }
        }
    }

    TOP_Context* myContext=nullptr;
    std::thread myThread; std::mutex myMutex; std::condition_variable myCond;
    bool myPending=false, myBusy=false, myQuit=false;
    std::string myFile, mySig, myWarn; int myW=512,myH=512,myIcon=0; int myOutW=0,myOutH=0;
    Result myResult; uint64_t myUploaded=0; std::atomic<uint64_t> mySerial{0}, myExec{0}, mySubmit{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode=TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Quicklook");
    i->customOPInfo.opLabel->setString("Quick Look");
    i->customOPInfo.opIcon->setString("QLK");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new QuickLookTOP(i,c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<QuickLookTOP*>(i); }
}
