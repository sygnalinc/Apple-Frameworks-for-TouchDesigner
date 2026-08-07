// CoreImage RAW TOP — DNG / Apple ProRAW / カメラRAW を CIRAWFilter でリアルタイム現像し、
// RGBA16Float TOP として出力する。露出・WB・ノイズ除去・シャープ・コントラストを調整可能。
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
using namespace TD;

namespace {
struct Params { std::string file; float exposure, boost, temp, tint, lumaNR, colorNR, sharpen, contrast, scale; bool flip; };
struct Result { std::vector<uint16_t> p; uint32_t w = 0, h = 0; uint64_t serial = 0; };

class CoreImageRAWTOP final : public TOP_CPlusPlusBase {
public:
    CoreImageRAWTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c) { myThread = std::thread([this]{ worker(); }); }
    ~CoreImageRAWTOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit = true; } myCond.notify_all(); if (myThread.joinable()) myThread.join(); }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked = true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        Params p;
        p.file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        p.exposure = (float)in->getParDouble("Exposure");
        p.boost = (float)in->getParDouble("Boost");
        p.temp = (float)in->getParDouble("Temperature");
        p.tint = (float)in->getParDouble("Tint");
        p.lumaNR = (float)in->getParDouble("Lumanr");
        p.colorNR = (float)in->getParDouble("Colornr");
        p.sharpen = (float)in->getParDouble("Sharpen");
        p.contrast = (float)in->getParDouble("Contrast");
        p.scale = (float)in->getParDouble("Scale");
        p.flip = in->getParInt("Flip") != 0;
        char buf[256]; snprintf(buf, sizeof buf, "%s|%.3f|%.3f|%.1f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%d",
            p.file.c_str(), p.exposure, p.boost, p.temp, p.tint, p.lumaNR, p.colorNR, p.sharpen, p.contrast, p.scale, p.flip ? 1 : 0);
        std::string sig = buf;
        if (sig != mySig) {
            mySig = sig;
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) { myParams = p; myPending = true; mySubmit++; l.unlock(); myCond.notify_one(); }
            else mySig.clear();
        }
        Result r;
        { std::lock_guard<std::mutex> l(myMutex); if (myResult.p.empty()) return; r = myResult; myUploaded = r.serial; }
        TOP_UploadInfo ui;
        ui.textureDesc.texDim = OP_TexDim::e2D;
        ui.textureDesc.width = r.w; ui.textureDesc.height = r.h;
        ui.textureDesc.pixelFormat = OP_PixelFormat::RGBA16Float;
        auto b = myContext->createOutputBuffer((size_t)r.w * r.h * 4 * sizeof(uint16_t), TOP_BufferFlags::None, nullptr);
        if (!b) return;
        memcpy(b->data, r.p.data(), r.p.size() * sizeof(uint16_t));
        out->uploadBuffer(&b, ui, nullptr);
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "CoreImage RAW";
        { OP_StringParameter p("File"); p.label = "RAW File (DNG / ProRAW / camera RAW)"; p.page = PAGE; m->appendFile(p); }
        auto f = [&](const char* n, const char* l, double d, double lo, double hi) { OP_NumericParameter p(n); p.label = l; p.page = PAGE; p.defaultValues[0] = d; p.minSliders[0] = lo; p.maxSliders[0] = hi; m->appendFloat(p); };
        f("Exposure", "Exposure (EV)", 0.0, -3.0, 3.0);
        f("Boost", "Boost (shadow/tone)", 1.0, 0.0, 1.0);
        f("Temperature", "Neutral Temperature (K)", 6500.0, 3000.0, 9000.0);
        f("Tint", "Neutral Tint", 0.0, -100.0, 100.0);
        f("Lumanr", "Luminance Noise Reduction", 0.5, 0.0, 1.0);
        f("Colornr", "Color Noise Reduction", 0.5, 0.0, 1.0);
        f("Sharpen", "Sharpness", 0.5, 0.0, 2.0);
        f("Contrast", "Contrast", 1.0, 0.0, 2.0);
        f("Scale", "Scale Factor", 1.0, 0.1, 1.0);
        { OP_NumericParameter p("Flip"); p.label = "Flip Vertically"; p.page = PAGE; p.defaultValues[0] = 1; m->appendToggle(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 4; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[] = {"executes","submits","develops","valid"};
        float v[] = {(float)myExec.load(),(float)mySubmit.load(),(float)myDevelop.load(),myValid?1.f:0.f};
        c->name->setString(n[i]); c->value = v[i];
    }
    void getWarningString(OP_String* s, void*) override { std::lock_guard<std::mutex> l(myMutex); if (!myWarning.empty()) s->setString(myWarning.c_str()); }

private:
    void worker() {
        while (true) {
            Params p;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l, [this]{ return myQuit || myPending; }); if (myQuit) return; p = myParams; myPending = false; myBusy = true; }
            Result r; std::string w; bool ok = develop(p, r, w);
            myDevelop++; myValid = ok;
            { std::lock_guard<std::mutex> l(myMutex); if (ok) { r.serial = ++mySerial; myResult = std::move(r); } myWarning = std::move(w); myBusy = false; }
        }
    }

    static bool develop(const Params& p, Result& r, std::string& w) {
        @autoreleasepool {
            @synchronized([CIFilter class]) {
                if (p.file.empty()) { w = "No RAW file"; return false; }
                NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:p.file.c_str()]];
                CIRAWFilter* f = [CIRAWFilter filterWithImageURL:url];
                if (!f) { w = "Not a supported RAW file"; return false; }
                f.exposure = p.exposure;
                f.boostAmount = p.boost;
                f.neutralTemperature = p.temp;
                f.neutralTint = p.tint;
                if (f.luminanceNoiseReductionSupported) f.luminanceNoiseReductionAmount = p.lumaNR;
                if (f.colorNoiseReductionSupported) f.colorNoiseReductionAmount = p.colorNR;
                if (f.sharpnessSupported) f.sharpnessAmount = p.sharpen;
                f.contrastAmount = p.contrast;
                f.scaleFactor = p.scale;
                CIImage* img = f.outputImage;
                if (!img) { w = "RAW develop produced no image"; return false; }
                CGRect e = img.extent;
                if (e.size.width < 1 || e.size.height < 1) { w = "Empty RAW output"; return false; }
                uint32_t W = (uint32_t)e.size.width, H = (uint32_t)e.size.height;
                r.w = W; r.h = H; r.p.resize((size_t)W * H * 4);
                CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
                CIContext* ctx = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace : (__bridge id)cs }];
                [ctx render:img toBitmap:r.p.data() rowBytes:(size_t)W * 4 * sizeof(uint16_t) bounds:e format:kCIFormatRGBA16 colorSpace:cs];
                CGColorSpaceRelease(cs);
                if (p.flip) { // Core Image出力(top-down) → TD正立へ行反転
                    size_t rb = (size_t)W * 4; std::vector<uint16_t> tmp(rb);
                    for (uint32_t y = 0; y < H / 2; y++) { uint16_t* a = r.p.data() + (size_t)y * rb; uint16_t* b2 = r.p.data() + (size_t)(H - 1 - y) * rb; memcpy(tmp.data(), a, rb * 2); memcpy(a, b2, rb * 2); memcpy(b2, tmp.data(), rb * 2); }
                }
                return true;
            }
        }
    }

    TOP_Context* myContext; std::thread myThread; std::condition_variable myCond; std::mutex myMutex;
    bool myQuit = false, myPending = false, myBusy = false;
    Params myParams; Result myResult; std::string mySig, myWarning; uint64_t mySerial = 0, myUploaded = 0;
    std::atomic<uint64_t> myExec{0}, mySubmit{0}, myDevelop{0}; std::atomic<bool> myValid{false};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Ciraw");
    i->customOPInfo.opLabel->setString("CI RAW");
    i->customOPInfo.opIcon->setString("CIR");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/CoreImageRAW/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 0;
    i->customOPInfo.maxInputs = 0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new CoreImageRAWTOP(i, c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<CoreImageRAWTOP*>(i); }
}
