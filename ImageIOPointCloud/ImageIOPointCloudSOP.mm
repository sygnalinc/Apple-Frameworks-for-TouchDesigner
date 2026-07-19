// ImageIO PointCloud SOP — 写真(HEIC等)に埋め込まれた深度/視差(AVDepthData)を、
// カメラ内部パラメータ(あれば)または画角から逆投影して 3Dポイントクラウドにする。
// 抽出・逆投影はワーカースレッドで行い、SOPのcookは最新の点群を出力するだけ。
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Accelerate/Accelerate.h>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "SOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
using namespace TD;

namespace {
struct Cloud { std::vector<Position> pts; std::vector<Color> cols; uint64_t serial = 0; };
struct Params { std::string file; int step; float depthScale, hfov; bool disp2depth, color, flip; int maxPts; };

class ImageIOPointCloudSOP final : public SOP_CPlusPlusBase {
public:
    ImageIOPointCloudSOP(const OP_NodeInfo*) { myThread = std::thread([this]{ worker(); }); }
    ~ImageIOPointCloudSOP() override { { std::lock_guard<std::mutex> l(myMutex); myQuit = true; } myCond.notify_all(); if (myThread.joinable()) myThread.join(); }

    void getGeneralInfo(SOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrame = false; g->cookEveryFrameIfAsked = true; }

    void execute(SOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        Params p;
        p.file = in->getParFilePath("File") ? in->getParFilePath("File") : "";
        p.step = std::max(1, (int)in->getParInt("Step"));
        p.depthScale = (float)in->getParDouble("Depthscale");
        p.hfov = (float)in->getParDouble("Hfov");
        p.disp2depth = in->getParInt("Disptodepth") != 0;
        p.color = in->getParInt("Color") != 0;
        p.flip = in->getParInt("Flip") != 0;
        p.maxPts = std::max(100, (int)in->getParInt("Maxpoints"));
        char buf[300]; snprintf(buf, sizeof buf, "%s|%d|%.4f|%.2f|%d|%d|%d|%d", p.file.c_str(), p.step, p.depthScale, p.hfov, p.disp2depth?1:0, p.color?1:0, p.flip?1:0, p.maxPts);
        std::string sig = buf;
        if (sig != mySig) {
            mySig = sig;
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) { myParams = p; myPending = true; mySubmit++; l.unlock(); myCond.notify_one(); }
            else mySig.clear();
        }
        Cloud c;
        { std::lock_guard<std::mutex> l(myMutex); c = myCloud; }
        if (c.pts.empty()) return;
        out->addPoints(c.pts.data(), (int32_t)c.pts.size());
        if (!c.cols.empty() && c.cols.size() == c.pts.size()) out->setColors(c.cols.data(), (int32_t)c.cols.size(), 0);
        out->addParticleSystem((int32_t)c.pts.size(), 0);
        myPoints = (int)c.pts.size();
    }
    void executeVBO(SOP_VBOOutput*, const OP_Inputs*, void*) override {}

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* PAGE = "PointCloud";
        { OP_StringParameter p("File"); p.label = "Image File (HEIC with depth)"; p.page = PAGE; m->appendFile(p); }
        { OP_NumericParameter p("Step"); p.label = "Sample Step (downsample)"; p.page = PAGE; p.defaultValues[0] = 2; p.minSliders[0] = 1; p.maxSliders[0] = 16; p.minValues[0] = 1; p.clampMins[0] = true; m->appendInt(p); }
        { OP_NumericParameter p("Maxpoints"); p.label = "Max Points"; p.page = PAGE; p.defaultValues[0] = 200000; p.minSliders[0] = 1000; p.maxSliders[0] = 500000; m->appendInt(p); }
        { OP_NumericParameter p("Depthscale"); p.label = "Depth Scale"; p.page = PAGE; p.defaultValues[0] = 1.0; p.minSliders[0] = 0.01; p.maxSliders[0] = 10; m->appendFloat(p); }
        { OP_NumericParameter p("Disptodepth"); p.label = "Disparity → Depth (1/x)"; p.page = PAGE; p.defaultValues[0] = 0; m->appendToggle(p); }
        { OP_NumericParameter p("Hfov"); p.label = "Horizontal FOV (deg, if no calibration)"; p.page = PAGE; p.defaultValues[0] = 60; p.minSliders[0] = 20; p.maxSliders[0] = 120; m->appendFloat(p); }
        { OP_NumericParameter p("Color"); p.label = "Sample Color from RGB"; p.page = PAGE; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Flip"); p.label = "Flip Vertically"; p.page = PAGE; p.defaultValues[0] = 1; m->appendToggle(p); }
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[] = {"executes","submits","builds","points","has_calibration"};
        float v[] = {(float)myExec.load(),(float)mySubmit.load(),(float)myBuild.load(),(float)myPoints.load(),myCalib?1.f:0.f};
        c->name->setString(n[i]); c->value = v[i];
    }
    void getWarningString(OP_String* s, void*) override { std::lock_guard<std::mutex> l(myMutex); if (!myWarning.empty()) s->setString(myWarning.c_str()); }

private:
    void worker() {
        while (true) {
            Params p;
            { std::unique_lock<std::mutex> l(myMutex); myCond.wait(l, [this]{ return myQuit || myPending; }); if (myQuit) return; p = myParams; myPending = false; myBusy = true; }
            Cloud c; std::string w; bool calib = false; bool ok = build(p, c, w, calib);
            myBuild++; myCalib = calib;
            { std::lock_guard<std::mutex> l(myMutex); if (ok) { c.serial = ++mySerial; myCloud = std::move(c); } myWarning = std::move(w); myBusy = false; }
        }
    }

    // 深度/視差の補助データを float 配列で取得
    static bool loadDepth(CGImageSourceRef src, std::vector<float>& out, uint32_t& W, uint32_t& H, CFDictionaryRef& auxOut) {
        CFStringRef order[] = { kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth };
        for (int i = 0; i < 2; i++) {
            CFDictionaryRef aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, order[i]);
            if (!aux) continue;
            CFDataRef data = (CFDataRef)CFDictionaryGetValue(aux, kCGImageAuxiliaryDataInfoData);
            CFDictionaryRef desc = (CFDictionaryRef)CFDictionaryGetValue(aux, kCGImageAuxiliaryDataInfoDataDescription);
            if (!data || !desc) { CFRelease(aux); continue; }
            auto geti = [&](CFStringRef k)->long { CFNumberRef n = (CFNumberRef)CFDictionaryGetValue(desc, k); long v = 0; if (n) CFNumberGetValue(n, kCFNumberLongType, &v); return v; };
            long w0 = geti(CFSTR("Width")), h0 = geti(CFSTR("Height")), bpr = geti(CFSTR("BytesPerRow")), pf = geti(CFSTR("PixelFormat"));
            if (w0 <= 0 || h0 <= 0) { CFRelease(aux); continue; }
            W = (uint32_t)w0; H = (uint32_t)h0; out.resize((size_t)W * H);
            const uint8_t* bytes = CFDataGetBytePtr(data); OSType fmt = (OSType)pf;
            if (fmt == kCVPixelFormatType_DisparityFloat16 || fmt == kCVPixelFormatType_DepthFloat16) {
                for (uint32_t y = 0; y < H; y++) { vImage_Buffer sb{ (void*)(bytes + (size_t)y * bpr), 1, W, (size_t)W * 2 }; vImage_Buffer db{ out.data() + (size_t)y * W, 1, W, (size_t)W * 4 }; vImageConvert_Planar16FtoPlanarF(&sb, &db, 0); }
            } else if (fmt == kCVPixelFormatType_DisparityFloat32 || fmt == kCVPixelFormatType_DepthFloat32) {
                for (uint32_t y = 0; y < H; y++) memcpy(out.data() + (size_t)y * W, bytes + (size_t)y * bpr, (size_t)W * 4);
            } else { for (uint32_t y = 0; y < H; y++) { const uint8_t* r = bytes + (size_t)y * bpr; float* o = out.data() + (size_t)y * W; for (uint32_t x = 0; x < W; x++) o[x] = r[x] / 255.f; } }
            auxOut = aux; // 呼び出し側で release
            return true;
        }
        return false;
    }

    static bool build(const Params& p, Cloud& c, std::string& w, bool& calib) {
        @autoreleasepool {
            if (p.file.empty()) { w = "No file"; return false; }
            NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:p.file.c_str()]];
            CGImageSourceRef src = CGImageSourceCreateWithURL((CFURLRef)url, nullptr);
            if (!src) { w = "Cannot open file"; return false; }
            std::vector<float> depth; uint32_t W = 0, H = 0; CFDictionaryRef aux = nullptr;
            if (!loadDepth(src, depth, W, H, aux)) { CFRelease(src); w = "No depth/disparity in this file"; return false; }

            // 内部パラメータ: AVDepthData のキャリブレーション優先、無ければ FOV
            float fx, fy, cx = W * 0.5f, cy = H * 0.5f;
            calib = false;
            if (aux) {
                NSError* err = nil;
                AVDepthData* dd = [AVDepthData depthDataFromDictionaryRepresentation:(__bridge NSDictionary*)aux error:&err];
                AVCameraCalibrationData* cc = dd.cameraCalibrationData;
                if (cc) {
                    matrix_float3x3 K = cc.intrinsicMatrix;
                    CGSize refDim = cc.intrinsicMatrixReferenceDimensions;
                    float sx = (float)W / (float)refDim.width, sy = (float)H / (float)refDim.height;
                    fx = K.columns[0][0] * sx; fy = K.columns[1][1] * sy;
                    cx = K.columns[2][0] * sx; cy = K.columns[2][1] * sy;
                    calib = true;
                }
            }
            if (!calib) { float f = (W * 0.5f) / std::tan(p.hfov * 0.5f * (float)M_PI / 180.f); fx = fy = f; }

            // カラー用にRGBを縮小デコード
            std::vector<uint8_t> rgb; uint32_t rw = 0, rh = 0;
            if (p.color) {
                CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, nullptr);
                if (img) {
                    rw = W; rh = H; rgb.resize((size_t)rw * rh * 4);
                    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                    CGContextRef ctx = CGBitmapContextCreate(rgb.data(), rw, rh, 8, rw * 4, cs, kCGImageAlphaPremultipliedLast);
                    CGContextDrawImage(ctx, CGRectMake(0, 0, rw, rh), img);
                    CGContextRelease(ctx); CGColorSpaceRelease(cs); CGImageRelease(img);
                }
            }
            if (aux) CFRelease(aux);
            CFRelease(src);

            // 逆投影(stepで間引き、maxPtsで制限)
            c.pts.reserve((size_t)(W / p.step) * (H / p.step));
            bool useCol = p.color && !rgb.empty();
            for (uint32_t y = 0; y < H; y += p.step) {
                for (uint32_t x = 0; x < W; x += p.step) {
                    float d = depth[(size_t)y * W + x];
                    if (!(d > 0) || !std::isfinite(d)) continue;
                    float Z = p.disp2depth ? (1.f / (d + 1e-4f)) : d;
                    Z *= p.depthScale;
                    float px = (float)x, py = (float)y;
                    float X = (px - cx) / fx * Z;
                    float Y = (py - cy) / fy * Z;
                    Position pos; pos.x = X; pos.y = p.flip ? Y : -Y; pos.z = -Z;
                    c.pts.push_back(pos);
                    if (useCol) { const uint8_t* pix = &rgb[((size_t)y * rw + x) * 4]; Color col; col.r = pix[0] / 255.f; col.g = pix[1] / 255.f; col.b = pix[2] / 255.f; col.a = 1.f; c.cols.push_back(col); }
                    if ((int)c.pts.size() >= p.maxPts) { w = "Reached Max Points (increase step or Max Points)"; return true; }
                }
            }
            if (c.pts.empty()) { w = "No valid depth points"; return false; }
            return true;
        }
    }

    std::thread myThread; std::condition_variable myCond; std::mutex myMutex;
    bool myQuit = false, myPending = false, myBusy = false;
    Params myParams; Cloud myCloud; std::string mySig, myWarning; uint64_t mySerial = 0;
    std::atomic<uint64_t> myExec{0}, mySubmit{0}, myBuild{0}; std::atomic<int> myPoints{0}; std::atomic<bool> myCalib{false};
};
} // namespace

extern "C" {
DLLEXPORT void FillSOPPluginInfo(SOP_PluginInfo* i) {
    if (!i->setAPIVersion(SOPCPlusPlusAPIVersion)) return;
    i->customOPInfo.opType->setString("Imageiopointcloud");
    i->customOPInfo.opLabel->setString("ImageIO PointCloud");
    i->customOPInfo.opIcon->setString("IPC");
    i->customOPInfo.authorName->setString("TDAppleML");
    i->customOPInfo.minInputs = 0;
    i->customOPInfo.maxInputs = 0;
}
DLLEXPORT SOP_CPlusPlusBase* CreateSOPInstance(const OP_NodeInfo* i) { return new ImageIOPointCloudSOP(i); }
DLLEXPORT void DestroySOPInstance(SOP_CPlusPlusBase* i) { delete static_cast<ImageIOPointCloudSOP*>(i); }
}
