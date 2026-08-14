// MapKit TOP 群(MapKit TOP / MapKit Look Around TOP)の共有ヘッダ。
// 取り込みの土台(フレーム構造・帰属表示の焼き込み・ビュー階層ヘルパ)だけを置く。
//
// **ObjC クラスはここに置かない**。同じクラス名を複数バンドルで定義すると、
// ObjC ランタイムが1つの実装を全バンドルへ使い回し、`owner` の C++ キャスト先が
// 食い違って UB になる(Multipeer は実装が完全同一だから成立していた)。
// ウインドウ/バー/SCK 出力の ObjC クラスは各 .mm でバンドル固有の名前で定義する。
//
// 前提: TOP_CPlusPlusBase.h / CPlusPlus_Common.h を **先に** include してから読むこと
// (str()/addF() が TD の型を使うため)。
#pragma once
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

namespace tdmk {

struct Frame {
    std::vector<uint8_t> bgra;
    uint32_t w = 0, h = 0;
    uint64_t serial = 0;
};

// 隠すとき画面内に残す量(pt)。**実測**: 0(完全に画面外)だと描画が止まり
// フレームが凍結する(輝度は保つが更新されない)。1pt 残せば動き続ける。
// 右下の最端 1pt はノッチ付き Mac の丸角ベゼルにほぼ隠れる
inline constexpr CGFloat kSliver = 1;

inline std::string str(const TD::OP_Inputs* in, const char* k, const char* d)
{
    const char* v = in->getParString(k);
    return v && *v ? v : d;
}

inline void addF(TD::OP_ParameterManager* m, const char* pg, const char* n, const char* l,
                 double def, double lo, double hi)
{
    TD::OP_NumericParameter p(n);
    p.label = l; p.page = pg;
    p.defaultValues[0] = def;
    p.minSliders[0] = lo; p.maxSliders[0] = hi;
    p.minValues[0] = lo;  p.maxValues[0] = hi;
    p.clampMins[0] = p.clampMaxes[0] = true;
    m->appendFloat(p);
}

// ビュー内蔵の帰属表示(Legal リンク)を隠す。公開 API には表示/非表示の口が無い。
// タイル読込後に再出現することがあるので毎 cook 掛け直す
inline void setLegalHidden(NSView* v, bool hidden)
{
    for (NSView* sub in v.subviews) {
        NSString* cls = NSStringFromClass(sub.class);
        if ([cls containsString:@"Attribution"] || [cls containsString:@"Legal"])
            sub.hidden = hidden;
        else
            setLegalHidden(sub, hidden);
    }
}

// Look Around の埋め込み表示は、MapKit が Pan / ズームのレコグナイザを**無効化して
// プレビュー専用にしている**(実測: enabled=0。navigationEnabled=YES でも変わらない)。
// 強制的に有効化すると実際に見回し・ズームが効く(実機で確認)。毎 cook 掛け直す
inline void enableAllGestures(NSView* v)
{
    for (NSGestureRecognizer* g in v.gestureRecognizers) g.enabled = YES;
    for (NSView* sub in v.subviews) enableAllGestures(sub);
}

inline NSView* findLookAroundView(NSView* root)
{
    if ([NSStringFromClass(root.class) isEqualToString:@"MKLookAroundView"]) return root;
    for (NSView* s in root.subviews) {
        NSView* r = findLookAroundView(s);
        if (r) return r;
    }
    return nil;
}

// 「(Appleロゴ) Apple Maps」の小さなパッチを一度だけ描き、アップロード直前のフレームへ
// 合成する。**受信時に焼いてはいけない** — SCK は静止中フレームを寄越さないので、
// トグルの変更が次のフレームまで反映されない(実測)。cook スレッド専用(ロック不要)
struct Attribution {
    std::vector<uint8_t> patch;
    uint32_t w = 0, h = 0, forH = 0;

    void ensure(uint32_t frameH)
    {
        if (forH == frameH && !patch.empty()) return;
        patch.clear();
        forH = frameH;
        NSString* text = @"\uF8FF Apple Maps";   // U+F8FF = システムフォントの Apple ロゴ
        const CGFloat fontSize = std::max<CGFloat>(11.0, (CGFloat)frameH * 0.018);
        CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, fontSize, NULL);
        NSDictionary* attrs = @{(id)kCTFontAttributeName: (__bridge id)font,
                                (id)kCTForegroundColorAttributeName:
                                    (id)[NSColor colorWithWhite:1.0 alpha:0.95].CGColor};
        CTLineRef line = CTLineCreateWithAttributedString(
            (__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:text
                                                                            attributes:attrs]);
        CGFloat asc = 0, desc = 0;
        const double tw = CTLineGetTypographicBounds(line, &asc, &desc, NULL);
        const CGFloat pad = fontSize * 0.5;
        w = (uint32_t)ceil(tw + pad * 2);
        h = (uint32_t)ceil(asc + desc + pad * 1.4);
        patch.assign((size_t)w * h * 4, 0);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(patch.data(), w, h, 8, w * 4, cs,
                                                 kCGImageAlphaPremultipliedFirst |
                                                 kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(cs);
        if (ctx) {
            CGContextSetRGBFillColor(ctx, 0, 0, 0, 0.45);   // 下地(どんな絵でも読めるように)
            CGPathRef bg = CGPathCreateWithRoundedRect(CGRectMake(0, 0, w, h), 4, 4, NULL);
            CGContextAddPath(ctx, bg); CGContextFillPath(ctx); CGPathRelease(bg);
            CGContextSetTextPosition(ctx, pad, pad * 0.7 + desc);
            CTLineDraw(line, ctx);
            CGContextRelease(ctx);
        } else {
            patch.clear();
        }
        CFRelease(line);
        CFRelease(font);
    }

    // f は bottom-up。パッチ(CG = 上から下)を行反転しながらアルファ合成する。
    // pos: 0=左下 1=右下 2=左上 3=右上
    void burn(Frame& f, int pos)
    {
        ensure(f.h);
        if (patch.empty() || w + 16 > f.w || h + 16 > f.h) return;
        const uint32_t m = std::max<uint32_t>(8, (uint32_t)(f.h * 0.012));
        const bool right = (pos == 1 || pos == 3);
        const bool top = (pos == 2 || pos == 3);
        const uint32_t baseX = right ? f.w - m - w : m;
        const uint32_t baseY = top ? f.h - m - h : m;   // bottom-up なので下 = 小さい行
        for (uint32_t py = 0; py < h; py++) {
            const uint8_t* src = patch.data() + (size_t)py * w * 4;
            uint8_t* dst = f.bgra.data() + ((size_t)(baseY + (h - 1 - py)) * f.w + baseX) * 4;
            for (uint32_t px = 0; px < w; px++) {
                const uint8_t* sp = src + (size_t)px * 4;
                uint8_t* dp = dst + (size_t)px * 4;
                const uint32_t a = sp[3];
                if (!a) continue;
                const uint32_t ia = 255 - a;
                dp[0] = (uint8_t)(sp[0] + (dp[0] * ia + 127) / 255);   // 事前乗算済み
                dp[1] = (uint8_t)(sp[1] + (dp[1] * ia + 127) / 255);
                dp[2] = (uint8_t)(sp[2] + (dp[2] * ia + 127) / 255);
                dp[3] = 255;
            }
        }
    }
};

}  // namespace tdmk
