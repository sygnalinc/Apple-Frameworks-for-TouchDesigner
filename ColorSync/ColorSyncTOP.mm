// ColorSync TOP — 入力TOPを ColorSync/ICC で色空間変換する(sRGB / Display P3 / Adobe RGB /
// Generic RGB/Gray / 任意 .icc プロファイル間)。CGColorSpace はICCプロファイル(ColorSync)で
// 色管理されるので、CGImage の描画による変換 = ColorSync 変換。表示装置別の色変換に使える。
// cook はブロックせずワーカーで変換する。
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
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
struct Buf { std::vector<uint8_t> bgra; uint32_t w=0,h=0; };
struct Result { std::vector<uint8_t> bgra; uint32_t w=0,h=0; uint64_t serial=0; };

static CGColorSpaceRef makeCS(const std::string& name, const std::string& file) {
    if (name=="File" && !file.empty()) {
        NSData* d=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:file.c_str()]];
        if (d) { CGColorSpaceRef c=CGColorSpaceCreateWithICCData((__bridge CFDataRef)d); if(c) return c; }
    }
    if (name=="Displayp3") return CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    if (name=="Adobergb")  return CGColorSpaceCreateWithName(kCGColorSpaceAdobeRGB1998);
    if (name=="Genericrgb")return CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);
    if (name=="Gray")      return CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    if (name=="Rec2020")   return CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020);
    return CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
}

class ColorSyncTOP final : public TOP_CPlusPlusBase {
public:
    ColorSyncTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c) { myThread=std::thread([this]{ worker(); }); }
    ~ColorSyncTOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit=true; } myCond.notify_all(); if(myThread.joinable()) myThread.join(); }
    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked=true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        bool active=in->getParInt("Active")!=0;
        std::string src=in->getParString("Source")?in->getParString("Source"):"Srgb";
        std::string dst=in->getParString("Dest")?in->getParString("Dest"):"Displayp3";
        std::string sfile=in->getParFilePath("Sourcefile")?in->getParFilePath("Sourcefile"):"";
        std::string dfile=in->getParFilePath("Destfile")?in->getParFilePath("Destfile"):"";
        std::string sig=src+"|"+dst+"|"+sfile+"|"+dfile;
        if (sig!=mySig){ mySig=sig; myLast=-1; }
        const OP_TOPInput* a=in->getInputTOP(0);
        if (active && a && (int64_t)a->totalCooks!=myLast) {
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) {
                OP_TOPInputDownloadOptions o; o.pixelFormat=OP_PixelFormat::BGRA8Fixed; o.verticalFlip=false;
                auto img=a->downloadTexture(o,nullptr);
                if (img) {
                    myIn.w=(uint32_t)img->textureDesc.width; myIn.h=(uint32_t)img->textureDesc.height;
                    size_t n=(size_t)myIn.w*myIn.h*4; myIn.bgra.assign(n,0);
                    const void* d=img->getData(); if(d) memcpy(myIn.bgra.data(), d, n);
                    mySrc=src; myDst=dst; mySrcFile=sfile; myDstFile=dfile;
                    myPending=true; myLast=a->totalCooks; mySubmit++; l.unlock(); myCond.notify_one();
                }
            }
        }
        Result r; { std::lock_guard<std::mutex> l(myMutex); if(myResult.serial==myUploaded||myResult.bgra.empty()) return; r=myResult; myUploaded=r.serial; }
        TOP_UploadInfo ui; ui.textureDesc.texDim=OP_TexDim::e2D; ui.textureDesc.width=r.w; ui.textureDesc.height=r.h; ui.textureDesc.pixelFormat=OP_PixelFormat::BGRA8Fixed;
        auto b=myContext->createOutputBuffer((size_t)r.w*r.h*4, TOP_BufferFlags::None, nullptr); if(!b) return;
        memcpy(b->data, r.bgra.data(), r.bgra.size()); out->uploadBuffer(&b, ui, nullptr);
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P="ColorSync";
        { OP_NumericParameter p("Active"); p.label="Active"; p.page=P; p.defaultValues[0]=1; m->appendToggle(p); }
        const char* n[]={"Srgb","Displayp3","Adobergb","Rec2020","Genericrgb","Gray","File"};
        const char* l[]={"sRGB","Display P3","Adobe RGB (1998)","Rec. 2020","Generic RGB","Generic Gray","ICC File"};
        { OP_StringParameter p("Source"); p.label="Source Space"; p.page=P; p.defaultValue="Srgb"; m->appendMenu(p,7,n,l); }
        { OP_StringParameter p("Dest"); p.label="Destination Space"; p.page=P; p.defaultValue="Displayp3"; m->appendMenu(p,7,n,l); }
        { OP_StringParameter p("Sourcefile"); p.label="Source ICC File"; p.page=P; m->appendFile(p); }
        { OP_StringParameter p("Destfile"); p.label="Destination ICC File"; p.page=P; m->appendFile(p); }
    }
    int32_t getNumInfoCHOPChans(void*) override { return 3; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[]={"executes","submits","converts"}; float v[]={(float)myExec.load(),(float)mySubmit.load(),(float)myConverts.load()};
        c->name->setString(n[i]); c->value=v[i];
    }
private:
    void worker() {
        for(;;){
            Buf src; std::string sn,dn,sf,df;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l,[this]{return myPending||myQuit;}); if(myQuit) return; myBusy=true; myPending=false; src=myIn; sn=mySrc; dn=myDst; sf=mySrcFile; df=myDstFile; }
            Result r; r.serial=++mySerial;
            @autoreleasepool {
                if (!src.bgra.empty()) {
                    int w=src.w, h=src.h;
                    CGColorSpaceRef sc=makeCS(sn,sf), dc=makeCS(dn,df);
                    if (sc && dc) {
                        // 入力BGRA8 → CGImage(source色空間)
                        CFDataRef cf=CFDataCreate(NULL, src.bgra.data(), (CFIndex)src.bgra.size());
                        CGDataProviderRef prov=CGDataProviderCreateWithCFData(cf);
                        CGImageRef inImg=CGImageCreate(w,h,8,32,w*4,sc, kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little, prov, NULL, false, kCGRenderingIntentDefault);
                        // dest色空間のコンテキストへ描画(CGがICC/ColorSync変換)
                        r.bgra.assign((size_t)w*h*4,0);
                        CGContextRef ctx=CGBitmapContextCreate(r.bgra.data(), w,h,8,w*4,dc, kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
                        if (inImg && ctx) { CGContextDrawImage(ctx, CGRectMake(0,0,w,h), inImg); r.w=w; r.h=h; myConverts++; }
                        if (ctx) CGContextRelease(ctx); if (inImg) CGImageRelease(inImg);
                        CGDataProviderRelease(prov); CFRelease(cf);
                    }
                    if (sc) CGColorSpaceRelease(sc); if (dc) CGColorSpaceRelease(dc);
                }
            }
            { std::lock_guard<std::mutex> l(myMutex); myResult=r; myBusy=false; }
        }
    }
    TOP_Context* myContext=nullptr; std::thread myThread; std::mutex myMutex; std::condition_variable myCond;
    bool myPending=false,myBusy=false,myQuit=false; int64_t myLast=-1;
    Buf myIn; std::string mySrc,myDst,mySrcFile,myDstFile,mySig;
    Result myResult; uint64_t myUploaded=0; std::atomic<uint64_t> mySerial{0},myExec{0},mySubmit{0},myConverts{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode=TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Colorsync");
    i->customOPInfo.opLabel->setString("ColorSync");
    i->customOPInfo.opIcon->setString("CSY");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/ColorSync/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs=1; i->customOPInfo.maxInputs=1;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new ColorSyncTOP(i,c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<ColorSyncTOP*>(i); }
}
