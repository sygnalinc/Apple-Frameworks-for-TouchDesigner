// CoreText TOP — Apple のテキストレンダリング(Core Text + Core Graphics)で文字を描く TOP。
// TD標準 Text TOP との違い:
//   - SF Pro 等のシステムフォント・可変フォント(ウェイトを 100〜900 で無段階指定)
//   - カラー絵文字(😀🎉)・日本語縦書き(kCTVerticalForms + RightToLeft progression)
//   - 高品質AA(サブピクセル位置)・リガチャ・トラッキング・行送り・両端揃え
//   - グラデーション塗り・アウトライン(ストローク)・ドロップシャドウ
// レンダリングはワーカースレッド(パラメータ変化のシグネチャ検知で再描画)。cook 非ブロック。
// テキストは Text パラメータ、または Text DAT 参照(複数行は DAT が便利)。
#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <AppKit/AppKit.h>
#include <Python.h>
#include <algorithm>
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

// ---- macOS標準フォントパネル(NSFontPanel)ブリッジ ----
// パネルの選択(changeFont:)を受けて、要求元ノードの Font / Fontsize パラメータへ
// Python 経由で書き戻す。main thread 専用(AppKit + TD Python)。
// changeFont:(AppKit) からは TD オブジェクトに一切触れない(THREAD CONFLICT になる・実測)。
// 選択はグローバルに保存し、cook(TDコンテキスト)内の PyRun でパラメータへ書き戻す。
static std::mutex gPanelMx;
static const TD::OP_NodeInfo* gPanelNode = nullptr;   // パネルを開いたノード(破棄時にクリア)
static NSFont* gPanelFont = nil;                      // 現在の選択(convertFontの基準)
static std::string gPanelPendingName;                 // 未適用の選択(PostScript名)
static double gPanelPendingSize = 0;
static uint64_t gPanelSerial = 0;                     // 選択のたびに増える

// cook(TDコンテキスト)から呼ぶ: 自ノードの Font / Fontsize へ書き戻す
static void applyPanelFontToNode(const TD::OP_NodeInfo* node, const std::string& psName, double size)
{
    if (!node || !node->context) return;
    PyGILState_STATE g = PyGILState_Ensure();
    std::string py;
    py += "try:\n";
    py += "\tn = __ct_node\n";
    py += "\tn.par.Font = '"; py += psName; py += "'\n";
    char sz[64]; snprintf(sz, sizeof sz, "\tn.par.Fontsize = %.2f\n", size);
    py += sz;
    py += "except Exception:\n";
    py += "\timport traceback as __ct_tb\n";
    py += "\t__ct_err = __ct_tb.format_exc()\n";
    PyObject* main = PyImport_AddModule("__main__");
    PyObject* dict = main ? PyModule_GetDict(main) : nullptr;
    PyObject* args = node->context->createArgumentsTuple(0, nullptr);
    if (dict && args) {
        PyDict_SetItemString(dict, "__ct_node", PyTuple_GET_ITEM(args, 0));
        PyObject* r = PyRun_String(py.c_str(), Py_file_input, dict, dict);
        if (r) Py_DECREF(r); else PyErr_Clear();
        PyDict_DelItemString(dict, "__ct_node");
    }
    if (args) Py_DECREF(args);
    PyGILState_Release(g);
}

@interface CTFontPanelBridge : NSObject
@end
@implementation CTFontPanelBridge
- (void)changeFont:(id)sender {
    NSFontManager* fm = (NSFontManager*)sender;
    NSFont* base = gPanelFont ?: [NSFont systemFontOfSize:72];
    NSFont* f = [fm convertFont:base];
    if (!f) return;
    gPanelFont = f;
    // ここではTDに一切触らない。選択を保存し、cook側が拾って書き戻す
    std::lock_guard<std::mutex> l(gPanelMx);
    gPanelPendingName = f.fontName.UTF8String ?: "";
    gPanelPendingSize = (double)f.pointSize;
    gPanelSerial++;
}
@end
static CTFontPanelBridge* gPanelBridge = nil;

namespace {

struct Style {
    std::string text, fontName, fontFile;
    bool palt = false;                 // プロポーショナルメトリクス(OpenType 'palt'。自動文字詰め)
    float fontSize = 72, weight = 400, tracking = 0, lineHeight = 1.0f;
    int ligatures = 1;                 // 0=none 1=standard 2=all
    int alignH = 1, alignV = 1;        // 0=left/top 1=center/middle 2=right/bottom 3=justified(Hのみ)
    bool italic = false, vertical = false, wrap = true;
    float padding = 20;
    float fontRGBA[4] = {1,1,1,1};
    float bgRGBA[4] = {0,0,0,0};
    bool gradient = false; float gradRGBA[4] = {0.2f,0.5f,1,1}; float gradAngle = 0;
    float strokeWidth = 0; float strokeRGBA[4] = {0,0,0,1};
    bool shadow = false; float shadowRGBA[4] = {0,0,0,0.75f}; float shadowX = 0, shadowY = -6, shadowBlur = 8;
    int w = 1280, h = 720;

    std::string sig() const {
        char b[640];
        snprintf(b, sizeof b, "%s|%.2f|%.0f|%.2f|%.3f|%d|%d|%d|%d%d%d|%.1f|"
                 "%.3f%.3f%.3f%.3f|%.3f%.3f%.3f%.3f|%d|%.3f%.3f%.3f%.3f|%.1f|"
                 "%.2f|%.3f%.3f%.3f%.3f|%d|%.3f%.3f%.3f%.3f|%.1f|%.1f|%.1f|%dx%d",
                 fontName.c_str(), fontSize, weight, tracking, lineHeight, ligatures,
                 alignH, alignV, italic, vertical, wrap, padding,
                 fontRGBA[0],fontRGBA[1],fontRGBA[2],fontRGBA[3],
                 bgRGBA[0],bgRGBA[1],bgRGBA[2],bgRGBA[3],
                 gradient, gradRGBA[0],gradRGBA[1],gradRGBA[2],gradRGBA[3], gradAngle,
                 strokeWidth, strokeRGBA[0],strokeRGBA[1],strokeRGBA[2],strokeRGBA[3],
                 shadow, shadowRGBA[0],shadowRGBA[1],shadowRGBA[2],shadowRGBA[3],
                 shadowX, shadowY, shadowBlur, w, h);
        return text + "\x1f" + fontFile + "\x1f" + (palt ? "P" : "p") + "\x1f" + b;
    }
};

struct Result { std::vector<uint8_t> bgra; int w=0,h=0; uint64_t serial=0; int lines=0; std::string font; };

static CGColorRef makeColor(const float c[4]) { return CGColorCreateGenericRGB(c[0], c[1], c[2], c[3]); }

// appendRGBA の4成分を float[4] へ(getParDouble4 は double& 引数)
static void readRGBA(const OP_Inputs* in, const char* name, float out[4])
{
    double r=0, g=0, b=0, a=0;
    in->getParDouble4(name, r, g, b, a);
    out[0]=(float)r; out[1]=(float)g; out[2]=(float)b; out[3]=(float)a;
}

// フォント生成: 名前空欄=システムUIフォント(SF)。可変ウェイト('wght')→無ければ太字トレイト近似
static CTFontRef makeFont(const Style& st)
{
    CTFontRef base = nullptr;
    if (!st.fontFile.empty()) {
        // フォントファイル(.ttf/.otf/.ttc)直接指定が最優先
        CGDataProviderRef prov = CGDataProviderCreateWithFilename(st.fontFile.c_str());
        if (prov) {
            CGFontRef cg = CGFontCreateWithDataProvider(prov);
            CGDataProviderRelease(prov);
            if (cg) { base = CTFontCreateWithGraphicsFont(cg, st.fontSize, nullptr, nullptr); CGFontRelease(cg); }
        }
    }
    if (!base) {
        if (st.fontName.empty() || st.fontName == "system") {
            base = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, st.fontSize, nullptr);
        } else {
            CFStringRef nm = CFStringCreateWithCString(nullptr, st.fontName.c_str(), kCFStringEncodingUTF8);
            base = CTFontCreateWithName(nm, st.fontSize, nullptr);
            CFRelease(nm);
        }
    }
    if (!base) return nullptr;
    // OpenType 'palt'(プロポーショナルメトリクス=自動文字詰め。CSSの font-feature-settings: 'palt')
    if (st.palt) {
        CFStringRef tag = CFSTR("palt");
        int one = 1;
        CFNumberRef val = CFNumberCreate(nullptr, kCFNumberIntType, &one);
        const void* fk[] = { kCTFontOpenTypeFeatureTag, kCTFontOpenTypeFeatureValue };
        const void* fv[] = { tag, val };
        CFDictionaryRef feature = CFDictionaryCreate(nullptr, fk, fv, 2,
                                                     &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFArrayRef features = CFArrayCreate(nullptr, (const void**)&feature, 1, &kCFTypeArrayCallBacks);
        CFDictionaryRef attrs = CFDictionaryCreate(nullptr, (const void**)&kCTFontFeatureSettingsAttribute,
                                                   (const void**)&features, 1,
                                                   &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes(attrs);
        CTFontRef withPalt = CTFontCreateCopyWithAttributes(base, st.fontSize, nullptr, desc);
        CFRelease(desc); CFRelease(attrs); CFRelease(features); CFRelease(feature); CFRelease(val);
        if (withPalt) { CFRelease(base); base = withPalt; }
    }
    // 可変フォントの weight 軸(存在すれば)
    if (st.weight != 400) {
        const uint32_t kWght = 0x77676874;   // 'wght'
        CFNumberRef axis = CFNumberCreate(nullptr, kCFNumberSInt32Type, &kWght);
        float wv = st.weight;
        CFNumberRef val = CFNumberCreate(nullptr, kCFNumberFloatType, &wv);
        CFDictionaryRef variation = CFDictionaryCreate(nullptr, (const void**)&axis, (const void**)&val, 1,
                                                       &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionaryRef attrs = CFDictionaryCreate(nullptr, (const void**)&kCTFontVariationAttribute,
                                                   (const void**)&variation, 1,
                                                   &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes(attrs);
        CTFontRef varied = CTFontCreateCopyWithAttributes(base, st.fontSize, nullptr, desc);
        CFRelease(desc); CFRelease(attrs); CFRelease(variation); CFRelease(val); CFRelease(axis);
        if (varied) { CFRelease(base); base = varied; }
        // 可変軸が無いフォントでも 600 以上なら Bold トレイトで近似
        if (st.weight >= 600) {
            CTFontRef bold = CTFontCreateCopyWithSymbolicTraits(base, st.fontSize, nullptr,
                                                                kCTFontTraitBold, kCTFontTraitBold);
            if (bold) { CFRelease(base); base = bold; }
        }
    }
    if (st.italic) {
        CTFontRef it = CTFontCreateCopyWithSymbolicTraits(base, st.fontSize, nullptr,
                                                          kCTFontTraitItalic, kCTFontTraitItalic);
        if (it) { CFRelease(base); base = it; }
    }
    return base;
}

// 属性付き文字列(塗り)。ストロークは同一フレームを kCGTextStroke で再描画する
// (別属性文字列で2回レイアウトするとグリフがズレる実バグを踏んだため)
static CFAttributedStringRef makeAttrString(const Style& st, CTFontRef font, bool strokeOnly)
{
    CFStringRef text = CFStringCreateWithCString(nullptr, st.text.c_str(), kCFStringEncodingUTF8);
    if (!text) text = CFSTR("");

    CTTextAlignment al = kCTTextAlignmentCenter;
    if (st.alignH == 0) al = kCTTextAlignmentLeft;
    else if (st.alignH == 2) al = kCTTextAlignmentRight;
    else if (st.alignH == 3) al = kCTTextAlignmentJustified;
    CTLineBreakMode lb = st.wrap ? kCTLineBreakByWordWrapping : kCTLineBreakByClipping;
    CGFloat lh = st.lineHeight;
    CTParagraphStyleSetting ps[] = {
        { kCTParagraphStyleSpecifierAlignment, sizeof(al), &al },
        { kCTParagraphStyleSpecifierLineBreakMode, sizeof(lb), &lb },
        { kCTParagraphStyleSpecifierLineHeightMultiple, sizeof(lh), &lh },
    };
    CTParagraphStyleRef para = CTParagraphStyleCreate(ps, 3);

    CFMutableDictionaryRef a = CFDictionaryCreateMutable(nullptr, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(a, kCTFontAttributeName, font);
    CFDictionarySetValue(a, kCTParagraphStyleAttributeName, para);
    int lig = st.ligatures;
    CFNumberRef ligN = CFNumberCreate(nullptr, kCFNumberIntType, &lig);
    CFDictionarySetValue(a, kCTLigatureAttributeName, ligN); CFRelease(ligN);
    if (st.tracking != 0) {
        CGFloat tr = st.tracking;
        CFNumberRef trN = CFNumberCreate(nullptr, kCFNumberCGFloatType, &tr);
        CFDictionarySetValue(a, kCTTrackingAttributeName, trN); CFRelease(trN);
    }
    if (st.vertical) CFDictionarySetValue(a, kCTVerticalFormsAttributeName, kCFBooleanTrue);

    CGColorRef fill = makeColor(st.fontRGBA);
    CFDictionarySetValue(a, kCTForegroundColorAttributeName, fill); CGColorRelease(fill);
    (void)strokeOnly;

    CFAttributedStringRef s = CFAttributedStringCreate(nullptr, text, a);
    CFRelease(a); CFRelease(para); CFRelease(text);
    return s;
}

// フレーム作成(縦書きは progression RightToLeft)+ 縦位置合わせ
static CTFrameRef makeFrame(CFAttributedStringRef str, const Style& st, int* outLines)
{
    CTFramesetterRef fs = CTFramesetterCreateWithAttributedString(str);
    CFDictionaryRef frameAttrs = nullptr;
    if (st.vertical) {
        CTFrameProgression prog = kCTFrameProgressionRightToLeft;
        CFNumberRef p = CFNumberCreate(nullptr, kCFNumberIntType, &prog);
        frameAttrs = CFDictionaryCreate(nullptr, (const void**)&kCTFrameProgressionAttributeName,
                                        (const void**)&p, 1,
                                        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(p);
    }
    CGFloat availW = st.w - st.padding * 2, availH = st.h - st.padding * 2;
    CGRect rect = CGRectMake(st.padding, st.padding, availW, availH);
    if (!st.vertical && st.alignV != 0) {
        // 使用高さを測って top/middle/bottom を実現(CTFrame は常に上詰めのため)
        CGSize used = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRangeMake(0,0), frameAttrs,
                                                                   CGSizeMake(availW, CGFLOAT_MAX), nullptr);
        CGFloat off = availH - used.height;
        if (off > 0) {
            if (st.alignV == 1) rect = CGRectMake(st.padding, st.padding + off/2, availW, used.height + 2);
            else                rect = CGRectMake(st.padding, st.padding, availW, used.height + 2);   // bottom(CG座標は下原点)
        }
        if (st.alignV == 0 && off > 0) rect = CGRectMake(st.padding, st.padding + off, availW, used.height + 2); // top
    } else if (!st.vertical && st.alignV == 0) {
        // top は既定(上詰め)
    }
    CGPathRef path = CGPathCreateWithRect(rect, nullptr);
    CTFrameRef frame = CTFramesetterCreateFrame(fs, CFRangeMake(0,0), path, frameAttrs);
    if (outLines) *outLines = (int)CFArrayGetCount(CTFrameGetLines(frame));
    CGPathRelease(path);
    if (frameAttrs) CFRelease(frameAttrs);
    CFRelease(fs);
    return frame;
}

// ストローク(縁取り): テキストのアルファカバレッジを CIMorphologyMaximum で膨張させ、
// その差分領域をストローク色で塗る(外側アウトライン)。グリフのアウトラインデータに
// 依存しないので、システムUIフォント(SF)でも安全(=SFのアウトライン抽出は TD プロセス内で
// ゴミ輪郭が混入する実バグを踏んだため、パス方式は使わない)。絵文字にも縁が付く。
static void strokeByDilation(CGContextRef ctx, const Style& st, CTFrameRef frame)
{
    // 1) テキストを透明背景のBGRAに描き、アルファ=カバレッジを得る
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef tc = CGBitmapContextCreate(nullptr, st.w, st.h, 8, (size_t)st.w*4, cs,
                                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!tc) return;
    CGContextClearRect(tc, CGRectMake(0, 0, st.w, st.h));
    CTFrameDraw(frame, tc);
    CGImageRef textImg = CGBitmapContextCreateImage(tc);
    CGContextRelease(tc);
    if (!textImg) return;

    // 2) CIで半径=ストローク幅ぶん膨張(CIFilterはプロセス横断で直列化: 既知のTDクラッシュ対策)
    CGImageRef dilated = nullptr;
    @synchronized([CIFilter class]) {
        CIImage* ci = [CIImage imageWithCGImage:textImg];
        CIFilter* f = [CIFilter filterWithName:@"CIMorphologyMaximum"];
        [f setValue:ci forKey:kCIInputImageKey];
        [f setValue:@(st.strokeWidth) forKey:kCIInputRadiusKey];
        CIImage* outCI = [f.outputImage imageByCroppingToRect:CGRectMake(0, 0, st.w, st.h)];
        CIContext* cictx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        if (outCI) dilated = [cictx createCGImage:outCI fromRect:CGRectMake(0, 0, st.w, st.h)];
    }
    CGImageRelease(textImg);
    if (!dilated) return;

    // 3) 膨張後アルファを取り出して CGImageMask(0=塗る/255=塗らない)を作る
    CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
    CGContextRef ac = CGBitmapContextCreate(nullptr, st.w, st.h, 8, (size_t)st.w*4, cs2,
                                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs2);
    if (!ac) { CGImageRelease(dilated); return; }
    CGContextClearRect(ac, CGRectMake(0, 0, st.w, st.h));
    CGContextDrawImage(ac, CGRectMake(0, 0, st.w, st.h), dilated);
    CGImageRelease(dilated);
    const uint8_t* px = (const uint8_t*)CGBitmapContextGetData(ac);
    std::vector<uint8_t> maskBytes((size_t)st.w * st.h);
    for (size_t i = 0; i < maskBytes.size(); i++) maskBytes[i] = (uint8_t)(255 - px[i*4 + 3]);   // BGRA の A
    CGContextRelease(ac);
    CGDataProviderRef prov = CGDataProviderCreateWithData(nullptr, maskBytes.data(), maskBytes.size(), nullptr);
    CGImageRef mask = CGImageMaskCreate(st.w, st.h, 8, 8, st.w, prov, nullptr, false);
    CGDataProviderRelease(prov);
    if (!mask) return;

    // 4) マスクでクリップしてストローク色を塗る(この上に本文フィルを重ねる)
    CGContextSaveGState(ctx);
    CGContextClipToMask(ctx, CGRectMake(0, 0, st.w, st.h), mask);
    CGColorRef sc = makeColor(st.strokeRGBA);
    CGContextSetFillColorWithColor(ctx, sc); CGColorRelease(sc);
    CGContextFillRect(ctx, CGRectMake(0, 0, st.w, st.h));
    CGContextRestoreGState(ctx);
    CGImageRelease(mask);
}

static void drawGradientThroughMask(CGContextRef ctx, const Style& st, CTFrameRef frame)
{
    // テキストのアルファマスクを作り、クリップしてグラデーションを塗る
    CGContextRef mask = CGBitmapContextCreate(nullptr, st.w, st.h, 8, st.w, nullptr, kCGImageAlphaOnly);
    if (!mask) return;
    CTFrameDraw(frame, mask);
    CGImageRef maskImg = CGBitmapContextCreateImage(mask);
    CGContextRelease(mask);
    if (!maskImg) return;

    CGContextSaveGState(ctx);
    CGContextClipToMask(ctx, CGRectMake(0, 0, st.w, st.h), maskImg);
    CGImageRelease(maskImg);

    CGColorRef c0 = makeColor(st.fontRGBA), c1 = makeColor(st.gradRGBA);
    const void* colors[] = { c0, c1 };
    CFArrayRef arr = CFArrayCreate(nullptr, colors, 2, &kCFTypeArrayCallBacks);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGGradientRef grad = CGGradientCreateWithColors(cs, arr, nullptr);
    // 角度: 0°=上→下、90°=左→右(時計回り)
    double rad = st.gradAngle * M_PI / 180.0;
    CGFloat cx = st.w * 0.5f, cy = st.h * 0.5f;
    CGFloat r = 0.5f * sqrt((double)st.w*st.w + (double)st.h*st.h);
    CGPoint p0 = CGPointMake(cx - sin(rad)*r, cy + cos(rad)*r);
    CGPoint p1 = CGPointMake(cx + sin(rad)*r, cy - cos(rad)*r);
    CGContextDrawLinearGradient(ctx, grad, p0, p1, 0);
    CGGradientRelease(grad); CGColorSpaceRelease(cs); CFRelease(arr);
    CGColorRelease(c0); CGColorRelease(c1);
    CGContextRestoreGState(ctx);
}

static bool renderText(const Style& st, Result& out, std::string& warn)
{
    if (st.w < 4 || st.h < 4) return false;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(nullptr, st.w, st.h, 8, (size_t)st.w*4, cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);   // BGRA
    CGColorSpaceRelease(cs);
    if (!ctx) return false;

    // 高品質AA(サブピクセル位置。透明背景でも綺麗に乗るようスムージングはoff)
    CGContextSetAllowsAntialiasing(ctx, true);
    CGContextSetShouldAntialias(ctx, true);
    CGContextSetAllowsFontSmoothing(ctx, false);
    CGContextSetAllowsFontSubpixelPositioning(ctx, true);
    CGContextSetShouldSubpixelPositionFonts(ctx, true);

    // 必ずクリアする(CGBitmapContextCreate の確保メモリはゼロ初期化保証が無く、
    // 透明背景時に前回レンダのグリフ片=ヒープゴミがそのまま残る実バグを踏んだ)
    CGContextClearRect(ctx, CGRectMake(0, 0, st.w, st.h));
    // 背景
    if (st.bgRGBA[3] > 0) {
        CGColorRef bg = makeColor(st.bgRGBA);
        CGContextSetFillColorWithColor(ctx, bg); CGColorRelease(bg);
        CGContextFillRect(ctx, CGRectMake(0, 0, st.w, st.h));
    }

    CTFontRef font = makeFont(st);
    if (!font) { CGContextRelease(ctx); return false; }
    // 要求フォントと解決フォントの食い違い警告(フォールバック検知)。
    // 指定はファミリー名でもPostScript名でもありうるので、両方と比較してから警告する
    if (!st.fontName.empty() && st.fontName != "system" && st.fontFile.empty()) {
        CFStringRef fam = CTFontCopyFamilyName(font);
        char buf[256] = {0};
        if (fam) { CFStringGetCString(fam, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(fam); }
        out.font = buf;
        CFStringRef psn = CTFontCopyPostScriptName(font);
        char psbuf[256] = {0};
        if (psn) { CFStringGetCString(psn, psbuf, sizeof psbuf, kCFStringEncodingUTF8); CFRelease(psn); }
        if (st.fontName != buf && st.fontName != psbuf && st.fontName.find(buf) == std::string::npos)
            warn = "Font '" + st.fontName + "' resolved to '" + std::string(buf) + "'";
    } else {
        out.font = "(system)";
    }

    CFAttributedStringRef fillStr = makeAttrString(st, font, false);

    // シャドウ(透明レイヤーで塗り全体に適用)
    if (st.shadow) {
        CGColorRef shc = makeColor(st.shadowRGBA);
        CGContextSetShadowWithColor(ctx, CGSizeMake(st.shadowX, st.shadowY), st.shadowBlur, shc);
        CGColorRelease(shc);
        CGContextBeginTransparencyLayer(ctx, nullptr);
    }

    int lines = 0;
    CTFrameRef frame = makeFrame(fillStr, st, &lines);
    // 縁取り(外側アウトライン)を先に敷き、その上に本文フィルを重ねる
    if (st.strokeWidth > 0) strokeByDilation(ctx, st, frame);
    if (st.gradient) drawGradientThroughMask(ctx, st, frame);
    else             CTFrameDraw(frame, ctx);
    CFRelease(frame);

    if (st.shadow) CGContextEndTransparencyLayer(ctx);

    CFRelease(fillStr);
    CFRelease(font);

    // CGBitmapContext はメモリ先頭=画像上端。TD の CPUMem は下端始まりなので行反転してコピー
    const uint8_t* src = (const uint8_t*)CGBitmapContextGetData(ctx);
    out.bgra.resize((size_t)st.w * st.h * 4);
    size_t row = (size_t)st.w * 4;
    for (int y = 0; y < st.h; y++)
        memcpy(out.bgra.data() + (size_t)(st.h - 1 - y) * row, src + (size_t)y * row, row);
    out.w = st.w; out.h = st.h; out.lines = lines;
    CGContextRelease(ctx);
    return true;
}

class CoreTextTOP final : public TOP_CPlusPlusBase {
public:
    CoreTextTOP(const OP_NodeInfo* ni, TOP_Context* c) : myNodeInfo(ni), myContext(c) { myThread = std::thread([this]{ worker(); }); }
    ~CoreTextTOP() override {
        { std::lock_guard<std::mutex> l(gPanelMx); if (gPanelNode == myNodeInfo) gPanelNode = nullptr; }
        { std::lock_guard<std::mutex> l(myMutex); myQuit = true; } myCond.notify_all(); if (myThread.joinable()) myThread.join();
    }
    void getGeneralInfo(TOP_GeneralInfo* g, const OP_Inputs*, void*) override { g->cookEveryFrameIfAsked = true; }

    void execute(TOP_Output* out, const OP_Inputs* in, void*) override {
        myExec++;
        // フォントパネルの未適用選択を TD コンテキスト(cook)内で書き戻す
        {
            std::string ps; double sz = 0; bool apply = false;
            {
                std::lock_guard<std::mutex> l(gPanelMx);
                if (gPanelNode == myNodeInfo && gPanelSerial != myPanelApplied && !gPanelPendingName.empty()) {
                    myPanelApplied = gPanelSerial;
                    ps = gPanelPendingName; sz = gPanelPendingSize; apply = true;
                }
            }
            if (apply) applyPanelFontToNode(myNodeInfo, ps, sz);
        }
        Style st;
        st.text = in->getParString("Text") ? in->getParString("Text") : "";
        // Text DAT があれば優先(セルを行/タブで連結)
        if (const OP_DATInput* d = in->getParDAT("Textdat")) {
            std::string t;
            for (int r = 0; r < d->numRows; r++) {
                if (r) t += "\n";
                for (int c = 0; c < d->numCols; c++) {
                    if (c) t += "\t";
                    const char* cell = d->getCell(r, c);
                    if (cell) t += cell;
                }
            }
            st.text = t;
        }
        st.fontName  = in->getParString("Font") ? in->getParString("Font") : "";
        st.fontFile  = in->getParFilePath("Fontfile") ? in->getParFilePath("Fontfile") : "";
        st.palt      = in->getParInt("Palt") != 0;
        st.fontSize  = (float)in->getParDouble("Fontsize");
        st.weight    = (float)in->getParDouble("Weight");
        st.italic    = in->getParInt("Italic") != 0;
        st.tracking  = (float)in->getParDouble("Tracking");
        st.lineHeight= (float)in->getParDouble("Lineheight");
        { std::string s = in->getParString("Ligatures") ? in->getParString("Ligatures") : "standard";
          st.ligatures = (s == "none") ? 0 : (s == "all") ? 2 : 1; }
        { std::string s = in->getParString("Alignh") ? in->getParString("Alignh") : "center";
          st.alignH = (s == "left") ? 0 : (s == "right") ? 2 : (s == "justify") ? 3 : 1; }
        { std::string s = in->getParString("Alignv") ? in->getParString("Alignv") : "middle";
          st.alignV = (s == "top") ? 0 : (s == "bottom") ? 2 : 1; }
        st.vertical  = in->getParInt("Vertical") != 0;
        st.wrap      = in->getParInt("Wordwrap") != 0;
        st.padding   = (float)in->getParDouble("Padding");
        readRGBA(in, "Fontcolor", st.fontRGBA);
        readRGBA(in, "Bgcolor", st.bgRGBA);
        st.gradient  = in->getParInt("Gradienton") != 0;
        readRGBA(in, "Gradcolor", st.gradRGBA);
        st.gradAngle = (float)in->getParDouble("Gradangle");
        st.strokeWidth = (float)in->getParDouble("Strokewidth");
        readRGBA(in, "Strokecolor", st.strokeRGBA);
        st.shadow    = in->getParInt("Shadowon") != 0;
        readRGBA(in, "Shadowcolor", st.shadowRGBA);
        st.shadowX   = (float)in->getParDouble("Shadowx");
        st.shadowY   = (float)in->getParDouble("Shadowy");
        st.shadowBlur= (float)in->getParDouble("Shadowblur");
        // 解像度は他のTOPと同じく Common ページ(Output Resolution)から取得。
        // 本TOPは入力を持たないため既定の "Use Input" は無意味(127x127になる)→ 1280x720 を既定に
        {
            const char* om = in->getParString("outputresolution");
            if (!om || strcmp(om, "useinput") == 0) { st.w = 1280; st.h = 720; }
            else {
                OP_TextureDesc sug; out->getSuggestedOutputDesc(&sug, nullptr);
                st.w = (int)sug.width; st.h = (int)sug.height;
            }
            if (st.w < 4) st.w = 4; if (st.h < 4) st.h = 4;
        }

        std::string sig = st.sig();
        if (sig != mySig) {
            mySig = sig;
            std::unique_lock<std::mutex> l(myMutex, std::try_to_lock);
            if (l.owns_lock() && !myPending && !myBusy) { myStyle = st; myPending = true; mySubmit++; l.unlock(); myCond.notify_one(); }
            else mySig.clear();   // 取りこぼしたら次cookで再投入
        }

        Result r;
        { std::lock_guard<std::mutex> l(myMutex);
          if (myResult.serial == myUploaded || myResult.bgra.empty()) return;
          r = myResult; myUploaded = r.serial; myLines = r.lines; myFont = r.font; }
        TOP_UploadInfo ui; ui.textureDesc.texDim = OP_TexDim::e2D;
        ui.textureDesc.width = r.w; ui.textureDesc.height = r.h;
        ui.textureDesc.pixelFormat = OP_PixelFormat::BGRA8Fixed;
        auto b = myContext->createOutputBuffer(r.bgra.size(), TOP_BufferFlags::None, nullptr); if (!b) return;
        memcpy(b->data, r.bgra.data(), r.bgra.size());
        out->uploadBuffer(&b, ui, nullptr);
        myOutW = r.w; myOutH = r.h; myRenders++;
    }

    void setupParameters(OP_ParameterManager* m, void*) override {
        const char* P = "CoreText";
        { OP_StringParameter p("Text"); p.label = "Text"; p.page = P; p.defaultValue = "CoreText"; m->appendString(p); }
        { OP_StringParameter p("Textdat"); p.label = "Text DAT (overrides Text)"; p.page = P; m->appendDAT(p); }
        // Font はフォントパネルで選んだ結果の表示欄(PostScript名・手入力も可。空=SFシステムフォント)
        { OP_StringParameter p("Font"); p.label = "Font (from Font Panel)"; p.page = P; m->appendString(p); }
        { OP_StringParameter p("Fontfile"); p.label = "Font File (.ttf/.otf, overrides Font)"; p.page = P; m->appendFile(p); }
        { OP_NumericParameter p("Fontpanel"); p.label = "Choose Font (macOS Font Panel)"; p.page = P; m->appendPulse(p); }
        { OP_NumericParameter p("Fontsize"); p.label = "Font Size (px)"; p.page = P; p.defaultValues[0] = 72; p.minSliders[0] = 8; p.maxSliders[0] = 400; p.minValues[0] = 1; p.clampMins[0] = true; m->appendFloat(p); }
        { OP_NumericParameter p("Weight"); p.label = "Weight (100-900, variable font)"; p.page = P; p.defaultValues[0] = 400; p.minSliders[0] = 100; p.maxSliders[0] = 900; p.minValues[0] = 100; p.maxValues[0] = 900; p.clampMins[0] = p.clampMaxes[0] = true; m->appendFloat(p); }
        { OP_NumericParameter p("Italic"); p.label = "Italic"; p.page = P; m->appendToggle(p); }
        { OP_NumericParameter p("Palt"); p.label = "Proportional Metrics (palt)"; p.page = P; m->appendToggle(p); }
        { OP_NumericParameter p("Tracking"); p.label = "Tracking (pt)"; p.page = P; p.defaultValues[0] = 0; p.minSliders[0] = -5; p.maxSliders[0] = 50; m->appendFloat(p); }
        { OP_NumericParameter p("Lineheight"); p.label = "Line Height (multiple)"; p.page = P; p.defaultValues[0] = 1.0; p.minSliders[0] = 0.5; p.maxSliders[0] = 3; m->appendFloat(p); }
        { OP_StringParameter p("Ligatures"); p.label = "Ligatures"; p.page = P; p.defaultValue = "standard";
          const char* n[] = {"none","standard","all"}; const char* l[] = {"None","Standard","All"}; m->appendMenu(p, 3, n, l); }
        { OP_StringParameter p("Alignh"); p.label = "Horizontal Align"; p.page = P; p.defaultValue = "center";
          const char* n[] = {"left","center","right","justify"}; const char* l[] = {"Left","Center","Right","Justify"}; m->appendMenu(p, 4, n, l); }
        { OP_StringParameter p("Alignv"); p.label = "Vertical Align"; p.page = P; p.defaultValue = "middle";
          const char* n[] = {"top","middle","bottom"}; const char* l[] = {"Top","Middle","Bottom"}; m->appendMenu(p, 3, n, l); }
        { OP_NumericParameter p("Vertical"); p.label = "Vertical Text (tategaki)"; p.page = P; m->appendToggle(p); }
        { OP_NumericParameter p("Wordwrap"); p.label = "Word Wrap"; p.page = P; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Padding"); p.label = "Padding (px)"; p.page = P; p.defaultValues[0] = 20; p.minSliders[0] = 0; p.maxSliders[0] = 200; p.minValues[0] = 0; p.clampMins[0] = true; m->appendFloat(p); }

        const char* S = "Style";
        { OP_NumericParameter p("Fontcolor"); p.label = "Font Color"; p.page = S;
          p.defaultValues[0]=1; p.defaultValues[1]=1; p.defaultValues[2]=1; p.defaultValues[3]=1; m->appendRGBA(p); }
        { OP_NumericParameter p("Bgcolor"); p.label = "Background Color"; p.page = S;
          p.defaultValues[0]=0; p.defaultValues[1]=0; p.defaultValues[2]=0; p.defaultValues[3]=0; m->appendRGBA(p); }
        { OP_NumericParameter p("Gradienton"); p.label = "Gradient Fill"; p.page = S; m->appendToggle(p); }
        { OP_NumericParameter p("Gradcolor"); p.label = "Gradient Color 2"; p.page = S;
          p.defaultValues[0]=0.2; p.defaultValues[1]=0.5; p.defaultValues[2]=1; p.defaultValues[3]=1; m->appendRGBA(p); }
        { OP_NumericParameter p("Gradangle"); p.label = "Gradient Angle (deg)"; p.page = S; p.defaultValues[0] = 0; p.minSliders[0] = 0; p.maxSliders[0] = 360; m->appendFloat(p); }
        { OP_NumericParameter p("Strokewidth"); p.label = "Stroke Width (px)"; p.page = S; p.defaultValues[0] = 0; p.minSliders[0] = 0; p.maxSliders[0] = 10; p.minValues[0] = 0; p.clampMins[0] = true; m->appendFloat(p); }
        { OP_NumericParameter p("Strokecolor"); p.label = "Stroke Color"; p.page = S;
          p.defaultValues[0]=0; p.defaultValues[1]=0; p.defaultValues[2]=0; p.defaultValues[3]=1; m->appendRGBA(p); }
        { OP_NumericParameter p("Shadowon"); p.label = "Drop Shadow"; p.page = S; m->appendToggle(p); }
        { OP_NumericParameter p("Shadowcolor"); p.label = "Shadow Color"; p.page = S;
          p.defaultValues[0]=0; p.defaultValues[1]=0; p.defaultValues[2]=0; p.defaultValues[3]=0.75; m->appendRGBA(p); }
        { OP_NumericParameter p("Shadowx"); p.label = "Shadow Offset X"; p.page = S; p.defaultValues[0] = 0; p.minSliders[0] = -50; p.maxSliders[0] = 50; m->appendFloat(p); }
        { OP_NumericParameter p("Shadowy"); p.label = "Shadow Offset Y"; p.page = S; p.defaultValues[0] = -6; p.minSliders[0] = -50; p.maxSliders[0] = 50; m->appendFloat(p); }
        { OP_NumericParameter p("Shadowblur"); p.label = "Shadow Blur"; p.page = S; p.defaultValues[0] = 8; p.minSliders[0] = 0; p.maxSliders[0] = 50; p.minValues[0] = 0; p.clampMins[0] = true; m->appendFloat(p); }

    }

    void getWarningString(OP_String* s, void*) override {
        std::lock_guard<std::mutex> l(myMutex);
        if (!myWarn.empty()) s->setString(myWarn.c_str());
    }
    int32_t getNumInfoCHOPChans(void*) override { return 5; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[] = {"executes","renders","width","height","lines"};
        float v[] = {(float)myExec.load(), (float)myRenders.load(), (float)myOutW, (float)myOutH, (float)myLines};
        c->name->setString(n[i]); c->value = v[i];
    }
    bool getInfoDATSize(OP_InfoDATSize* s, void*) override { s->rows = 2; s->cols = 2; s->byColumn = false; return true; }
    void getInfoDATEntries(int32_t index, int32_t nEntries, OP_InfoDATEntries* e, void*) override {
        if (nEntries < 2) return;
        if (index == 0) { e->values[0]->setString("resolved_font"); std::lock_guard<std::mutex> l(myMutex); e->values[1]->setString(myFont.c_str()); }
        else { e->values[0]->setString("lines"); e->values[1]->setString(std::to_string(myLines).c_str()); }
    }

private:
    void worker() {
        while (true) {
            Style st;
            {
                std::unique_lock<std::mutex> l(myMutex);
                myCond.wait(l, [this]{ return myQuit || myPending; });
                if (myQuit) return;
                myPending = false; myBusy = true; st = myStyle;
            }
            Result r; std::string warn;
            bool ok = false;
            @autoreleasepool { ok = renderText(st, r, warn); }
            {
                std::lock_guard<std::mutex> l(myMutex);
                myWarn = warn;
                if (ok) { r.serial = ++mySerial; myResult = std::move(r); }
                myBusy = false;
            }
        }
    }

    const OP_NodeInfo* myNodeInfo = nullptr;   // フォントパネルからのパラメータ書き戻し用
    uint64_t myPanelApplied = 0;               // 適用済みのパネル選択シリアル
    TOP_Context* myContext = nullptr;
    std::thread myThread; std::mutex myMutex; std::condition_variable myCond;
    bool myQuit = false, myPending = false, myBusy = false;
    Style myStyle; Result myResult; uint64_t mySerial = 0, myUploaded = 0;
    std::string mySig, myWarn, myFont;
    int myOutW = 0, myOutH = 0, myLines = 0;
    std::atomic<uint64_t> myExec{0}, mySubmit{0}, myRenders{0};
};

} // namespace

extern "C" {
DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* i) {
    if (!i->setAPIVersion(TOPCPlusPlusAPIVersion)) return;
    i->executeMode = TOP_ExecuteMode::CPUMem;
    i->customOPInfo.opType->setString("Coretext");
    i->customOPInfo.opLabel->setString("CoreText");
    i->customOPInfo.opIcon->setString("CTX");
    if (i->customOPInfo.opHelpURL) i->customOPInfo.opHelpURL->setString("https://github.com/sygnalinc/TDAppleOps/blob/main/CoreText/README.md");
    i->customOPInfo.authorName->setString("SYGNAL Inc.");
    i->customOPInfo.minInputs = 0; i->customOPInfo.maxInputs = 0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new CoreTextTOP(i, c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<CoreTextTOP*>(i); }
}
