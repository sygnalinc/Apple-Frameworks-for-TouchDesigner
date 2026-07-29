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

// cook(TDコンテキスト)から呼ぶ: ライブ編集用の Text DAT を自動生成し、
// 開いたドックチップとして接続する(タイプごとに反映される。パラメータ欄はEnter確定のため)
static void createLiveTextDAT(const TD::OP_NodeInfo* node, const char* currentText)
{
    if (!node || !node->context) return;
    PyGILState_STATE g = PyGILState_Ensure();
    std::string py;
    py += "try:\n";
    py += "\timport td\n";
    py += "\tn = __ct_node\n";
    py += "\tif not n.par.Textdat.eval():\n";        // 既に接続済みなら何もしない(上書きしない)
    py += "\t\tp = n.parent()\n";
    py += "\t\tnm = n.name + '_text'\n";
    py += "\t\td = p.op(nm)\n";
    py += "\t\tif not d:\n";
    py += "\t\t\td = p.create(td.textDAT, nm)\n";
    py += "\t\t\td.text = __ct_text\n";
    py += "\t\t\td.dock = n\n";
    py += "\t\t\td.expose = True\n";
    py += "\t\t\td.viewer = True\n";
    py += "\t\t\td.showDocked = True\n";   // 開いたチップ=すぐ編集できる
    py += "\t\tn.par.Textdat = nm\n";
    py += "except Exception:\n";
    py += "\timport traceback as __ct_tb\n";
    py += "\t__ct_err = __ct_tb.format_exc()\n";
    PyObject* main = PyImport_AddModule("__main__");
    PyObject* dict = main ? PyModule_GetDict(main) : nullptr;
    PyObject* args = node->context->createArgumentsTuple(0, nullptr);
    PyObject* txt = PyUnicode_FromString(currentText ? currentText : "");
    if (dict && args && txt) {
        PyDict_SetItemString(dict, "__ct_node", PyTuple_GET_ITEM(args, 0));
        PyDict_SetItemString(dict, "__ct_text", txt);
        PyObject* r = PyRun_String(py.c_str(), Py_file_input, dict, dict);
        if (r) Py_DECREF(r); else PyErr_Clear();
        PyDict_DelItemString(dict, "__ct_node");
        PyDict_DelItemString(dict, "__ct_text");
    }
    if (txt) Py_DECREF(txt);
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

// Style DAT の1行 = 範囲スタイル。リッチテキスト(範囲ごとの色/サイズ/フォント)+ ルビ + 縦中横
struct StyleRun {
    std::string match;                 // text列: この部分文字列の全出現に適用
    int start = -1, length = -1;       // start/length列: 文字インデックス(合成文字単位)
    std::string font;                  // 空=継承
    float size = 0, weight = 0;        // 0=継承
    int italic = -1, underline = -1;   // -1=継承
    bool hasColor = false; float rgba[4] = {1,1,1,1};
    bool hasTracking = false; float tracking = 0;
    std::string ruby;                  // ルビ(振り仮名)
    float rubySize = 0.5f;             // ルビの相対サイズ
    int upright = -1;                  // 縦書き時のグリフ形: 1=縦組み形(正立) 0=横組み形(90°回転)
};

struct Style {
    std::string text, fontName, fontFile;
    bool palt = false;                 // プロポーショナルメトリクス(OpenType 'palt'。自動文字詰め)
    float fontSize = 72, weight = 400, tracking = 0, lineHeight = 1.0f;
    float shearX = 0, shearY = 0;      // アフィン変換によるシアー(度)。疑似イタリック
    float slant = 0;                   // 可変フォントの 'slnt' 軸(度・対応書体のみ)
    int ligatures = 1;                 // 0=none 1=standard 2=all
    int alignH = 1, alignV = 1;        // 0=left/top 1=center/middle 2=right/bottom 3=justified(Hのみ)
    bool italic = false, vertical = false, autofit = false;
    int truncate = 0;                  // 0=off 1=tail 2=head 3=middle(領域に収まらない時の省略)
    std::vector<StyleRun> runs;        // リッチテキスト/ルビ/縦中横(Style DAT)
    std::string runsSig;               // runs の変更検知用
    int shape = 0;                     // 0=rect 1=ellipse 2=rounded 3=polygon 4=path DAT
    int shapeSides = 6; float shapeRound = 0.25f, shapeRotate = 0;
    std::vector<std::pair<float,float>> shapePath;   // shape=4 のuv点列
    std::string ellipsis = "…";       // 省略記号
    int wrapMode = 0;                  // 0=wrap 1=nowrap 2=balance 3=pretty 4=stable(=wrap)
    float padding = 20;
    float fontRGBA[4] = {1,1,1,1};
    float bgRGBA[4] = {0,0,0,0};
    bool gradient = false; float gradRGBA[4] = {0.2f,0.5f,1,1}; float gradAngle = 0;
    float strokeWidth = 0; float strokeRGBA[4] = {0,0,0,1};
    float embolden = 0;                // 合成ボールド(px)。フォントの最大ウェイト以上に太らせる
    bool shadow = false; float shadowRGBA[4] = {0,0,0,0.75f}; float shadowX = 0, shadowY = -6, shadowBlur = 8;
    int w = 1280, h = 720;

    std::string sig() const {
        char b[640];
        snprintf(b, sizeof b, "%s|%.2f|%.0f|%.2f|%.3f|%d|%d|%d|%d%d%d|%.1f|"
                 "%.3f%.3f%.3f%.3f|%.3f%.3f%.3f%.3f|%d|%.3f%.3f%.3f%.3f|%.1f|"
                 "%.2f|%.3f%.3f%.3f%.3f|%d|%.3f%.3f%.3f%.3f|%.1f|%.1f|%.1f|%dx%d",
                 fontName.c_str(), fontSize, weight, tracking, lineHeight, ligatures,
                 alignH, alignV, italic, vertical, wrapMode, padding,
                 fontRGBA[0],fontRGBA[1],fontRGBA[2],fontRGBA[3],
                 bgRGBA[0],bgRGBA[1],bgRGBA[2],bgRGBA[3],
                 gradient, gradRGBA[0],gradRGBA[1],gradRGBA[2],gradRGBA[3], gradAngle,
                 strokeWidth, strokeRGBA[0],strokeRGBA[1],strokeRGBA[2],strokeRGBA[3],
                 shadow, shadowRGBA[0],shadowRGBA[1],shadowRGBA[2],shadowRGBA[3],
                 shadowX, shadowY, shadowBlur + embolden * 1000.0f, w, h);
        char sh[128];
        snprintf(sh, sizeof sh, "|s%d|%d|%.3f|%.1f|%zu|sh%.2f,%.2f,%.2f",
                 shape, shapeSides, shapeRound, shapeRotate, shapePath.size(), shearX, shearY, slant);
        return text + "\x1f" + fontFile + "\x1f" + ellipsis + "\x1f" + runsSig + "\x1f" + sh + "\x1f"
             + (palt ? "P" : "p") + (autofit ? "F" : "f") + std::to_string(truncate) + "\x1f" + b;
    }
};

struct Result { std::vector<uint8_t> bgra; int w=0,h=0; uint64_t serial=0; int lines=0; float fitted=0; bool truncated=false; std::string font; };

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
    // 可変フォントの軸(weight / slant)。対応書体でのみ効く
    if (st.weight != 400 || st.slant != 0) {
        const uint32_t kWght = 0x77676874;   // 'wght'
        const uint32_t kSlnt = 0x736c6e74;   // 'slnt'
        CFMutableDictionaryRef variation = CFDictionaryCreateMutable(nullptr, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (st.weight != 400) {
            CFNumberRef axis = CFNumberCreate(nullptr, kCFNumberSInt32Type, &kWght);
            float wv = st.weight;
            CFNumberRef v = CFNumberCreate(nullptr, kCFNumberFloatType, &wv);
            CFDictionarySetValue(variation, axis, v); CFRelease(axis); CFRelease(v);
        }
        if (st.slant != 0) {
            CFNumberRef axis = CFNumberCreate(nullptr, kCFNumberSInt32Type, &kSlnt);
            float sv = st.slant;
            CFNumberRef v = CFNumberCreate(nullptr, kCFNumberFloatType, &sv);
            CFDictionarySetValue(variation, axis, v); CFRelease(axis); CFRelease(v);
        }
        CFDictionaryRef attrs = CFDictionaryCreate(nullptr, (const void**)&kCTFontVariationAttribute,
                                                   (const void**)&variation, 1,
                                                   &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes(attrs);
        CTFontRef varied = CTFontCreateCopyWithAttributes(base, st.fontSize, nullptr, desc);
        CFRelease(desc); CFRelease(attrs); CFRelease(variation);
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
    // シアー(疑似イタリック): フォント行列にせん断成分を入れる。書体を問わず角度指定でき、
    // グリフ形状そのものが変形するので縁取り/Embolden/グラデ/シャドウも自動的に追従する
    if (st.shearX != 0 || st.shearY != 0) {
        CGAffineTransform mtx = CGAffineTransformMake(
            1.0, (CGFloat)tan(st.shearY * M_PI / 180.0),      // b: 縦方向のシアー
            (CGFloat)tan(st.shearX * M_PI / 180.0), 1.0,      // c: 横方向のシアー(右に倒す=正)
            0, 0);
        CTFontRef sheared = CTFontCreateCopyWithAttributes(base, st.fontSize, &mtx, nullptr);
        if (sheared) { CFRelease(base); base = sheared; }
    }
    return base;
}

// 属性付き文字列(塗り)。ストロークは同一フレームを kCGTextStroke で再描画する
// (別属性文字列で2回レイアウトするとグリフがズレる実バグを踏んだため)
static CFAttributedStringRef makeAttrStringFrom(const Style& st, CTFontRef font, CFStringRef srcText)
{
    CFStringRef text = srcText ? (CFStringRef)CFRetain(srcText)
                               : CFStringCreateWithCString(nullptr, st.text.c_str(), kCFStringEncodingUTF8);
    if (!text) text = (CFStringRef)CFRetain(CFSTR(""));

    CTTextAlignment al = kCTTextAlignmentCenter;
    if (st.alignH == 0) al = kCTTextAlignmentLeft;
    else if (st.alignH == 2) al = kCTTextAlignmentRight;
    else if (st.alignH == 3) al = kCTTextAlignmentJustified;
    CTLineBreakMode lb = (st.wrapMode == 1) ? kCTLineBreakByClipping : kCTLineBreakByWordWrapping;
    // 行送り: LineHeightMultiple は1行目のベースラインまで動かしてしまう(実測)ため使わない。
    // 1.0超は「行間への加算」(LineSpacingAdjustment・1行目は不動)、
    // 1.0未満は行高自体を詰める(MaximumLineHeight。この場合のみ1行目もわずかに動く)
    CGFloat natural = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font);
    CGFloat delta = (st.lineHeight - 1.0f) * natural;
    CTParagraphStyleSetting ps[4];
    int nps = 0;
    ps[nps++] = { kCTParagraphStyleSpecifierAlignment, sizeof(al), &al };
    ps[nps++] = { kCTParagraphStyleSpecifierLineBreakMode, sizeof(lb), &lb };
    CGFloat spacing = delta, maxLH = 0;
    if (delta >= 0) {
        ps[nps++] = { kCTParagraphStyleSpecifierLineSpacingAdjustment, sizeof(spacing), &spacing };
    } else {
        maxLH = std::max<CGFloat>(natural + delta, 1);   // 0以下は不正なので1pxで下限ガード
        ps[nps++] = { kCTParagraphStyleSpecifierMaximumLineHeight, sizeof(maxLH), &maxLH };
    }
    CTParagraphStyleRef para = CTParagraphStyleCreate(ps, nps);

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

    CFAttributedStringRef base = CFAttributedStringCreate(nullptr, text, a);
    CFRelease(a); CFRelease(para);
    if (st.runs.empty()) { CFRelease(text); return base; }

    // --- リッチテキスト / ルビ / 縦中横: Style DAT の各行を範囲へ適用 ---
    CFMutableAttributedStringRef m = CFAttributedStringCreateMutableCopy(nullptr, 0, base);
    CFRelease(base);
    CFAttributedStringBeginEditing(m);
    const CFIndex len = CFStringGetLength(text);

    // 文字インデックス(合成文字単位)→ UTF-16 オフセット
    auto charToUTF16 = [&](int charIdx) -> CFIndex {
        if (charIdx <= 0) return 0;
        CFIndex i = 0; int n = 0;
        while (i < len && n < charIdx) {
            CFRange r = CFStringGetRangeOfComposedCharactersAtIndex(text, i);
            i = r.location + r.length; n++;
        }
        return i;
    };

    for (const StyleRun& run : st.runs) {
        // 適用範囲の決定(text列は全出現・start/length列は文字インデックス)
        std::vector<CFRange> ranges;
        if (!run.match.empty()) {
            CFStringRef needle = CFStringCreateWithCString(nullptr, run.match.c_str(), kCFStringEncodingUTF8);
            if (needle && CFStringGetLength(needle) > 0) {
                CFIndex from = 0;
                while (from < len) {
                    CFRange found;
                    if (!CFStringFindWithOptions(text, needle, CFRangeMake(from, len - from), 0, &found)) break;
                    ranges.push_back(found);
                    from = found.location + (found.length > 0 ? found.length : 1);
                }
            }
            if (needle) CFRelease(needle);
        } else if (run.start >= 0) {
            CFIndex s0 = charToUTF16(run.start);
            CFIndex s1 = (run.length >= 0) ? charToUTF16(run.start + run.length) : len;
            if (s1 > len) s1 = len;
            if (s0 < s1) ranges.push_back(CFRangeMake(s0, s1 - s0));
        }
        if (ranges.empty()) continue;

        // この行のフォント(継承しつつ上書き)
        CTFontRef runFont = nullptr;
        if (!run.font.empty() || run.size > 0 || run.weight > 0 || run.italic >= 0) {
            Style rs = st;
            rs.runs.clear();
            if (!run.font.empty()) { rs.fontName = run.font; rs.fontFile.clear(); }
            if (run.size > 0) rs.fontSize = run.size;
            if (run.weight > 0) rs.weight = run.weight;
            if (run.italic >= 0) rs.italic = (run.italic != 0);
            runFont = makeFont(rs);
        }

        for (const CFRange& r : ranges) {
            if (runFont) CFAttributedStringSetAttribute(m, r, kCTFontAttributeName, runFont);
            if (run.hasColor) {
                CGColorRef c = makeColor(run.rgba);
                CFAttributedStringSetAttribute(m, r, kCTForegroundColorAttributeName, c);
                CGColorRelease(c);
            }
            if (run.hasTracking) {
                CGFloat tr = run.tracking;
                CFNumberRef n = CFNumberCreate(nullptr, kCFNumberCGFloatType, &tr);
                CFAttributedStringSetAttribute(m, r, kCTTrackingAttributeName, n); CFRelease(n);
            }
            if (run.underline >= 0) {
                int32_t u = run.underline ? kCTUnderlineStyleSingle : kCTUnderlineStyleNone;
                CFNumberRef n = CFNumberCreate(nullptr, kCFNumberSInt32Type, &u);
                CFAttributedStringSetAttribute(m, r, kCTUnderlineStyleAttributeName, n); CFRelease(n);
            }
            // 縦書き時のグリフの向き。1=縦組み形(正立)/ 0=横組み形(縦書き中では90°回転)
            if (run.upright >= 0)
                CFAttributedStringSetAttribute(m, r, kCTVerticalFormsAttributeName,
                                               run.upright ? kCFBooleanTrue : kCFBooleanFalse);
            // ルビ(振り仮名)
            if (!run.ruby.empty()) {
                CFStringRef rb = CFStringCreateWithCString(nullptr, run.ruby.c_str(), kCFStringEncodingUTF8);
                if (rb) {
                    CGFloat sf = run.rubySize > 0 ? run.rubySize : 0.5;
                    CFNumberRef sfn = CFNumberCreate(nullptr, kCFNumberCGFloatType, &sf);
                    CFDictionaryRef attrs = CFDictionaryCreate(nullptr,
                        (const void**)&kCTRubyAnnotationSizeFactorAttributeName, (const void**)&sfn, 1,
                        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                    CTRubyAnnotationRef ruby = CTRubyAnnotationCreateWithAttributes(
                        kCTRubyAlignmentAuto, kCTRubyOverhangAuto, kCTRubyPositionBefore, rb, attrs);
                    if (ruby) {
                        CFAttributedStringSetAttribute(m, r, kCTRubyAnnotationAttributeName, ruby);
                        CFRelease(ruby);
                    }
                    CFRelease(attrs); CFRelease(sfn); CFRelease(rb);
                }
            }
        }
        if (runFont) CFRelease(runFont);
    }
    CFAttributedStringEndEditing(m);
    CFRelease(text);
    return m;
}

static CFAttributedStringRef makeAttrString(const Style& st, CTFontRef font, bool strokeOnly)
{
    (void)strokeOnly;
    return makeAttrStringFrom(st, font, nullptr);
}

// 折り返し計測: 幅 w で組んだときの行数・最終行幅・最大行幅
struct WrapInfo { int lines = 0; double lastW = 0, maxW = 0; };
static WrapInfo measureWrap(CFAttributedStringRef str, CGFloat w)
{
    WrapInfo out;
    CTFramesetterRef fs = CTFramesetterCreateWithAttributedString(str);
    CGPathRef path = CGPathCreateWithRect(CGRectMake(0, 0, w, 1e6), nullptr);
    CTFrameRef fr = CTFramesetterCreateFrame(fs, CFRangeMake(0,0), path, nullptr);
    CFArrayRef lines = CTFrameGetLines(fr);
    out.lines = (int)CFArrayGetCount(lines);
    for (CFIndex i = 0; i < out.lines; i++) {
        CTLineRef ln = (CTLineRef)CFArrayGetValueAtIndex(lines, i);
        double lw = CTLineGetTypographicBounds(ln, nullptr, nullptr, nullptr);
        out.maxW = std::max(out.maxW, lw);
        if (i == out.lines - 1) out.lastW = lw;
    }
    CFRelease(fr); CGPathRelease(path); CFRelease(fs);
    return out;
}

// balance / pretty 用の実効折り返し幅(横書きのみ)。
// balance: 行数を availW と同じに保ったまま折り返し幅を最小化 → 各行の長さが揃う
// pretty : 最終行が極端に短い(最大行の30%未満)とき、行数を変えずに幅を少し詰めて調整
static CGFloat effectiveWrapWidth(CFAttributedStringRef str, const Style& st, CGFloat availW)
{
    if (st.vertical || (st.wrapMode != 2 && st.wrapMode != 3)) return availW;
    WrapInfo base = measureWrap(str, availW);
    if (base.lines <= 1) return availW;
    if (st.wrapMode == 2) {   // balance: 二分探索で行数キープの最小幅
        CGFloat lo = availW * 0.2f, hi = availW;
        for (int i = 0; i < 16; i++) {
            CGFloat mid = (lo + hi) * 0.5f;
            if (measureWrap(str, mid).lines <= base.lines) hi = mid; else lo = mid;
        }
        return hi;
    }
    // pretty: 最終行の孤立(短すぎ)を検出したら 2% 刻みで幅を詰める(行数は維持)
    if (base.lastW >= base.maxW * 0.3) return availW;
    for (int i = 1; i <= 10; i++) {
        CGFloat w = availW * (1.0f - 0.02f * i);
        WrapInfo m = measureWrap(str, w);
        if (m.lines != base.lines) break;               // 行数が変わったら諦めて元の幅
        if (m.lastW >= m.maxW * 0.3) return w;          // 孤立解消
    }
    return availW;
}

// 組版領域の形。CTFramesetterCreateFrame は矩形以外の任意 CGPath を受け付けるので、
// 円・角丸・多角形・任意点列(Path DAT)にテキストを流し込める
static CGPathRef makeShapePath(const Style& st, CGRect rect)
{
    switch (st.shape) {
        case 1:   // ellipse
            return CGPathCreateWithEllipseInRect(rect, nullptr);
        case 2: { // rounded rect
            CGFloat r = std::min(rect.size.width, rect.size.height) * 0.5f * st.shapeRound;
            return CGPathCreateWithRoundedRect(rect, r, r, nullptr);
        }
        case 3: { // polygon(矩形に内接)
            int n = std::max(3, std::min(st.shapeSides, 64));
            CGMutablePathRef p = CGPathCreateMutable();
            CGFloat cx = CGRectGetMidX(rect), cy = CGRectGetMidY(rect);
            CGFloat rx = rect.size.width * 0.5f, ry = rect.size.height * 0.5f;
            double rot = st.shapeRotate * M_PI / 180.0 + M_PI_2;   // 既定で頂点が上
            for (int i = 0; i < n; i++) {
                double a = rot + 2.0 * M_PI * i / n;
                CGFloat x = cx + rx * (CGFloat)cos(a), y = cy + ry * (CGFloat)sin(a);
                if (i == 0) CGPathMoveToPoint(p, nullptr, x, y);
                else        CGPathAddLineToPoint(p, nullptr, x, y);
            }
            CGPathCloseSubpath(p);
            return p;
        }
        case 4: { // Path DAT の uv 点列(0..1 を rect にマップ)
            if (st.shapePath.size() < 3) break;
            CGMutablePathRef p = CGPathCreateMutable();
            for (size_t i = 0; i < st.shapePath.size(); i++) {
                CGFloat x = rect.origin.x + st.shapePath[i].first  * rect.size.width;
                CGFloat y = rect.origin.y + st.shapePath[i].second * rect.size.height;
                if (i == 0) CGPathMoveToPoint(p, nullptr, x, y);
                else        CGPathAddLineToPoint(p, nullptr, x, y);
            }
            CGPathCloseSubpath(p);
            return p;
        }
        default: break;
    }
    return CGPathCreateWithRect(rect, nullptr);
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
    // balance / pretty は実効折り返し幅を狭め、Horizontal Align に従って領域内に配置する
    CGFloat effW = effectiveWrapWidth(str, st, availW);
    CGFloat x = st.padding;
    if (effW < availW) {
        if (st.alignH == 2) x = st.padding + (availW - effW);            // right
        else if (st.alignH != 0) x = st.padding + (availW - effW) / 2;   // center / justify
    }
    CGRect rect = CGRectMake(x, st.padding, effW, availH);
    if (!st.vertical && st.alignV != 0) {
        // 使用高さを測って top/middle/bottom を実現(CTFrame は常に上詰めのため)
        CGSize used = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRangeMake(0,0), frameAttrs,
                                                                   CGSizeMake(effW, CGFLOAT_MAX), nullptr);
        CGFloat off = availH - used.height;
        if (off > 0) {
            if (st.alignV == 1) rect = CGRectMake(x, st.padding + off/2, effW, used.height + 2);
            else                rect = CGRectMake(x, st.padding, effW, used.height + 2);   // bottom(CG座標は下原点)
        }
        if (st.alignV == 0 && off > 0) rect = CGRectMake(x, st.padding + off, effW, used.height + 2); // top
    } else if (!st.vertical && st.alignV == 0) {
        // top は既定(上詰め)
    }
    // 矩形以外の形では縦位置合わせの矩形縮小を行わず、領域全体を形に使う
    if (st.shape != 0) rect = CGRectMake(st.padding, st.padding, availW, availH);
    CGPathRef path = makeShapePath(st, rect);
    CTFrameRef frame = CTFramesetterCreateFrame(fs, CFRangeMake(0,0), path, frameAttrs);
    if (outLines) *outLines = (int)CFArrayGetCount(CTFrameGetLines(frame));
    CGPathRelease(path);
    if (frameAttrs) CFRelease(frameAttrs);
    CFRelease(fs);
    return frame;
}

// 指定文字列が描画領域(解像度-余白)に収まるか。縦書きは幅/高さを入れ替えて判定する
static bool textFitsInArea(const Style& st, CTFontRef font, CFStringRef text)
{
    CGFloat availW = st.w - st.padding * 2, availH = st.h - st.padding * 2;
    if (availW <= 4 || availH <= 4) return true;
    CFAttributedStringRef str = makeAttrStringFrom(st, font, text);
    CTFramesetterRef fs = CTFramesetterCreateWithAttributedString(str);
    CFDictionaryRef frameAttrs = nullptr;
    if (st.vertical) {
        CTFrameProgression prog = kCTFrameProgressionRightToLeft;
        CFNumberRef pn = CFNumberCreate(nullptr, kCFNumberIntType, &prog);
        frameAttrs = CFDictionaryCreate(nullptr, (const void**)&kCTFrameProgressionAttributeName,
                                        (const void**)&pn, 1,
                                        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(pn);
    }
    bool wraps = st.wrapMode != 1;   // nowrap は折り返さず1行で幅を見る
    CGSize cons = st.vertical
        ? CGSizeMake(CGFLOAT_MAX, wraps ? availH : CGFLOAT_MAX)
        : CGSizeMake(wraps ? availW : CGFLOAT_MAX, CGFLOAT_MAX);
    CGSize used = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRangeMake(0,0), frameAttrs, cons, nullptr);
    if (frameAttrs) CFRelease(frameAttrs);
    CFRelease(fs); CFRelease(str);
    return used.width <= availW + 0.5 && used.height <= availH + 0.5;
}

// 領域に収まらないとき、末尾/先頭/中央を省略記号(…)に置き換えて収まる最大量を二分探索する。
// UTF-16 の合成文字境界にスナップするので絵文字・結合文字を割らない。
// st.text を書き換える(以後の描画パスは全てこの文字列を使うので、縁取り/グラデ等とも整合する)
static bool applyTruncation(Style& st, CTFontRef font)
{
    if (st.truncate == 0 || st.text.empty()) return false;
    CFStringRef full = CFStringCreateWithCString(nullptr, st.text.c_str(), kCFStringEncodingUTF8);
    if (!full) return false;
    if (textFitsInArea(st, font, full)) { CFRelease(full); return false; }   // 収まるなら何もしない

    CFStringRef ell = CFStringCreateWithCString(nullptr, st.ellipsis.c_str(), kCFStringEncodingUTF8);
    if (!ell) ell = (CFStringRef)CFRetain(CFSTR("…"));
    const CFIndex len = CFStringGetLength(full);

    // 合成文字境界へスナップ(サロゲートペア・結合文字を割らない)
    auto snap = [&](CFIndex i) -> CFIndex {
        if (i <= 0) return 0;
        if (i >= len) return len;
        CFRange r = CFStringGetRangeOfComposedCharactersAtIndex(full, i);
        return (r.location < i) ? r.location : i;
    };
    // 残す文字数 keep(UTF-16単位)から候補文字列を作る
    auto candidate = [&](CFIndex keep) -> CFStringRef {
        CFMutableStringRef s = CFStringCreateMutable(nullptr, 0);
        if (st.truncate == 1) {                       // tail: 先頭を残して末尾を省略
            CFIndex k = snap(keep);
            CFStringRef head = CFStringCreateWithSubstring(nullptr, full, CFRangeMake(0, k));
            CFStringAppend(s, head); CFStringAppend(s, ell); CFRelease(head);
        } else if (st.truncate == 2) {                // head: 末尾を残して先頭を省略
            CFIndex start = snap(len - keep);
            CFStringRef tail = CFStringCreateWithSubstring(nullptr, full, CFRangeMake(start, len - start));
            CFStringAppend(s, ell); CFStringAppend(s, tail); CFRelease(tail);
        } else {                                      // middle: 前後を残して中央を省略
            CFIndex h = snap(keep / 2);
            CFIndex start = snap(len - (keep - h));
            if (start < h) start = h;
            CFStringRef head = CFStringCreateWithSubstring(nullptr, full, CFRangeMake(0, h));
            CFStringRef tail = CFStringCreateWithSubstring(nullptr, full, CFRangeMake(start, len - start));
            CFStringAppend(s, head); CFStringAppend(s, ell); CFStringAppend(s, tail);
            CFRelease(head); CFRelease(tail);
        }
        return s;
    };

    // 二分探索: 収まる最大の keep を求める
    CFIndex lo = 0, hi = len;
    CFStringRef best = nullptr;
    for (int i = 0; i < 18 && lo <= hi; i++) {
        CFIndex mid = (lo + hi) / 2;
        CFStringRef c = candidate(mid);
        if (textFitsInArea(st, font, c)) {
            if (best) CFRelease(best);
            best = c; lo = mid + 1;
        } else {
            CFRelease(c); if (mid == 0) break; hi = mid - 1;
        }
    }
    if (!best) best = candidate(0);   // 省略記号すら入らない場合も記号だけは出す

    // UTF-8 へ戻して st.text を差し替え
    CFIndex maxBytes = CFStringGetMaximumSizeForEncoding(CFStringGetLength(best), kCFStringEncodingUTF8) + 1;
    std::vector<char> buf((size_t)maxBytes, 0);
    if (CFStringGetCString(best, buf.data(), maxBytes, kCFStringEncodingUTF8)) st.text = buf.data();
    CFRelease(best); CFRelease(ell); CFRelease(full);
    return true;
}

// オートフィット: 描画領域(解像度-余白)に収まる最大フォントサイズを二分探索で求める。
// Word Wrap On なら折り返した全体が収まるサイズ、Off なら行がそのまま収まるサイズ。
// 縦書きは幅(段数)と高さを入れ替えて判定する。
static float fitFontSize(const Style& stIn)
{
    CGFloat availW = stIn.w - stIn.padding * 2, availH = stIn.h - stIn.padding * 2;
    if (availW <= 4 || availH <= 4 || stIn.text.empty()) return stIn.fontSize;
    auto fits = [&](float s) -> bool {
        Style tmp = stIn; tmp.fontSize = s;
        CTFontRef font = makeFont(tmp);
        if (!font) return true;
        CFAttributedStringRef str = makeAttrString(tmp, font, false);
        CTFramesetterRef fs = CTFramesetterCreateWithAttributedString(str);
        CFDictionaryRef frameAttrs = nullptr;
        if (tmp.vertical) {
            CTFrameProgression prog = kCTFrameProgressionRightToLeft;
            CFNumberRef pn = CFNumberCreate(nullptr, kCFNumberIntType, &prog);
            frameAttrs = CFDictionaryCreate(nullptr, (const void**)&kCTFrameProgressionAttributeName,
                                            (const void**)&pn, 1,
                                            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFRelease(pn);
        }
        bool wraps = tmp.wrapMode != 1;   // nowrap 以外は折り返す前提でフィット
        CGSize cons = tmp.vertical
            ? CGSizeMake(CGFLOAT_MAX, wraps ? availH : CGFLOAT_MAX)
            : CGSizeMake(wraps ? availW : CGFLOAT_MAX, CGFLOAT_MAX);
        CGSize used = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRangeMake(0,0), frameAttrs, cons, nullptr);
        if (frameAttrs) CFRelease(frameAttrs);
        CFRelease(fs); CFRelease(str); CFRelease(font);
        return used.width <= availW + 0.5 && used.height <= availH + 0.5;
    };
    float hi = stIn.fontSize;
    if (fits(hi)) return hi;          // 指定サイズのまま収まる(Autofitは縮小のみ)
    float lo = 4;
    for (int i = 0; i < 14; i++) {    // 0.01px級まで収束
        float mid = (lo + hi) * 0.5f;
        if (fits(mid)) lo = mid; else hi = mid;
    }
    return lo;
}

// テキストのアルファカバレッジを CIMorphologyMaximum で radius 分膨張させ、
// CGImageMask(0=塗る/255=塗らない)を作る。グリフのアウトラインデータに依存しないので
// システムUIフォント(SF)でも安全(=SFのアウトライン抽出は TD プロセス内でゴミ輪郭が混入する
// 実バグを踏んだため、パス方式は使わない)。絵文字にも効く。縁取り/合成ボールドの共通基盤。
static CGImageRef makeDilatedMask(const Style& st, CTFrameRef frame, float radius)
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef tc = CGBitmapContextCreate(nullptr, st.w, st.h, 8, (size_t)st.w*4, cs,
                                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!tc) return nullptr;
    CGContextClearRect(tc, CGRectMake(0, 0, st.w, st.h));
    CTFrameDraw(frame, tc);
    // 元テキストのアルファ(カウンター保護の基準)を先に抜いておく
    std::vector<uint8_t> base((size_t)st.w * st.h);
    {
        const uint8_t* tp = (const uint8_t*)CGBitmapContextGetData(tc);
        for (size_t i = 0; i < base.size(); i++) base[i] = tp[i*4 + 3];   // BGRA の A
    }
    CGImageRef textImg = CGBitmapContextCreateImage(tc);
    CGContextRelease(tc);
    if (!textImg) return nullptr;

    // CIで膨張(CIFilterはプロセス横断で直列化: 既知のTDクラッシュ対策)
    CGImageRef dilated = nullptr;
    @synchronized([CIFilter class]) {
        CIImage* ci = [CIImage imageWithCGImage:textImg];
        CIFilter* f = [CIFilter filterWithName:@"CIMorphologyMaximum"];
        [f setValue:ci forKey:kCIInputImageKey];
        [f setValue:@(radius) forKey:kCIInputRadiusKey];
        CIImage* outCI = [f.outputImage imageByCroppingToRect:CGRectMake(0, 0, st.w, st.h)];
        CIContext* cictx = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        if (outCI) dilated = [cictx createCGImage:outCI fromRect:CGRectMake(0, 0, st.w, st.h)];
    }
    CGImageRelease(textImg);
    if (!dilated) return nullptr;

    // 膨張後アルファ → CGImageMask
    CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
    CGContextRef ac = CGBitmapContextCreate(nullptr, st.w, st.h, 8, (size_t)st.w*4, cs2,
                                            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs2);
    if (!ac) { CGImageRelease(dilated); return nullptr; }
    CGContextClearRect(ac, CGRectMake(0, 0, st.w, st.h));
    CGContextDrawImage(ac, CGRectMake(0, 0, st.w, st.h), dilated);
    CGImageRelease(dilated);
    const uint8_t* px = (const uint8_t*)CGBitmapContextGetData(ac);
    // カウンター保護: 画像端から到達できる「外側の背景」をフラッドフィルで求め、
    // 膨張は外側にだけ許す。閉じた内側(o・口 などの穴)は元の形のまま残る
    const int W = st.w, H = st.h;
    std::vector<uint8_t> outside((size_t)W * H, 0);
    {
        std::vector<int> stack;
        stack.reserve(4096);
        auto push = [&](int x, int y) {
            int i = y * W + x;
            if (!outside[(size_t)i] && base[(size_t)i] < 8) { outside[(size_t)i] = 1; stack.push_back(i); }
        };
        for (int x = 0; x < W; x++) { push(x, 0); push(x, H - 1); }
        for (int y = 0; y < H; y++) { push(0, y); push(W - 1, y); }
        while (!stack.empty()) {
            int i = stack.back(); stack.pop_back();
            int x = i % W, y = i / W;
            if (x > 0) push(x - 1, y);
            if (x < W - 1) push(x + 1, y);
            if (y > 0) push(x, y - 1);
            if (y < H - 1) push(x, y + 1);
        }
        // 外側マップを2px膨張してグリフのAA縁(半透明画素)を含める。
        // これが無いと元グリフの輪郭に沿って塗りが薄い1pxの継ぎ目(暗い縁)が出る
        for (int pass = 0; pass < 2; pass++) {
            std::vector<uint8_t> prev = outside;
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++) {
                    size_t i = (size_t)y * W + x;
                    if (prev[i]) continue;
                    if ((x > 0 && prev[i-1]) || (x < W-1 && prev[i+1]) ||
                        (y > 0 && prev[i-(size_t)W]) || (y < H-1 && prev[i+(size_t)W]))
                        outside[i] = 1;
                }
        }
    }
    std::vector<uint8_t> maskBytes((size_t)W * H);
    for (size_t i = 0; i < maskBytes.size(); i++) {
        uint8_t dil = px[i*4 + 3];                                     // 膨張後アルファ(BGRA の A)
        uint8_t a = outside[i] ? std::max(base[i], dil) : base[i];     // 外側のみ膨張を反映
        maskBytes[i] = (uint8_t)(255 - a);
    }
    CGContextRelease(ac);
    NSData* data = [NSData dataWithBytes:maskBytes.data() length:maskBytes.size()];   // provider が保持
    CGDataProviderRef prov = CGDataProviderCreateWithCFData((CFDataRef)data);
    CGImageRef mask = CGImageMaskCreate(st.w, st.h, 8, 8, st.w, prov, nullptr, false);
    CGDataProviderRelease(prov);
    return mask;
}

// クリップ済み領域(または全面)へグラデーションを塗る(Font Color → Gradient Color 2・角度)
static void drawGradientFill(CGContextRef ctx, const Style& st)
{
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
}

// 膨張マスクでクリップして単色 or グラデーションを塗る
static void fillThroughDilatedMask(CGContextRef ctx, const Style& st, CTFrameRef frame,
                                   float radius, const float rgba[4], bool gradient)
{
    CGImageRef mask = makeDilatedMask(st, frame, radius);
    if (!mask) return;
    CGContextSaveGState(ctx);
    CGContextClipToMask(ctx, CGRectMake(0, 0, st.w, st.h), mask);
    if (gradient) {
        drawGradientFill(ctx, st);
    } else {
        CGColorRef c = makeColor(rgba);
        CGContextSetFillColorWithColor(ctx, c); CGColorRelease(c);
        CGContextFillRect(ctx, CGRectMake(0, 0, st.w, st.h));
    }
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
    drawGradientFill(ctx, st);
    CGContextRestoreGState(ctx);
}

static bool renderText(const Style& stIn, Result& out, std::string& warn)
{
    Style st = stIn;
    if (st.autofit) st.fontSize = fitFontSize(st);   // 描画領域に収まるサイズへ自動縮小
    out.fitted = st.fontSize;
    if (st.w < 4 || st.h < 4) return false;
    // 省略(…): 収まらない場合のみ st.text を差し替える。フォントは実サイズで作る必要があるので
    // ここで一度だけ生成して使い回す
    if (st.truncate != 0) {
        CTFontRef probe = makeFont(st);
        if (probe) { out.truncated = applyTruncation(st, probe); CFRelease(probe); }
    }
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
    // 描画順: 縁取り(最外周) → 合成ボールド(太らせた本体) → 本文テキスト
    if (st.strokeWidth > 0)
        fillThroughDilatedMask(ctx, st, frame, st.embolden + st.strokeWidth, st.strokeRGBA, false);
    if (st.embolden > 0)
        fillThroughDilatedMask(ctx, st, frame, st.embolden, st.fontRGBA, st.gradient);
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
        // Edit Text: ライブ編集用の Text DAT を生成・接続(cook文脈で実行)
        if (myEditTextPending) {
            myEditTextPending = false;
            createLiveTextDAT(myNodeInfo, st.text.c_str());
        }
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
        // --- Style DAT: リッチテキスト / ルビ / 縦中横(ヘッダ行で列名を指定)---
        if (const OP_DATInput* sd = in->getParDAT("Styledat")) {
            auto col = [&](const char* name) -> int {
                for (int c = 0; c < sd->numCols; c++) {
                    const char* h = sd->getCell(0, c);
                    if (h && strcmp(h, name) == 0) return c;
                }
                return -1;
            };
            const int cMatch = col("text"), cStart = col("start"), cLen = col("length");
            const int cFont = col("font"), cSize = col("size"), cWeight = col("weight");
            const int cItalic = col("italic"), cUnder = col("underline"), cTrack = col("tracking");
            const int cR = col("r"), cG = col("g"), cB = col("b"), cA = col("a");
            const int cRuby = col("ruby"), cRubySize = col("rubysize"), cUpright = col("upright");
            auto cell = [&](int r, int c) -> const char* {
                if (c < 0 || r >= sd->numRows) return nullptr;
                const char* v = sd->getCell(r, c);
                return (v && *v) ? v : nullptr;
            };
            for (int r = 1; r < sd->numRows; r++) {
                StyleRun run;
                if (const char* v = cell(r, cMatch))  run.match = v;
                if (const char* v = cell(r, cStart))  run.start = atoi(v);
                if (const char* v = cell(r, cLen))    run.length = atoi(v);
                if (const char* v = cell(r, cFont))   run.font = v;
                if (const char* v = cell(r, cSize))   run.size = (float)atof(v);
                if (const char* v = cell(r, cWeight)) run.weight = (float)atof(v);
                if (const char* v = cell(r, cItalic)) run.italic = atoi(v);
                if (const char* v = cell(r, cUnder))  run.underline = atoi(v);
                if (const char* v = cell(r, cTrack))  { run.hasTracking = true; run.tracking = (float)atof(v); }
                if (const char* v = cell(r, cRuby))   run.ruby = v;
                if (const char* v = cell(r, cRubySize)) run.rubySize = (float)atof(v);
                if (const char* v = cell(r, cUpright)) run.upright = atoi(v);
                if (cR >= 0 || cG >= 0 || cB >= 0) {
                    run.hasColor = true;
                    run.rgba[0] = cell(r,cR) ? (float)atof(cell(r,cR)) : 1.0f;
                    run.rgba[1] = cell(r,cG) ? (float)atof(cell(r,cG)) : 1.0f;
                    run.rgba[2] = cell(r,cB) ? (float)atof(cell(r,cB)) : 1.0f;
                    run.rgba[3] = cell(r,cA) ? (float)atof(cell(r,cA)) : 1.0f;
                }
                if (run.match.empty() && run.start < 0) continue;   // 範囲指定が無い行は無視
                st.runs.push_back(run);
                // 変更検知用シグネチャ
                char b[256];
                snprintf(b, sizeof b, "|%d,%d,%.1f,%.0f,%d,%d,%.2f,%d%d%d%d,%.2f,%.2f,%.2f,%.2f,%.2f",
                         run.start, run.length, run.size, run.weight, run.italic, run.underline,
                         run.tracking, run.hasColor, run.hasTracking, run.upright, (int)run.ruby.size(),
                         run.rgba[0], run.rgba[1], run.rgba[2], run.rgba[3], run.rubySize);
                st.runsSig += run.match + run.font + run.ruby + b;
            }
        }
        // --- Shape: 組版領域の形 ---
        { std::string s = in->getParString("Shape") ? in->getParString("Shape") : "rect";
          st.shape = (s == "ellipse") ? 1 : (s == "rounded") ? 2 : (s == "polygon") ? 3 : (s == "path") ? 4 : 0; }
        st.shapeSides  = (int)in->getParInt("Shapesides");
        st.shapeRound  = (float)in->getParDouble("Shaperound");
        st.shapeRotate = (float)in->getParDouble("Shaperotate");
        if (st.shape == 4) {
            if (const OP_DATInput* pd = in->getParDAT("Shapedat")) {
                // 数値セルか(ヘッダ行の自動判定に使う)
                auto isNum = [](const char* s) -> bool {
                    if (!s || !*s) return false;
                    char* end = nullptr; strtod(s, &end);
                    while (end && *end == ' ') end++;
                    return end && *end == '\0';
                };
                // 列の決定: 列名に x/y・u/v・P(0)/P(1) があればそれを使う(SOP to DAT 対応)。
                // 無ければ先頭2列
                int cx = 0, cy = 1, startRow = 0;
                if (pd->numRows > 0) {
                    bool header = false;
                    for (int c = 0; c < pd->numCols; c++)
                        if (!isNum(pd->getCell(0, c))) { header = true; break; }
                    if (header) {
                        startRow = 1;
                        for (int c = 0; c < pd->numCols; c++) {
                            const char* h = pd->getCell(0, c);
                            if (!h) continue;
                            if (!strcmp(h,"x") || !strcmp(h,"u") || !strcmp(h,"P(0)") || !strcmp(h,"tx")) cx = c;
                            if (!strcmp(h,"y") || !strcmp(h,"v") || !strcmp(h,"P(1)") || !strcmp(h,"ty")) cy = c;
                        }
                    }
                }
                for (int r = startRow; r < pd->numRows; r++) {
                    const char* xs = cx < pd->numCols ? pd->getCell(r, cx) : nullptr;
                    const char* ys = cy < pd->numCols ? pd->getCell(r, cy) : nullptr;
                    if (!isNum(xs) || !isNum(ys)) continue;
                    st.shapePath.emplace_back((float)atof(xs), (float)atof(ys));
                }
                // 正規化: 点群のバウンディングボックスを 0..1 へ収める(SOPの任意単位でもそのまま使える)
                if (in->getParInt("Pathnormalize") != 0 && st.shapePath.size() >= 3) {
                    float minx = st.shapePath[0].first, maxx = minx;
                    float miny = st.shapePath[0].second, maxy = miny;
                    for (auto& pt : st.shapePath) {
                        minx = std::min(minx, pt.first);  maxx = std::max(maxx, pt.first);
                        miny = std::min(miny, pt.second); maxy = std::max(maxy, pt.second);
                    }
                    float dx = maxx - minx, dy = maxy - miny;
                    if (dx > 1e-6f && dy > 1e-6f)
                        for (auto& pt : st.shapePath) {
                            pt.first  = (pt.first  - minx) / dx;
                            pt.second = (pt.second - miny) / dy;
                        }
                }
                char b[64]; snprintf(b, sizeof b, "|p%zu", st.shapePath.size()); st.runsSig += b;
                for (auto& pt : st.shapePath) { char q[32]; snprintf(q, sizeof q, "%.3f,%.3f;", pt.first, pt.second); st.runsSig += q; }
            }
        }
        st.fontName  = in->getParString("Font") ? in->getParString("Font") : "";
        st.fontFile  = in->getParFilePath("Fontfile") ? in->getParFilePath("Fontfile") : "";
        st.palt      = in->getParInt("Palt") != 0;
        st.fontSize  = (float)in->getParDouble("Fontsize");
        st.autofit   = in->getParInt("Autofit") != 0;
        st.shearX    = (float)in->getParDouble("Shearx");
        st.shearY    = (float)in->getParDouble("Sheary");
        st.slant     = (float)in->getParDouble("Slant");
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
        { std::string s = in->getParString("Truncate") ? in->getParString("Truncate") : "off";
          st.truncate = (s == "tail") ? 1 : (s == "head") ? 2 : (s == "middle") ? 3 : 0; }
        st.ellipsis  = in->getParString("Ellipsis") ? in->getParString("Ellipsis") : "…";
        if (st.ellipsis.empty()) st.ellipsis = "…";
        { std::string s = in->getParString("Textwrap") ? in->getParString("Textwrap") : "wrap";
          st.wrapMode = (s == "nowrap") ? 1 : (s == "balance") ? 2 : (s == "pretty") ? 3 : (s == "stable") ? 4 : 0; }
        st.padding   = (float)in->getParDouble("Padding");
        readRGBA(in, "Fontcolor", st.fontRGBA);
        readRGBA(in, "Bgcolor", st.bgRGBA);
        st.gradient  = in->getParInt("Gradienton") != 0;
        readRGBA(in, "Gradcolor", st.gradRGBA);
        st.gradAngle = (float)in->getParDouble("Gradangle");
        st.strokeWidth = (float)in->getParDouble("Strokewidth");
        st.embolden  = (float)in->getParDouble("Embolden");
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
          r = myResult; myUploaded = r.serial; myLines = r.lines; myFitted = r.fitted;
          myTruncated = r.truncated; myFont = r.font; }
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
        { OP_NumericParameter p("Edittext"); p.label = "Edit Text (live Text DAT)"; p.page = P; m->appendPulse(p); }
        { OP_StringParameter p("Styledat"); p.label = "Style DAT (rich text / ruby)"; p.page = P; m->appendDAT(p); }
        // Font はフォントパネルで選んだ結果の表示欄(PostScript名・手入力も可。空=SFシステムフォント)
        { OP_StringParameter p("Font"); p.label = "Font (from Font Panel)"; p.page = P; m->appendString(p); }
        { OP_StringParameter p("Fontfile"); p.label = "Font File (.ttf/.otf, overrides Font)"; p.page = P; m->appendFile(p); }
        { OP_NumericParameter p("Fontpanel"); p.label = "Choose Font (macOS Font Panel)"; p.page = P; m->appendPulse(p); }
        { OP_NumericParameter p("Fontsize"); p.label = "Font Size (px)"; p.page = P; p.defaultValues[0] = 72; p.minSliders[0] = 8; p.maxSliders[0] = 400; p.minValues[0] = 1; p.clampMins[0] = true; m->appendFloat(p); }
        { OP_NumericParameter p("Autofit"); p.label = "Auto Fit Font Size (shrink to area)"; p.page = P; p.defaultValues[0] = 0; m->appendToggle(p); }
        { OP_NumericParameter p("Weight"); p.label = "Weight (100-900, variable font)"; p.page = P; p.defaultValues[0] = 400; p.minSliders[0] = 100; p.maxSliders[0] = 900; p.minValues[0] = 100; p.maxValues[0] = 900; p.clampMins[0] = p.clampMaxes[0] = true; m->appendFloat(p); }
        { OP_NumericParameter p("Italic"); p.label = "Italic"; p.page = P; m->appendToggle(p); }
        { OP_NumericParameter p("Shearx"); p.label = "Shear X (deg)"; p.page = P; p.defaultValues[0] = 0; p.minSliders[0] = -45; p.maxSliders[0] = 45; m->appendFloat(p); }
        { OP_NumericParameter p("Sheary"); p.label = "Shear Y (deg)"; p.page = P; p.defaultValues[0] = 0; p.minSliders[0] = -45; p.maxSliders[0] = 45; m->appendFloat(p); }
        { OP_NumericParameter p("Slant"); p.label = "Slant Axis (deg, variable font)"; p.page = P; p.defaultValues[0] = 0; p.minSliders[0] = -15; p.maxSliders[0] = 15; m->appendFloat(p); }
        { OP_NumericParameter p("Palt"); p.label = "Proportional Metrics (palt)"; p.page = P; m->appendToggle(p); }
        { OP_NumericParameter p("Tracking"); p.label = "Tracking (pt)"; p.page = P; p.defaultValues[0] = 0; p.minSliders[0] = -100; p.maxSliders[0] = 100; m->appendFloat(p); }
        { OP_NumericParameter p("Lineheight"); p.label = "Line Height (multiple)"; p.page = P; p.defaultValues[0] = 1.0; p.minSliders[0] = 0; p.maxSliders[0] = 3; m->appendFloat(p); }
        { OP_StringParameter p("Ligatures"); p.label = "Ligatures"; p.page = P; p.defaultValue = "standard";
          const char* n[] = {"none","standard","all"}; const char* l[] = {"None","Standard","All"}; m->appendMenu(p, 3, n, l); }
        { OP_StringParameter p("Alignh"); p.label = "Horizontal Align"; p.page = P; p.defaultValue = "center";
          const char* n[] = {"left","center","right","justify"}; const char* l[] = {"Left","Center","Right","Justify"}; m->appendMenu(p, 4, n, l); }
        { OP_StringParameter p("Alignv"); p.label = "Vertical Align"; p.page = P; p.defaultValue = "middle";
          const char* n[] = {"top","middle","bottom"}; const char* l[] = {"Top","Middle","Bottom"}; m->appendMenu(p, 3, n, l); }
        { OP_NumericParameter p("Vertical"); p.label = "Vertical Text (tategaki)"; p.page = P; m->appendToggle(p); }
        { OP_StringParameter p("Textwrap"); p.label = "Text Wrap"; p.page = P; p.defaultValue = "wrap";
          const char* n[] = {"wrap","nowrap","balance","pretty","stable"};
          const char* l[] = {"Wrap (fit to width)","No Wrap","Balance (even lines)","Pretty (no orphans)","Stable (= Wrap)"};
          m->appendMenu(p, 5, n, l); }
        { OP_StringParameter p("Truncate"); p.label = "Truncate (overflow)"; p.page = P; p.defaultValue = "off";
          const char* n[] = {"off","tail","head","middle"};
          // メニューラベルはASCIIのみ(TDのUIは非ASCIIが文字化けする)
          const char* l[] = {"Off (overflow / clip)","Tail (abc...)","Head (...xyz)","Middle (ab...yz)"};
          m->appendMenu(p, 4, n, l); }
        { OP_StringParameter p("Ellipsis"); p.label = "Ellipsis"; p.page = P; p.defaultValue = "…"; m->appendString(p); }
        { OP_StringParameter p("Shape"); p.label = "Layout Shape"; p.page = P; p.defaultValue = "rect";
          const char* n[] = {"rect","ellipse","rounded","polygon","path"};
          const char* l[] = {"Rectangle","Ellipse","Rounded Rect","Polygon","Path DAT (uv points)"};
          m->appendMenu(p, 5, n, l); }
        { OP_NumericParameter p("Shapesides"); p.label = "Polygon Sides"; p.page = P; p.defaultValues[0] = 6; p.minSliders[0] = 3; p.maxSliders[0] = 16; p.minValues[0] = 3; p.clampMins[0] = true; m->appendInt(p); }
        { OP_NumericParameter p("Shaperound"); p.label = "Corner Round (0-1)"; p.page = P; p.defaultValues[0] = 0.25; p.minSliders[0] = 0; p.maxSliders[0] = 1; m->appendFloat(p); }
        { OP_NumericParameter p("Shaperotate"); p.label = "Polygon Rotate (deg)"; p.page = P; p.defaultValues[0] = 0; p.minSliders[0] = 0; p.maxSliders[0] = 360; m->appendFloat(p); }
        { OP_StringParameter p("Shapedat"); p.label = "Path DAT (u v / SOP to DAT)"; p.page = P; m->appendDAT(p); }
        { OP_NumericParameter p("Pathnormalize"); p.label = "Normalize Path to Area"; p.page = P; p.defaultValues[0] = 1; m->appendToggle(p); }
        { OP_NumericParameter p("Padding"); p.label = "Padding (px)"; p.page = P; p.defaultValues[0] = 20; p.minSliders[0] = 0; p.maxSliders[0] = 200; p.minValues[0] = 0; p.clampMins[0] = true; m->appendFloat(p); }

        const char* S = "Style";
        { OP_NumericParameter p("Fontcolor"); p.label = "Font Color"; p.page = S;
          p.defaultValues[0]=1; p.defaultValues[1]=1; p.defaultValues[2]=1; p.defaultValues[3]=1; m->appendRGBA(p); }
        { OP_NumericParameter p("Bgcolor"); p.label = "Background Color"; p.page = S;
          p.defaultValues[0]=0; p.defaultValues[1]=0; p.defaultValues[2]=0; p.defaultValues[3]=0; m->appendRGBA(p); }
        { OP_NumericParameter p("Embolden"); p.label = "Embolden (px, beyond max weight)"; p.page = S; p.defaultValues[0] = 0; p.minSliders[0] = 0; p.maxSliders[0] = 20; p.minValues[0] = 0; p.clampMins[0] = true; m->appendFloat(p); }
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

    // macOS標準フォントパネルを開く。選択は changeFont: → cook経由で Font/Fontsize へ反映
    void pulsePressed(const char* name, void*) override {
        if (strcmp(name, "Edittext") == 0) { myEditTextPending = true; return; }
        if (strcmp(name, "Fontpanel") != 0) return;
        const OP_NodeInfo* node = myNodeInfo;
        dispatch_async(dispatch_get_main_queue(), ^{
            { std::lock_guard<std::mutex> l(gPanelMx); gPanelNode = node; }
            if (!gPanelBridge) gPanelBridge = [CTFontPanelBridge new];
            NSFontManager* fm = [NSFontManager sharedFontManager];
            fm.target = gPanelBridge;
            if (gPanelFont) [fm setSelectedFont:gPanelFont isMultiple:NO];
            [fm orderFrontFontPanel:nil];
        });
    }

    void getWarningString(OP_String* s, void*) override {
        std::lock_guard<std::mutex> l(myMutex);
        if (!myWarn.empty()) s->setString(myWarn.c_str());
    }
    int32_t getNumInfoCHOPChans(void*) override { return 7; }
    void getInfoCHOPChan(int32_t i, OP_InfoCHOPChan* c, void*) override {
        const char* n[] = {"executes","renders","width","height","lines","fitted_size","truncated"};
        float v[] = {(float)myExec.load(), (float)myRenders.load(), (float)myOutW, (float)myOutH, (float)myLines, myFitted,
                     myTruncated ? 1.0f : 0.0f};
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
    bool myEditTextPending = false;            // Edit Text パルスの保留
    TOP_Context* myContext = nullptr;
    std::thread myThread; std::mutex myMutex; std::condition_variable myCond;
    bool myQuit = false, myPending = false, myBusy = false;
    Style myStyle; Result myResult; uint64_t mySerial = 0, myUploaded = 0;
    std::string mySig, myWarn, myFont;
    int myOutW = 0, myOutH = 0, myLines = 0; float myFitted = 0; bool myTruncated = false;
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
    i->customOPInfo.majorVersion = 0;
    i->customOPInfo.minorVersion = 9;
    i->customOPInfo.minInputs = 0; i->customOPInfo.maxInputs = 0;
}
DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* i, TOP_Context* c) { return new CoreTextTOP(i, c); }
DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* i, TOP_Context*) { delete static_cast<CoreTextTOP*>(i); }
}
