// ImageIO Depth TOP — iPhone写真等に埋め込まれた深度/視差/Portrait Matte/セマンティックマットを
// ImageIO の補助データ(AVDepthData由来)から取り出し、Mono32Float TOP として出力する。
// ファイル入力のソースTOP。cook はブロックせずワーカーで抽出する。
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreVideo/CoreVideo.h>
#import <Accelerate/Accelerate.h>
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
struct Result { std::vector<float> p; uint32_t w = 0, h = 0; uint64_t serial = 0; float lo = 0, hi = 1; std::string kind; };

// 補助データ種別(パラメータのメニュー順)
static CFStringRef auxTypeFor(int idx) {
    switch (idx) {
        case 0: return nullptr; // Auto
        case 1: return kCGImageAuxiliaryDataTypeDisparity;
        case 2: return kCGImageAuxiliaryDataTypeDepth;
        case 3: return kCGImageAuxiliaryDataTypePortraitEffectsMatte;
        case 4: return kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte;
        case 5: return kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte;
        case 6: return kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte;
        case 7: return kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte;
        case 8: return kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte;
        default: return nullptr;
    }
}

class ImageIODepthTOP final : public TOP_CPlusPlusBase {
public:
    ImageIODepthTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c) { myThread = std::thread([this]{ worker(); }); }
    ~ImageIODepthTOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit = true; } myCond.notify_all(); if (myThread.joinable()) myThread.join(); }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked = true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        std::string file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        int type = (int)in->getParInt("Datatype");
        bool norm = in->getParInt("Normalize") != 0;
        std::string sig = file + "|" + std::to_string(type) + "|" + (norm ? "1" : "0");
        if (sig != mySig) {
            mySig = sig;
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) {
                myFile = file; myType = type; myNorm = norm; myPending = true; mySubmit++;
                l.unlock(); myCond.notify_one();
            } else { mySig.clear(); } // 取れなければ次フレーム再試行
        }

        Result r;
        { std::lock_guard<std::mutex> l(myMutex); if (myResult.serial == myUploaded || myResult.p.empty()) return; r = myResult; myUploaded = r.serial; }
        TOP_UploadInfo ui;
        ui.textureDesc.texDim = OP_TexDim::e2D;
        ui.textureDesc.width = r.w; ui.textureDesc.height = r.h;
        ui.textureDesc.pixelFormat = OP_PixelFormat::Mono32Float;
        auto b = myContext->createOutputBuffer((size_t)r.w * r.h * sizeof(float), TOP_BufferFlags::None, nullptr);
        if (!b) return;
        memcpy(b->data, r.p.data(), r.p.size() * sizeof(float));
        out->uploadBuffer(&b, ui, nullptr);
        myLo = r.lo; myHi = r.hi; { std::lock_guard<std::mutex> l(myMutex); myKind = r.kind; }
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "ImageIO Depth";
        { OP_StringParameter p("File"); p.label = "Image File (HEIC / JPEG with depth)"; p.page = PAGE; m->appendFile(p); }
        { OP_StringParameter p("Datatype"); p.label = "Data Type"; p.page = PAGE;
          const char* names[] = {"Auto","Disparity","Depth","Portraitmatte","Skinmatte","Hairmatte","Skymatte","Teethmatte","Glassesmatte"};
          const char* labels[] = {"Auto (disparity→depth→matte)","Disparity","Depth","Portrait Matte","Semantic: Skin","Semantic: Hair","Semantic: Sky","Semantic: Teeth","Semantic: Glasses"};
          std::vector<const char*> nv(names, names+9), lv(labels, labels+9);
          p.defaultValue = "Auto"; m->appendMenu(p, 9, nv.data(), lv.data()); }
        { OP_NumericParameter p("Normalize"); p.label = "Normalize (auto min-max → 0..1)"; p.page = PAGE; p.defaultValues[0] = 1; m->appendToggle(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 6; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[] = {"executes","submits","extracts","valid","range_min","range_max"};
        float v[] = {(float)myExec.load(),(float)mySubmit.load(),(float)myExtract.load(),myValid?1.f:0.f,myLo.load(),myHi.load()};
        c->name->setString(n[i]); c->value = v[i];
    }
    void getWarningString(OP_String* s, void*) override { std::lock_guard<std::mutex> l(myMutex); if (!myWarning.empty()) s->setString(myWarning.c_str()); }

private:
    void worker() {
        while (true) {
            std::string file; int type; bool norm;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l, [this]{ return myQuit || myPending; });
              if (myQuit) return; file = myFile; type = myType; norm = myNorm; myPending = false; myBusy = true; }
            Result r; std::string w;
            bool ok = extract(file, type, norm, r, w);
            myExtract++; myValid = ok;
            { std::lock_guard<std::mutex> l(myMutex); if (ok) { r.serial = ++mySerial; myResult = std::move(r); } myWarning = std::move(w); myBusy = false; }
        }
    }

    static bool loadAux(CGImageSourceRef src, CFStringRef type, std::vector<float>& out, uint32_t& W, uint32_t& H, std::string& kind, std::string& w) {
        CFDictionaryRef aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, type);
        if (!aux) return false;
        CFDataRef data = (CFDataRef)CFDictionaryGetValue(aux, kCGImageAuxiliaryDataInfoData);
        CFDictionaryRef desc = (CFDictionaryRef)CFDictionaryGetValue(aux, kCGImageAuxiliaryDataInfoDataDescription);
        if (!data || !desc) { CFRelease(aux); return false; }
        auto geti = [&](CFStringRef k)->long { CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(desc, k); long v = 0; if (n) CFNumberGetValue(n, kCFNumberLongType, &v); return v; };
        long w0 = geti(CFSTR("Width")), h0 = geti(CFSTR("Height")), bpr = geti(CFSTR("BytesPerRow")), pf = geti(CFSTR("PixelFormat"));
        if (w0 <= 0 || h0 <= 0) { CFRelease(aux); return false; }
        W = (uint32_t)w0; H = (uint32_t)h0;
        const uint8_t* bytes = CFDataGetBytePtr(data);
        out.resize((size_t)W * H);
        OSType fmt = (OSType)pf;
        if (fmt == kCVPixelFormatType_DisparityFloat16 || fmt == kCVPixelFormatType_DepthFloat16) {
            // float16 → float32(行ごと、bytesPerRowを考慮)
            for (uint32_t y = 0; y < H; y++) {
                vImage_Buffer sb{ (void*)(bytes + (size_t)y * bpr), 1, W, (size_t)W * 2 };
                vImage_Buffer db{ out.data() + (size_t)y * W, 1, W, (size_t)W * 4 };
                vImageConvert_Planar16FtoPlanarF(&sb, &db, 0);
            }
            kind = "float16";
        } else if (fmt == kCVPixelFormatType_DisparityFloat32 || fmt == kCVPixelFormatType_DepthFloat32) {
            for (uint32_t y = 0; y < H; y++) memcpy(out.data() + (size_t)y * W, bytes + (size_t)y * bpr, (size_t)W * 4);
            kind = "float32";
        } else {
            // 8bit matte 等 → 0..1
            for (uint32_t y = 0; y < H; y++) { const uint8_t* row = bytes + (size_t)y * bpr; float* o = out.data() + (size_t)y * W; for (uint32_t x = 0; x < W; x++) o[x] = row[x] / 255.f; }
            kind = "uint8";
        }
        CFRelease(aux);
        return true;
    }

    static bool extract(const std::string& file, int type, bool norm, Result& r, std::string& w) {
        @autoreleasepool {
            if (file.empty()) { w = "No file"; return false; }
            NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:file.c_str()]];
            CGImageSourceRef src = CGImageSourceCreateWithURL((CFURLRef)url, nullptr);
            if (!src) { w = "Cannot open file"; return false; }
            std::vector<float> vals; uint32_t W = 0, H = 0; std::string kind;
            bool ok = false;
            if (type == 0) {
                CFStringRef order[] = { kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypePortraitEffectsMatte };
                for (int i = 0; i < 3 && !ok; i++) ok = loadAux(src, order[i], vals, W, H, kind, w);
            } else {
                CFStringRef t = auxTypeFor(type);
                if (t) ok = loadAux(src, t, vals, W, H, kind, w);
            }
            CFRelease(src);
            if (!ok) { if (w.empty()) w = "No depth/matte data in this file"; return false; }
            // 正規化(表示用) / 生値
            float lo = vals[0], hi = vals[0];
            for (float v : vals) { if (v < lo) lo = v; if (v > hi) hi = v; }
            r.lo = lo; r.hi = hi;
            if (norm && hi > lo) { float inv = 1.f / (hi - lo); for (float& v : vals) v = (v - lo) * inv; }
            // TOPは bottom-up。行反転してアップロード(上下正立)
            r.w = W; r.h = H; r.p.resize((size_t)W * H); r.kind = kind;
            for (uint32_t y = 0; y < H; y++) memcpy(r.p.data() + (size_t)(H - 1 - y) * W, vals.data() + (size_t)y * W, (size_t)W * sizeof(float));
            return true;
        }
    }

    TOP_Context* myContext; std::thread myThread; std::condition_variable myCond; std::mutex myMutex;
    bool myQuit = false, myPending = false, myBusy = false, myNorm = true;
    std::string myFile, mySig, myWarning, myKind; int myType = 0;
    Result myResult; uint64_t mySerial = 0, myUploaded = 0;
    std::atomic<uint64_t> myExec{0}, mySubmit{0}, myExtract{0}; std::atomic<bool> myValid{false};
    std::atomic<float> myLo{0}, myHi{1};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Imageiodepth");
    i->customOPInfo.opLabel->setString("ImageIO Depth");
    i->customOPInfo.opIcon->setString("IID");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs = 0;
    i->customOPInfo.maxInputs = 0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new ImageIODepthTOP(i, c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<ImageIODepthTOP*>(i); }
}
