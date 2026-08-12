// CoreImage Glass TOP — macOS の「すりガラス」を入力画像に適用する。
//
// Style は2つ:
//   Frosted      … NSVisualEffectView のマテリアル(サイドバー/HUD/ポップオーバー等)の見た目
//   Liquid Glass … macOS 26 の NSGlassEffectView。縁で背景が屈折し、リムが光る
//
// **本物の API はテクスチャとして取り出せない**(NSVisualEffectView の .behindWindow は
// ウインドウコンポジタが画面上で合成するもので、cacheDisplay には乗らない)。そのため
// Core Image で組み直している。プリセットの数値は、実物を画面に出して既知のテスト画像に
// 重ね、screencapture で取り込んで逆算した実測値(README の表を参照)。
//
// 入力0: 背景画像(必須)
// 入力1: マスク(任意)。白い所がガラスになる。無ければ角丸矩形をパラメータから作る

#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include "TOP_CPlusPlusBase.h"
#include "CPlusPlus_Common.h"
#include "../common/NonCommercialLimit.h"

using namespace TD;

namespace {

// ---- 実測プリセット -------------------------------------------------------
// 画面上の実物を既知のテスト画像に重ねて screencapture で取り込み、
//   黒地の出力 = tint*alpha、白地の出力 = (1-alpha) + tint*alpha
// から alpha と tint を解いた値。blur は白黒境界の 10-90% 遷移幅から。
struct Preset { const char* name; float r, g, b, alpha, blur; };

// Frosted(NSVisualEffectView)。sheet は alpha=1.0・blur=0 で「そもそも透けない」ため
// プリセットから外している(実測で判明)。
const Preset kFrostedDark[] = {
    {"Hud",        0.202f, 0.228f, 0.237f, 0.447f, 35.0f},
    {"Popover",    0.185f, 0.210f, 0.210f, 0.635f, 34.8f},
    {"Menu",       0.183f, 0.199f, 0.203f, 0.731f, 35.2f},
    {"Sidebar",    0.181f, 0.195f, 0.199f, 0.825f, 34.0f},
    {"Titlebar",   0.238f, 0.256f, 0.257f, 0.809f, 38.2f},
    {"Fullscreen", 0.196f, 0.219f, 0.219f, 0.539f, 36.5f},
};
const Preset kFrostedLight[] = {
    {"Hud",        0.866f, 0.888f, 0.889f, 0.527f, 34.5f},
    {"Popover",    0.867f, 0.886f, 0.886f, 0.654f, 33.2f},
    {"Menu",       0.869f, 0.884f, 0.889f, 0.776f, 32.0f},
    {"Sidebar",    0.870f, 0.883f, 0.887f, 0.902f, 24.8f},
    {"Titlebar",   0.947f, 0.961f, 0.966f, 0.810f, 38.0f},
    {"Fullscreen", 0.866f, 0.888f, 0.889f, 0.527f, 34.5f},
};
// Liquid Glass(NSGlassEffectView)。白地での透け具合の実測:
//   Regular 0.39 / Clear 0.81 → Clear の方がはるかに素通し
const Preset kLiquidDark[]  = { {"Regular", 0.16f,0.17f,0.18f, 0.61f, 30.0f},
                                {"Clear",   0.16f,0.17f,0.18f, 0.19f, 22.0f} };
const Preset kLiquidLight[] = { {"Regular", 0.92f,0.93f,0.94f, 0.55f, 30.0f},
                                {"Clear",   0.95f,0.96f,0.97f, 0.17f, 22.0f} };

// 縁の屈折とリム。ぼかしたマスクの勾配を法線とみなし、背景をその向きへ引き込む。
// これなら角丸矩形でも入力マスクの任意形状でも同じ経路で扱える。
//
// **CIWarpKernel は画像をサンプルできない**(座標だけを返す)ので、
// 屈折とリムを1つの汎用 CIKernel にまとめている。
static NSString* const kGlassKernel =
@"kernel vec4 glassEdge(sampler img, sampler edge, float amount, float rim) {"
@"  vec2 d = destCoord();"
@"  float l = sample(edge, samplerTransform(edge, d + vec2(-1.0, 0.0))).r;"
@"  float r = sample(edge, samplerTransform(edge, d + vec2( 1.0, 0.0))).r;"
@"  float b = sample(edge, samplerTransform(edge, d + vec2(0.0, -1.0))).r;"
@"  float t = sample(edge, samplerTransform(edge, d + vec2(0.0,  1.0))).r;"
@"  vec2 n = vec2(r - l, t - b);"          // 勾配 = 内向きの法線(縁だけ大きい)
@"  vec4 c = sample(img, samplerTransform(img, d - n * amount));"
@"  return vec4(c.rgb + length(n) * rim, c.a);"
@"}";

class CoreImageGlassTOP final : public TOP_CPlusPlusBase
{
public:
    CoreImageGlassTOP(const OP_NodeInfo*, TOP_Context* ctx) : myContext(ctx)
    {
        myThread = std::thread(&CoreImageGlassTOP::worker, this);
    }
    ~CoreImageGlassTOP() override
    {
        { std::lock_guard<std::mutex> l(myMutex); myQuit = true; }
        myCond.notify_all();
        if (myThread.joinable()) myThread.join();
    }

    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override
    {
        g->cookEveryFrameIfAsked = true;
    }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override
    {
        myExec++;
        Params p;
        p.style      = (int)in->getParInt("Style");        // 0=Frosted 1=Liquid
        const char* mat = in->getParString("Material");
        p.material = materialIndex(mat ? mat : "", in->getParInt("Style") == 1);
        p.dark       = in->getParInt("Appearance") != 0;   // 0=Light 1=Dark
        p.blurScale  = (float)in->getParDouble("Blur");
        p.saturation = (float)in->getParDouble("Saturation");
        p.tintAmount = (float)in->getParDouble("Tint");
        p.corner     = (float)in->getParDouble("Cornerradius");
        p.inset      = (float)in->getParDouble("Inset");
        p.refract    = (float)in->getParDouble("Refraction");
        p.rim        = (float)in->getParDouble("Rim");
        p.flip       = in->getParInt("Flip") != 0;
        double tc[4] = {0,0,0,0};
        in->getParDouble4("Tintcolor", tc[0], tc[1], tc[2], tc[3]);
        p.tr = (float)tc[0]; p.tg = (float)tc[1]; p.tb = (float)tc[2];
        p.useCustomTint = in->getParInt("Customtint") != 0;

        char buf[256];
        snprintf(buf, sizeof buf, "%d|%d|%d|%.2f|%.2f|%.2f|%.1f|%.1f|%.2f|%.2f|%d|%.3f,%.3f,%.3f|%d",
                 p.style, p.material, p.dark ? 1 : 0, p.blurScale, p.saturation, p.tintAmount,
                 p.corner, p.inset, p.refract, p.rim, p.flip ? 1 : 0, p.tr, p.tg, p.tb,
                 p.useCustomTint ? 1 : 0);
        std::string sig(buf);
        if (sig != mySig) { mySig = sig; myLastA = myLastM = -1; }

        const OP_TOPInput* a = in->getInputTOP(0);
        const OP_TOPInput* m = in->getInputTOP(1);
        if (!a) { myWarning = "Connect the background image to input 0"; return; }
        myWarning.clear();

        const bool changed = (int64_t)a->totalCooks != myLastA ||
                             (m && (int64_t)m->totalCooks != myLastM);
        if (changed) {
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) {
                OP_TOPInputDownloadOptions o;
                o.pixelFormat = OP_PixelFormat::BGRA8Fixed;
                o.verticalFlip = p.flip;
                myImage = a->downloadTexture(o, nullptr);
                myMask = m ? m->downloadTexture(o, nullptr) : OP_SmartRef<OP_TOPDownloadResult>();
                if (myImage) {
                    myParams = p; myPending = true;
                    myLastA = a->totalCooks;
                    myLastM = m ? m->totalCooks : -1;
                    mySubmit++;
                    l.unlock(); myCond.notify_one();
                }
            }
        }

        // キャッシュ済みの結果は毎 execute アップロードする。
        // (serial 一致で return すると bypass から戻したとき黒いままになる)
        Result r;
        { std::lock_guard<std::mutex> l(myMutex); if (myResult.p.empty()) return; r = myResult; }
        uint32_t w = r.w, h = r.h;
        std::vector<uint8_t> px = r.p;
        myNCScaled = tdnc::fit(px, w, h, OP_PixelFormat::BGRA8Fixed);
        TOP_UploadInfo ui;
        ui.textureDesc.texDim = OP_TexDim::e2D;
        ui.textureDesc.width = w; ui.textureDesc.height = h;
        ui.textureDesc.pixelFormat = OP_PixelFormat::BGRA8Fixed;
        auto b = myContext->createOutputBuffer(px.size(), TOP_BufferFlags::None, nullptr);
        if (!b) return;
        memcpy(b->data, px.data(), px.size());
        out->uploadBuffer(&b, ui, nullptr);
        myFrames++;
    }

    void setupParameters(OP_ParameterManager* m, void*) override
    {
        const char* PAGE = "Glass";
        { OP_StringParameter p("Style"); p.label = "Style"; p.page = PAGE;
          const char* n[] = {"Frosted", "Liquid"};
          const char* l[] = {"Frosted (macOS materials)", "Liquid Glass (macOS 26)"};
          std::vector<const char*> nv(n, n+2), lv(l, l+2);
          p.defaultValue = "Frosted"; m->appendMenu(p, 2, nv.data(), lv.data()); }
        // Material は Style で中身が変わる(Frosted=6種 / Liquid=Regular・Clear)。
        // 静的メニューだと Liquid のとき Sidebar 等が並んでしまい、内部で丸めることになる
        { OP_StringParameter p("Material"); p.label = "Material"; p.page = PAGE;
          p.defaultValue = "Sidebar"; m->appendDynamicStringMenu(p); }
        { OP_StringParameter p("Appearance"); p.label = "Appearance"; p.page = PAGE;
          const char* n[] = {"Light","Dark"}; const char* l[] = {"Light","Dark"};
          std::vector<const char*> nv(n, n+2), lv(l, l+2);
          p.defaultValue = "Dark"; m->appendMenu(p, 2, nv.data(), lv.data()); }
        addFloat(m, "Blur",       "Blur Scale",   1.0, 0.0, 3.0);
        addFloat(m, "Saturation", "Saturation",   1.8, 0.0, 4.0);
        addFloat(m, "Tint",       "Tint Amount",  1.0, 0.0, 2.0);
        { OP_NumericParameter p("Customtint"); p.label = "Custom Tint"; p.page = PAGE;
          p.defaultValues[0] = 0; m->appendToggle(p); }
        { OP_NumericParameter p("Tintcolor"); p.label = "Tint Color"; p.page = PAGE;
          for (int i = 0; i < 3; i++) { p.defaultValues[i] = 0.2; p.minValues[i] = 0; p.maxValues[i] = 1;
              p.minSliders[i] = 0; p.maxSliders[i] = 1; p.clampMins[i] = p.clampMaxes[i] = true; }
          m->appendRGB(p); }
        addFloat(m, "Cornerradius", "Corner Radius", 28.0, 0.0, 300.0);
        addFloat(m, "Inset",        "Inset",         60.0, 0.0, 500.0);
        addFloat(m, "Refraction",   "Edge Refraction", 0.6, 0.0, 3.0);
        addFloat(m, "Rim",          "Edge Rim",        0.5, 0.0, 3.0);
        { OP_NumericParameter p("Flip"); p.label = "Flip Vertically"; p.page = PAGE;
          p.defaultValues[0] = 1; m->appendToggle(p); }
    }

    void buildDynamicMenu(const OP_Inputs* in, OP_BuildDynamicMenuInfo* info, void*) override
    {
        if (strcmp(info->name, "Material") != 0) return;
        const bool liquid = in && in->getParInt("Style") == 1;
        if (liquid) {
            info->addMenuEntry("Regular", "Regular");
            info->addMenuEntry("Clear", "Clear (more transparent)");
        } else {
            const char* n[] = {"Hud","Popover","Menu","Sidebar","Titlebar","Fullscreen"};
            const char* l[] = {"HUD Window","Popover","Menu","Sidebar / Under Window",
                               "Titlebar","Fullscreen UI"};
            for (int i = 0; i < 6; i++) info->addMenuEntry(n[i], l[i]);
        }
    }

    void getWarningString(OP_String* s, void*) override
    {
        if (!myWarning.empty()) { s->setString(myWarning.c_str()); return; }
        if (myNCScaled) s->setString(tdnc::kWarning);
    }

    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override
    {
        const char* n[] = {"executes", "submits", "frames", "blur_radius", "alpha"};
        float v[] = {(float)myExec.load(), (float)mySubmit.load(), (float)myFrames.load(),
                     myUsedBlur.load(), myUsedAlpha.load()};
        c->name->setString(n[i]); c->value = v[i];
    }

private:
    struct Params {
        int style = 0, material = 3; bool dark = true;
        float blurScale = 1, saturation = 1.8f, tintAmount = 1, corner = 28, inset = 60;
        float refract = 0.6f, rim = 0.5f, tr = 0.2f, tg = 0.2f, tb = 0.2f;
        bool useCustomTint = false, flip = true;
    };
    struct Result { std::vector<uint8_t> p; uint32_t w = 0, h = 0; };

    static void addFloat(OP_ParameterManager* m, const char* n, const char* l,
                         double d, double lo, double hi)
    {
        OP_NumericParameter p(n); p.label = l; p.page = "Glass";
        p.defaultValues[0] = d; p.minValues[0] = lo; p.maxValues[0] = hi;
        p.minSliders[0] = lo; p.maxSliders[0] = hi;
        p.clampMins[0] = p.clampMaxes[0] = true;
        m->appendFloat(p);
    }

    // 動的メニューは値が文字列で入るので、名前からプリセット番号を引く
    static int materialIndex(const std::string& name, bool liquid)
    {
        if (liquid) return name == "Clear" ? 1 : 0;
        static const char* names[] = {"Hud","Popover","Menu","Sidebar","Titlebar","Fullscreen"};
        for (int i = 0; i < 6; i++) if (name == names[i]) return i;
        return 3;   // 既定は Sidebar
    }

    static const Preset& pick(const Params& p)
    {
        if (p.style == 1) {
            int i = std::clamp(p.material, 0, 1);
            return p.dark ? kLiquidDark[i] : kLiquidLight[i];
        }
        int i = std::clamp(p.material, 0, 5);
        return p.dark ? kFrostedDark[i] : kFrostedLight[i];
    }

    static CIImage* makeImage(OP_SmartRef<OP_TOPDownloadResult>& d, CGColorSpaceRef cs)
    {
        if (!d) return nil;
        void* data = d->getData();
        if (!data) return nil;
        uint32_t w = d->textureDesc.width, h = d->textureDesc.height;
        NSData* nd = [NSData dataWithBytes:data length:(size_t)w * h * 4];
        return [CIImage imageWithBitmapData:nd bytesPerRow:w * 4
                                       size:CGSizeMake(w, h)
                                     format:kCIFormatBGRA8 colorSpace:cs];
    }

    void worker()
    {
        while (true) {
            OP_SmartRef<OP_TOPDownloadResult> img, msk;
            Params p;
            {
                std::unique_lock<std::mutex> l(myMutex);
                myCond.wait(l, [this] { return myQuit || myPending; });
                if (myQuit) return;
                img = std::move(myImage); msk = std::move(myMask);
                p = myParams; myPending = false; myBusy = true;
            }
            Result r; std::string w;
            bool ok = false;
            @autoreleasepool { ok = process(img, msk, p, r, w); }
            { std::lock_guard<std::mutex> l(myMutex);
              if (ok) myResult = std::move(r);
              myWarning = w; myBusy = false; }
        }
    }

    bool process(OP_SmartRef<OP_TOPDownloadResult>& imgRef,
                 OP_SmartRef<OP_TOPDownloadResult>& mskRef,
                 const Params& p, Result& r, std::string& warn)
    {
        // Core Image は他プラグインとプロセス横断で直列化する
        // (Keystone と Bokeh の同時初期化で KVC 競合の実クラッシュを踏んでいる)
        @synchronized([CIFilter class]) {
            uint32_t iw = imgRef ? imgRef->textureDesc.width : 0;
            uint32_t ih = imgRef ? imgRef->textureDesc.height : 0;
            if (!iw || !ih) return false;
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CIImage* src = makeImage(imgRef, cs);
            if (!src) { CGColorSpaceRelease(cs); return false; }
            CGRect extent = CGRectMake(0, 0, iw, ih);

            const Preset& pre = pick(p);
            const float blur = pre.blur * std::max(0.f, p.blurScale);
            const float alpha = std::clamp(pre.alpha * p.tintAmount, 0.f, 1.f);
            myUsedBlur = blur; myUsedAlpha = alpha;

            // --- ガラスの形(マスク)。入力1があればそれ、無ければ角丸矩形 ---
            CIImage* mask = nil;
            if (mskRef) {
                mask = makeImage(mskRef, cs);
                if (mask && (mask.extent.size.width != iw || mask.extent.size.height != ih)) {
                    mask = [mask imageByApplyingTransform:
                            CGAffineTransformMakeScale(iw / mask.extent.size.width,
                                                       ih / mask.extent.size.height)];
                }
            }
            if (!mask) mask = roundedRectMask(iw, ih, p.inset, p.corner, cs);
            if (!mask) { CGColorSpaceRelease(cs); return false; }

            // --- 背景をぼかして彩度とティントを乗せる ---
            CIImage* bg = src;
            if (blur > 0.01f) {
                CIFilter* f = [CIFilter filterWithName:@"CIGaussianBlur"];
                [f setValue:[src imageByClampingToExtent] forKey:kCIInputImageKey];
                [f setValue:@(blur) forKey:kCIInputRadiusKey];
                bg = [f.outputImage imageByCroppingToRect:extent];
            }
            if (std::fabs(p.saturation - 1.f) > 0.01f) {
                CIFilter* f = [CIFilter filterWithName:@"CIColorControls"];
                [f setValue:bg forKey:kCIInputImageKey];
                [f setValue:@(p.saturation) forKey:kCIInputSaturationKey];
                bg = f.outputImage;
            }

            // --- Liquid Glass: 縁で背景を屈折させ、リムを光らせる ---
            if (p.style == 1 && (p.refract > 0.01f || p.rim > 0.01f)) {
                // ぼかしたマスク = 縁でだけ勾配を持つ場。その勾配を法線として使う
                CIFilter* eb = [CIFilter filterWithName:@"CIGaussianBlur"];
                [eb setValue:[mask imageByClampingToExtent] forKey:kCIInputImageKey];
                [eb setValue:@(std::max(2.f, p.corner * 0.35f)) forKey:kCIInputRadiusKey];
                CIImage* edge = [eb.outputImage imageByCroppingToRect:extent];

                static CIKernel* gk = [CIKernel kernelWithString:kGlassKernel];
                if (gk) {
                    CIImage* lit = [gk applyWithExtent:extent
                                           roiCallback:^CGRect(int, CGRect rect) {
                                               return CGRectInset(rect, -96, -96); }
                                             arguments:@[[bg imageByClampingToExtent], edge,
                                                         @(p.refract * 120.f), @(p.rim * 3.f)]];
                    if (lit) bg = [lit imageByCroppingToRect:extent];
                }
            }

            // --- ティントを重ねる ---
            if (alpha > 0.001f) {
                CGFloat tr = p.useCustomTint ? p.tr : pre.r;
                CGFloat tg = p.useCustomTint ? p.tg : pre.g;
                CGFloat tb = p.useCustomTint ? p.tb : pre.b;
                CIImage* tint = [CIImage imageWithColor:
                                 [CIColor colorWithRed:tr green:tg blue:tb alpha:alpha]];
                tint = [tint imageByCroppingToRect:extent];
                CIFilter* over = [CIFilter filterWithName:@"CISourceOverCompositing"];
                [over setValue:tint forKey:kCIInputImageKey];
                [over setValue:bg forKey:kCIInputBackgroundImageKey];
                bg = over.outputImage;
            }

            // --- マスクの内側だけガラスにする ---
            CIFilter* blend = [CIFilter filterWithName:@"CIBlendWithMask"];
            [blend setValue:bg forKey:kCIInputImageKey];
            [blend setValue:src forKey:kCIInputBackgroundImageKey];
            [blend setValue:mask forKey:@"inputMaskImage"];
            CIImage* outImg = [blend.outputImage imageByCroppingToRect:extent];
            if (!outImg) { CGColorSpaceRelease(cs); warn = "Glass produced no image"; return false; }

            r.w = iw; r.h = ih; r.p.resize((size_t)iw * ih * 4);
            CIContext* ctx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
            [ctx render:outImg toBitmap:r.p.data() rowBytes:iw * 4 bounds:extent
                 format:kCIFormatBGRA8 colorSpace:cs];
            // Core Image は top-down、TD は bottom-up
            std::vector<uint8_t> row((size_t)iw * 4);
            for (uint32_t y = 0; y < ih / 2; y++) {
                uint8_t* x = r.p.data() + (size_t)y * iw * 4;
                uint8_t* z = r.p.data() + (size_t)(ih - 1 - y) * iw * 4;
                memcpy(row.data(), x, row.size());
                memcpy(x, z, row.size());
                memcpy(z, row.data(), row.size());
            }
            CGColorSpaceRelease(cs);
            return true;
        }
    }

    // 角丸矩形の白マスク。CIRoundedRectangleGenerator が無い環境でも動くよう
    // CoreGraphics で描いて CIImage にする。
    static CIImage* roundedRectMask(uint32_t w, uint32_t h, float inset, float radius,
                                    CGColorSpaceRef cs)
    {
        size_t bpr = (size_t)w * 4;
        std::vector<uint8_t> buf((size_t)h * bpr, 0);
        CGContextRef c = CGBitmapContextCreate(buf.data(), w, h, 8, bpr, cs,
                                               kCGImageAlphaPremultipliedFirst |
                                               kCGBitmapByteOrder32Little);
        if (!c) return nil;
        CGFloat in = std::min({(CGFloat)inset, w * 0.49, h * 0.49});
        CGRect rect = CGRectMake(in, in, w - in * 2, h - in * 2);
        CGFloat rad = std::min({(CGFloat)radius, rect.size.width * 0.5, rect.size.height * 0.5});
        CGPathRef path = CGPathCreateWithRoundedRect(rect, rad, rad, nullptr);
        CGContextSetRGBFillColor(c, 1, 1, 1, 1);
        CGContextAddPath(c, path);
        CGContextFillPath(c);
        CGPathRelease(path);
        CGContextRelease(c);
        NSData* nd = [NSData dataWithBytes:buf.data() length:buf.size()];
        return [CIImage imageWithBitmapData:nd bytesPerRow:bpr
                                       size:CGSizeMake(w, h)
                                     format:kCIFormatBGRA8 colorSpace:cs];
    }

    TOP_Context* myContext = nullptr;
    std::thread myThread;
    std::mutex myMutex;
    std::condition_variable myCond;
    bool myQuit = false, myPending = false, myBusy = false, myNCScaled = false;
    OP_SmartRef<OP_TOPDownloadResult> myImage, myMask;
    Params myParams;
    Result myResult;
    std::string mySig, myWarning;
    int64_t myLastA = -1, myLastM = -1;
    std::atomic<uint64_t> myExec{0}, mySubmit{0}, myFrames{0};
    std::atomic<float> myUsedBlur{0}, myUsedAlpha{0};
};

}   // namespace

extern "C" {

DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i)
{
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Ciglass");
    i->customOPInfo.opLabel->setString("CI Glass");
    i->customOPInfo.opIcon->setString("CIG");
    if (i->customOPInfo.opHelpURL)
        i->customOPInfo.opHelpURL->setString(
            "https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/blob/main/CoreImageGlass/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 1;
    i->customOPInfo.maxInputs = 2;
}

DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c)
{
    return new CoreImageGlassTOP(i, c);
}
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*)
{
    delete static_cast<CoreImageGlassTOP*>(i);
}

}
