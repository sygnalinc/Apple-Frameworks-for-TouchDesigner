// CoreImage HDR TOP — HEIC等のHDRゲインマップを扱う。SDRベース / ゲインマップ / HDR拡張(EDR)を
// 切り替えて RGBA16Float TOP として出力する。
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include "../common/NonCommercialLimit.h"
using namespace TD;

namespace {
struct Result { std::vector<uint16_t> p; uint32_t w = 0, h = 0; uint64_t serial = 0; float maxv = 0; };

class CoreImageHDRTOP final : public TOP_CPlusPlusBase {
public:
    CoreImageHDRTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c) { myThread = std::thread([this]{ worker(); }); }
    ~CoreImageHDRTOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit = true; } myCond.notify_all(); if (myThread.joinable()) myThread.join(); }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked = true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        std::string file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        int mode = (int)in->getParInt("Mode");
        bool flip = in->getParInt("Flip") != 0;
        bool applyOri = in->getParInt("Applyorientation") != 0;
        std::string sig = file + "|" + std::to_string(mode) + "|" + (flip ? "1" : "0") + (applyOri ? "1" : "0");
        if (sig != mySig) {
            mySig = sig;
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) { myFile = file; myMode = mode; myFlip = flip; myApplyOri = applyOri; myPending = true; mySubmit++; l.unlock(); myCond.notify_one(); }
            else mySig.clear();
        }
        Result r;
        { std::lock_guard<std::mutex> l(myMutex); if (myResult.p.empty()) return; r = myResult; myUploaded = r.serial; }
        // NC の 1280x1280 上限に収めてから宣言する（超えたまま渡すと TD が
        // クランプ後の幅でバッファを読み、絵が斜めに崩れる）
        if (tdnc::fit(r.p, r.w, r.h, OP_PixelFormat::RGBA16Float)) myWarning = tdnc::kWarning;

        TOP_UploadInfo ui;
        ui.textureDesc.texDim = OP_TexDim::e2D;
        ui.textureDesc.width = r.w; ui.textureDesc.height = r.h;
        ui.textureDesc.pixelFormat = OP_PixelFormat::RGBA16Float;
        auto b = myContext->createOutputBuffer((size_t)r.w * r.h * 4 * sizeof(uint16_t), TOP_BufferFlags::None, nullptr);
        if (!b) return;
        memcpy(b->data, r.p.data(), r.p.size() * sizeof(uint16_t));
        out->uploadBuffer(&b, ui, nullptr);
        myMax = r.maxv;
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "CoreImage HDR";
        { OP_StringParameter p("File"); p.label = "Image File (HEIC with HDR gain map)"; p.page = PAGE; m->appendFile(p); }
        { OP_StringParameter p("Mode"); p.label = "Mode"; p.page = PAGE;
          const char* n[] = {"Sdr","Gainmap","Hdr"}; const char* l[] = {"SDR base","Gain Map","HDR (expand / EDR)"};
          std::vector<const char*> nv(n,n+3), lv(l,l+3); p.defaultValue = "Hdr"; m->appendMenu(p, 3, nv.data(), lv.data()); }
        { OP_NumericParameter p("Flip"); p.label = "Flip Vertically"; p.page = PAGE; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Applyorientation"); p.label = "Apply EXIF Orientation"; p.page = PAGE; p.defaultValues[0] = 1; m->appendToggle(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[] = {"executes","submits","loads","valid","max_value"};
        float v[] = {(float)myExec.load(),(float)mySubmit.load(),(float)myLoad.load(),myValid?1.f:0.f,myMax.load()};
        c->name->setString(n[i]); c->value = v[i];
    }
    void getWarningString(OP_String* s, void*) override { std::lock_guard<std::mutex> l(myMutex); if (!myWarning.empty()) s->setString(myWarning.c_str()); }

private:
    void worker() {
        while (true) {
            std::string file; int mode; bool flip, applyOri;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l, [this]{ return myQuit || myPending; }); if (myQuit) return; file = myFile; mode = myMode; flip = myFlip; applyOri = myApplyOri; myPending = false; myBusy = true; }
            Result r; std::string w; bool ok = load(file, mode, flip, applyOri, r, w);
            myLoad++; myValid = ok;
            { std::lock_guard<std::mutex> l(myMutex); if (ok) { r.serial = ++mySerial; myResult = std::move(r); } myWarning = std::move(w); myBusy = false; }
        }
    }

    static bool load(const std::string& file, int mode, bool flip, bool applyOrientation, Result& r, std::string& w) {
        @autoreleasepool {
            @synchronized([CIFilter class]) {
                if (file.empty()) { w = "No file"; return false; }
                NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:file.c_str()]];
                // 撮影時のカメラの向き(EXIF Orientation)を反映する。off だとセンサーそのままの
                // 向きで出るので、縦位置で撮った写真は横倒しになる(実測: orientation=6 の HEIC で
                // 4032x3024 のまま。適用すると 3024x4032)
                NSMutableDictionary* opts = [NSMutableDictionary dictionary];
                opts[kCIImageApplyOrientationProperty] = applyOrientation ? @YES : @NO;
                if (mode == 1) opts[kCIImageAuxiliaryHDRGainMap] = @YES;
                else if (mode == 2) opts[kCIImageExpandToHDR] = @YES;
                CIImage* img = [CIImage imageWithContentsOfURL:url options:opts];
                if (!img && mode == 1) { w = "No HDR gain map in this file"; return false; }
                if (!img) { w = "Cannot open image"; return false; }
                CGRect e = img.extent;
                if (e.size.width < 1 || e.size.height < 1 || !std::isfinite(e.size.width)) { w = "Empty image"; return false; }
                uint32_t W = (uint32_t)e.size.width, H = (uint32_t)e.size.height;
                r.w = W; r.h = H; r.p.resize((size_t)W * H * 4);
                CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
                CIContext* ctx = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace : (__bridge id)cs }];
                // float32で描画して最大値を測り、float16へ格納
                std::vector<float> f((size_t)W * H * 4);
                [ctx render:img toBitmap:f.data() rowBytes:(size_t)W * 4 * sizeof(float) bounds:e format:kCIFormatRGBAf colorSpace:cs];
                float mx = 0; for (float v : f) if (v > mx) mx = v;
                r.maxv = mx;
                // float32 → float16
                for (size_t k = 0; k < f.size(); k++) r.p[k] = float16(f[k]);
                CGColorSpaceRelease(cs);
                if (flip) { size_t rb = (size_t)W * 4; std::vector<uint16_t> tmp(rb);
                    for (uint32_t y = 0; y < H / 2; y++) { uint16_t* a = r.p.data() + (size_t)y * rb; uint16_t* b2 = r.p.data() + (size_t)(H - 1 - y) * rb; memcpy(tmp.data(), a, rb * 2); memcpy(a, b2, rb * 2); memcpy(b2, tmp.data(), rb * 2); } }
                return true;
            }
        }
    }

    static uint16_t float16(float f) {
        uint32_t x; memcpy(&x, &f, 4);
        uint16_t s = (x >> 16) & 0x8000; int e = (int)((x >> 23) & 0xff) - 127 + 15; uint16_t m = (x >> 13) & 0x3ff;
        if (e <= 0) return s; if (e >= 31) return s | 0x7c00; return s | (uint16_t)(e << 10) | m;
    }

    TOP_Context* myContext; std::thread myThread; std::condition_variable myCond; std::mutex myMutex;
    bool myQuit = false, myPending = false, myBusy = false, myFlip = true, myApplyOri = true;
    std::string myFile, mySig, myWarning; int myMode = 2;
    Result myResult; uint64_t mySerial = 0, myUploaded = 0;
    std::atomic<uint64_t> myExec{0}, mySubmit{0}, myLoad{0}; std::atomic<bool> myValid{false}; std::atomic<float> myMax{0};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Cihdr");
    i->customOPInfo.opLabel->setString("CI HDR");
    i->customOPInfo.opIcon->setString("CIH");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/CoreImageHDR/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 0;
    i->customOPInfo.maxInputs = 0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new CoreImageHDRTOP(i, c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<CoreImageHDRTOP*>(i); }
}
