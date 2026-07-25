// ImageIO File In TOP — 汎用の画像ファイル読み込みTOP(ImageIO)。TDのMovie File Inが
// 表示できないHEIF/HEIC等も表示でき、画像に埋め込まれた各種データを取り出せる:
//   Color(通常のRGB)/ Disparity / Depth / Portrait Matte / セマンティックマット
//   (skin/hair/sky/teeth/glasses)。
//
// ・Color は主画像を BGRA8 で出力(HEIF表示の代替)。
// ・深度/マットは補助データ(AVDepthData由来)を Mono32Float で出力。
// ・**EXIFの向き(Orientation 1〜8)を適用**して常に正立表示にする
//   (iPhoneの縦写真は横センサー+Orientation=6で保存され、未対応だと横倒しになる)。
// cook はブロックせずワーカーで抽出する。
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
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
struct Result {
    std::vector<uint8_t> bytes;   // color=BGRA8 / depth=float32(いずれも4byte/px)
    uint32_t w = 0, h = 0;
    uint64_t serial = 0;
    bool color = false;
    float lo = 0, hi = 1;
    std::string kind;
};

// Data Type メニュー index → 補助データ種別(0=Color, 1=Auto は別扱い)
static CFStringRef auxTypeFor(int idx) {
    switch (idx) {
        case 2: return kCGImageAuxiliaryDataTypeDisparity;
        case 3: return kCGImageAuxiliaryDataTypeDepth;
        case 4: return kCGImageAuxiliaryDataTypePortraitEffectsMatte;
        case 5: return kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte;
        case 6: return kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte;
        case 7: return kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte;
        case 8: return kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte;
        case 9: return kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte;
        default: return nullptr;   // 0 Color / 1 Auto
    }
}

// EXIF Orientation(1〜8)を適用して正立化する汎用リマップ(elem=4byte/px 運用)。
// src は top-down。出力 dst も top-down(表示寸法 dW×dH)。
static void applyOrientation(const uint8_t* src, uint32_t W, uint32_t H, int elem,
                             int orient, std::vector<uint8_t>& dst,
                             uint32_t& dW, uint32_t& dH) {
    const bool swap = (orient >= 5 && orient <= 8);
    dW = swap ? H : W;
    dH = swap ? W : H;
    dst.resize((size_t)dW * dH * elem);
    for (uint32_t dy = 0; dy < dH; dy++) {
        for (uint32_t dx = 0; dx < dW; dx++) {
            uint32_t sx, sy;
            switch (orient) {
                default:
                case 1: sx = dx;         sy = dy;         break;
                case 2: sx = W - 1 - dx; sy = dy;         break;
                case 3: sx = W - 1 - dx; sy = H - 1 - dy; break;
                case 4: sx = dx;         sy = H - 1 - dy; break;
                case 5: sx = dy;         sy = dx;         break;
                case 6: sx = dy;         sy = H - 1 - dx; break;
                case 7: sx = W - 1 - dy; sy = H - 1 - dx; break;
                case 8: sx = W - 1 - dy; sy = dx;         break;
            }
            memcpy(&dst[((size_t)dy * dW + dx) * elem],
                   &src[((size_t)sy * W + sx) * elem], elem);
        }
    }
}

class ImageIOFileInTOP final : public TOP_CPlusPlusBase {
public:
    ImageIOFileInTOP(const OP_NodeInfo*, TOP_Context* c) : myContext(c) { myThread = std::thread([this]{ worker(); }); }
    ~ImageIOFileInTOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit = true; } myCond.notify_all(); if (myThread.joinable()) myThread.join(); }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked = true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        std::string file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        int type = (int)in->getParInt("Datatype");
        bool norm = in->getParInt("Normalize") != 0;
        bool orientOn = in->getParInt("Applyorientation") != 0;
        std::string sig = file + "|" + std::to_string(type) + "|" + (norm ? "1" : "0") + (orientOn ? "o" : "");
        if (sig != mySig) {
            mySig = sig;
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) {
                myFile = file; myType = type; myNorm = norm; myOrient = orientOn; myPending = true; mySubmit++;
                l.unlock(); myCond.notify_one();
            } else { mySig.clear(); }
        }

        Result r;
        { std::lock_guard<std::mutex> l(myMutex); if (myResult.serial == myUploaded || myResult.bytes.empty()) return; r = myResult; myUploaded = r.serial; }
        TOP_UploadInfo ui;
        ui.textureDesc.texDim = OP_TexDim::e2D;
        ui.textureDesc.width = r.w; ui.textureDesc.height = r.h;
        ui.textureDesc.pixelFormat = r.color ? OP_PixelFormat::BGRA8Fixed : OP_PixelFormat::Mono32Float;
        auto b = myContext->createOutputBuffer((size_t)r.w * r.h * 4, TOP_BufferFlags::None, nullptr);
        if (!b) return;
        memcpy(b->data, r.bytes.data(), r.bytes.size());
        out->uploadBuffer(&b, ui, nullptr);
        myLo = r.lo; myHi = r.hi; myW = r.w; myH = r.h;
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "ImageIO File In";
        { OP_StringParameter p("File"); p.label = "Image File (HEIF / HEIC / JPEG / PNG ...)"; p.page = PAGE; m->appendFile(p); }
        { OP_StringParameter p("Datatype"); p.label = "Data Type"; p.page = PAGE;
          const char* names[]  = {"Color","Auto","Disparity","Depth","Portraitmatte","Skinmatte","Hairmatte","Skymatte","Teethmatte","Glassesmatte"};
          const char* labels[] = {"Color (RGB)","Auto Depth (disparity->depth->matte)","Disparity","Depth","Portrait Matte","Semantic: Skin","Semantic: Hair","Semantic: Sky","Semantic: Teeth","Semantic: Glasses"};
          std::vector<const char*> nv(names, names+10), lv(labels, labels+10);
          p.defaultValue = "Color"; m->appendMenu(p, 10, nv.data(), lv.data()); }
        { OP_NumericParameter p("Applyorientation"); p.label = "Apply EXIF Orientation"; p.page = PAGE; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Normalize"); p.label = "Normalize Depth (auto min-max -> 0..1)"; p.page = PAGE; p.defaultValues[0] = 1; m->appendToggle(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 11; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[] = {"executes","submits","extracts","valid","range_min","range_max","width","height","has_disparity","has_depth","has_matte"};
        float v[] = {(float)myExec.load(),(float)mySubmit.load(),(float)myExtract.load(),myValid?1.f:0.f,myLo.load(),myHi.load(),
                     (float)myW.load(),(float)myH.load(),myHasDisp?1.f:0.f,myHasDepth?1.f:0.f,myHasMatte?1.f:0.f};
        c->name->setString(n[i]); c->value = v[i];
    }
    void getWarningString(OP_String* s, void*) override { std::lock_guard<std::mutex> l(myMutex); if (!myWarning.empty()) s->setString(myWarning.c_str()); }

private:
    void worker() {
        while (true) {
            std::string file; int type; bool norm, orientOn;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l, [this]{ return myQuit || myPending; });
              if (myQuit) return; file = myFile; type = myType; norm = myNorm; orientOn = myOrient; myPending = false; myBusy = true; }
            Result r; std::string w;
            bool ok = extract(file, type, norm, orientOn, r, w);
            myExtract++; myValid = ok;
            { std::lock_guard<std::mutex> l(myMutex); if (ok) { r.serial = ++mySerial; myResult = std::move(r); } myWarning = std::move(w); myBusy = false; }
        }
    }

    static int readOrientation(CGImageSourceRef src) {
        int orient = 1;
        CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, nullptr);
        if (props) {
            CFNumberRef o = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyOrientation);
            if (o) CFNumberGetValue(o, kCFNumberIntType, &orient);
            CFRelease(props);
        }
        if (orient < 1 || orient > 8) orient = 1;
        return orient;
    }

    // 主画像を top-down BGRA8(source寸法)へ
    static bool decodeColor(CGImageSourceRef src, std::vector<uint8_t>& out, uint32_t& W, uint32_t& H) {
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, nullptr);
        if (!img) return false;
        W = (uint32_t)CGImageGetWidth(img); H = (uint32_t)CGImageGetHeight(img);
        out.assign((size_t)W * H * 4, 0);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(out.data(), W, H, 8, (size_t)W * 4, cs,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        // CGBitmapContext の描画結果は補助データ(loadAux)と同じ縦向き(top-down相当)。
        // ここで反転すると applyOrientation が反転済みバッファに掛かり、EXIF Orientation が
        // 左右/上下反転する(実測でHEICが鏡像・上下逆になった)。反転せずに描く。
        CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), img);
        CGContextRelease(ctx); CGColorSpaceRelease(cs); CGImageRelease(img);
        return true;
    }

    static bool loadAux(CGImageSourceRef src, CFStringRef type, std::vector<float>& out, uint32_t& W, uint32_t& H, std::string& kind) {
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
            for (uint32_t y = 0; y < H; y++) { const uint8_t* row = bytes + (size_t)y * bpr; float* o = out.data() + (size_t)y * W; for (uint32_t x = 0; x < W; x++) o[x] = row[x] / 255.f; }
            kind = "uint8";
        }
        CFRelease(aux);
        return true;
    }

    bool extract(const std::string& file, int type, bool norm, bool orientOn, Result& r, std::string& w) {
        @autoreleasepool {
            if (file.empty()) { w = "No file"; return false; }
            NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:file.c_str()]];
            CGImageSourceRef src = CGImageSourceCreateWithURL((CFURLRef)url, nullptr);
            if (!src) { w = "Cannot open file"; return false; }
            const int orient = orientOn ? readOrientation(src) : 1;

            // 利用可能な補助データを診断
            auto has = [&](CFStringRef t)->bool { CFDictionaryRef a = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, t); if (a) { CFRelease(a); return true; } return false; };
            myHasDisp = has(kCGImageAuxiliaryDataTypeDisparity);
            myHasDepth = has(kCGImageAuxiliaryDataTypeDepth);
            myHasMatte = has(kCGImageAuxiliaryDataTypePortraitEffectsMatte);

            if (type == 0) {
                // ---- Color(BGRA8)----
                std::vector<uint8_t> srcbuf; uint32_t W = 0, H = 0;
                if (!decodeColor(src, srcbuf, W, H)) { CFRelease(src); w = "Cannot decode image"; return false; }
                CFRelease(src);
                std::vector<uint8_t> disp; uint32_t dW, dH;
                applyOrientation(srcbuf.data(), W, H, 4, orient, disp, dW, dH);
                // TOPは bottom-up。行反転してアップロード
                r.bytes.resize((size_t)dW * dH * 4);
                for (uint32_t y = 0; y < dH; y++)
                    memcpy(r.bytes.data() + (size_t)(dH - 1 - y) * dW * 4, disp.data() + (size_t)y * dW * 4, (size_t)dW * 4);
                r.w = dW; r.h = dH; r.color = true; r.kind = "color"; r.lo = 0; r.hi = 1;
                return true;
            }

            // ---- Depth / Disparity / Matte(Mono32Float)----
            std::vector<float> vals; uint32_t W = 0, H = 0; std::string kind; bool ok = false;
            if (type == 1) {
                CFStringRef order[] = { kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypePortraitEffectsMatte };
                for (int i = 0; i < 3 && !ok; i++) ok = loadAux(src, order[i], vals, W, H, kind);
            } else {
                CFStringRef t = auxTypeFor(type);
                if (t) ok = loadAux(src, t, vals, W, H, kind);
            }
            CFRelease(src);
            if (!ok) { w = "No depth/matte data of that type in this file"; return false; }

            // 向きを適用(float を 4byte 要素として扱う)
            std::vector<uint8_t> disp; uint32_t dW, dH;
            applyOrientation(reinterpret_cast<const uint8_t*>(vals.data()), W, H, 4, orient, disp, dW, dH);
            float* fp = reinterpret_cast<float*>(disp.data());
            const size_t n = (size_t)dW * dH;
            float lo = fp[0], hi = fp[0];
            for (size_t i = 0; i < n; i++) { if (fp[i] < lo) lo = fp[i]; if (fp[i] > hi) hi = fp[i]; }
            r.lo = lo; r.hi = hi;
            if (norm && hi > lo) { float inv = 1.f / (hi - lo); for (size_t i = 0; i < n; i++) fp[i] = (fp[i] - lo) * inv; }
            // TOP bottom-up 行反転
            r.bytes.resize(n * 4); r.w = dW; r.h = dH; r.color = false; r.kind = kind;
            for (uint32_t y = 0; y < dH; y++)
                memcpy(r.bytes.data() + (size_t)(dH - 1 - y) * dW * 4, disp.data() + (size_t)y * dW * 4, (size_t)dW * 4);
            return true;
        }
    }

    TOP_Context* myContext; std::thread myThread; std::condition_variable myCond; std::mutex myMutex;
    bool myQuit = false, myPending = false, myBusy = false, myNorm = true, myOrient = true;
    std::string myFile, mySig, myWarning; int myType = 0;
    Result myResult; uint64_t mySerial = 0, myUploaded = 0;
    std::atomic<uint64_t> myExec{0}, mySubmit{0}, myExtract{0}, myW{0}, myH{0};
    std::atomic<bool> myValid{false}, myHasDisp{false}, myHasDepth{false}, myHasMatte{false};
    std::atomic<float> myLo{0}, myHi{1};
};
} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Imageiofilein");
    i->customOPInfo.opLabel->setString("ImageIO File In");
    i->customOPInfo.opIcon->setString("IFI");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/ImageIOFileIn/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 0;
    i->customOPInfo.maxInputs = 0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new ImageIOFileInTOP(i, c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<ImageIOFileInTOP*>(i); }
}
