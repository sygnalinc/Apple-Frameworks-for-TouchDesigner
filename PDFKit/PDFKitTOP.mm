// PDF Document TOP — PDFKit で PDF の指定ページを BGRA8 TOP に描画する。DPI/ページ指定。
// cook はブロックせずワーカーで描画する。
#import <Foundation/Foundation.h>
#import <PDFKit/PDFKit.h>
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

class PDFKitTOP final : public TOP_CPlusPlusBase {
public:
    PDFKitTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c) { myThread=std::thread([this]{ worker(); }); }
    ~PDFKitTOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit=true; } myCond.notify_all(); if(myThread.joinable()) myThread.join(); }
    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked=true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        std::string file=in->getParFilePath("File")?in->getParFilePath("File"):"";
        int page=(int)in->getParInt("Page"); float dpi=(float)in->getParDouble("Dpi");
        std::string sig=file+"|"+std::to_string(page)+"|"+std::to_string((int)dpi);
        if (sig!=mySig){ mySig=sig; std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy){ myFile=file; myPage=page; myDpi=dpi; myPending=true; mySubmit++; l.unlock(); myCond.notify_one(); } else mySig.clear(); }
        Result r; { std::lock_guard<std::mutex> l(myMutex); if(myResult.serial==myUploaded||!myResult.ok||myResult.bgra.empty()) return; r=myResult; myUploaded=r.serial; }
        TOP_UploadInfo ui; ui.textureDesc.texDim=OP_TexDim::e2D; ui.textureDesc.width=r.w; ui.textureDesc.height=r.h; ui.textureDesc.pixelFormat=OP_PixelFormat::BGRA8Fixed;
        auto b=myContext->createOutputBuffer((size_t)r.w*r.h*4, TOP_BufferFlags::None, nullptr); if(!b) return;
        memcpy(b->data, r.bgra.data(), r.bgra.size()); out->uploadBuffer(&b, ui, nullptr);
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="PDFKit";
        { OP_StringParameter p("File"); p.label="PDF File"; p.page=P; m->appendFile(p); }
        { OP_NumericParameter p("Page"); p.label="Page (0-based)"; p.page=P; p.defaultValues[0]=0; p.minSliders[0]=0; p.maxSliders[0]=100; p.minValues[0]=0; p.clampMins[0]=true; m->appendInt(p); }
        { OP_NumericParameter p("Dpi"); p.label="DPI"; p.page=P; p.defaultValues[0]=150; p.minSliders[0]=36; p.maxSliders[0]=600; p.minValues[0]=1; p.clampMins[0]=true; m->appendFloat(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","width","height"}; float v[]={(float)myExec.load(),(float)myOutW,(float)myOutH};
        c->name->setString(n[i]); c->value=v[i];
    }
    void getWarningString(OP_String* s, void*) override { if(!myWarn.empty()) s->setString(myWarn.c_str()); }

private:
    void worker() {
        for(;;){
            std::string file; int page; float dpi;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l,[this]{return myPending||myQuit;}); if(myQuit) return; myBusy=true; myPending=false; file=myFile; page=myPage; dpi=myDpi; }
            Result r; r.serial=++mySerial;
            @autoreleasepool {
                if(!file.empty()){
                    NSURL* url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:file.c_str()]];
                    PDFDocument* doc=[[PDFDocument alloc] initWithURL:url];
                    if (!doc){ std::lock_guard<std::mutex> l(myMutex); myWarn="failed to open PDF"; }
                    else if (page<0||page>=(int)doc.pageCount){ std::lock_guard<std::mutex> l(myMutex); myWarn="page out of range"; }
                    else {
                        PDFPage* p=[doc pageAtIndex:page];
                        CGRect box=[p boundsForBox:kPDFDisplayBoxMediaBox];
                        float sc=dpi/72.f;
                        int iw=(int)ceilf(box.size.width*sc), ih=(int)ceilf(box.size.height*sc);
                        if (iw>0 && ih>0 && (long)iw*ih<=64L*1024*1024){
                            r.bgra.assign((size_t)iw*ih*4, 0);
                            CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
                            CGContextRef ctx=CGBitmapContextCreate(r.bgra.data(), iw, ih, 8, iw*4, cs, kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
                            CGContextSetRGBFillColor(ctx,1,1,1,1); CGContextFillRect(ctx, CGRectMake(0,0,iw,ih)); // 白背景
                            CGContextScaleCTM(ctx, sc, sc);
                            CGContextTranslateCTM(ctx, -box.origin.x, -box.origin.y);
                            [p drawWithBox:kPDFDisplayBoxMediaBox toContext:ctx];
                            CGContextRelease(ctx); CGColorSpaceRelease(cs);
                            r.w=iw; r.h=ih; r.ok=true;
                        }
                    }
                }
            }
            { std::lock_guard<std::mutex> l(myMutex); myResult=r; if(r.ok){ myOutW=r.w; myOutH=r.h; myWarn.clear(); } myBusy=false; }
        }
    }
    TOP_Context* myContext=nullptr; std::thread myThread; std::mutex myMutex; std::condition_variable myCond;
    bool myPending=false,myBusy=false,myQuit=false;
    std::string myFile,mySig,myWarn; int myPage=0; float myDpi=150; int myOutW=0,myOutH=0;
    Result myResult; uint64_t myUploaded=0; std::atomic<uint64_t> mySerial{0},myExec{0},mySubmit{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode=TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Pdfkit");
    i->customOPInfo.opLabel->setString("PDFKit");
    i->customOPInfo.opIcon->setString("PDF");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs=0; i->customOPInfo.maxInputs=0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new PDFKitTOP(i,c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<PDFKitTOP*>(i); }
}
