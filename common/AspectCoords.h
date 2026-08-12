// AspectCoords.h — Vision 系OPの uv 出力を入力画像のアスペクト比に合わせて再スケールする共通ヘルパ
//
// TD標準 **Body Track CHOP の "Aspect Correct UVs"** と同じ役割・同じパラメータ名で提供する。
// (公式説明: "Rescales the u and v positions so that they have the correct aspect ratio
//  of the input image." — uv を3D位置として使うときに有用)
//
// 背景: Vision の座標は 0〜1 の正規化値(左下原点)で TDのuv系と整合するが、
// **u の1単位と v の1単位はピクセル距離が違う**(1280x720 なら 0.1 は横128px・縦72px)。
// そのため uv をそのままインスタンスの位置に流すと、点の配置が縦に間延びする。
//
// 変換式(Off のときは無変換):
//   aspect = width / height
//   u' = u                              (0〜1 のまま)
//   v' = 0.5 + (v - 0.5) / aspect       (中心 0.5 を保って縦を 1/aspect に縮める)
//   bbox の height も 1/aspect、width はそのまま
//
// **u を 0〜1 に保つのが要点**。これにより
//   Instance TX = u - 0.5 / TY = v' - 0.5 → **Ortho Width = 1 のカメラのまま**
// 映像にぴったり重なる(Ortho Width=1 は横幅いっぱい、縦は自動的に 1/aspect になるため)。
// 16:9 なら v' は 0.21875〜0.78125 の範囲になり、1単位が縦横で同じピクセル距離になる。
// 縦長画像(aspect<1)でもカメラの縦視野が広がるので同じ式でそのまま合う。
//
// 使い方:
//   const tdaspect::Mapper map{ inputs->getParInt("Aspectcorrectuv") != 0,
//                               top ? (float)top->textureDesc.width  : 0.0f,
//                               top ? (float)top->textureDesc.height : 0.0f };
//   out = map.x(u);   out = map.y(v);      // 位置
//   out = map.dx(bw); out = map.dy(bh);    // 幅・高さ
//   信頼度・角度・3D座標(メートル)は変換しない
//
// パラメータ追加は appendAspectCorrect() を呼ぶだけ。既定 Off なので既存 .toe は従来動作のまま。
#pragma once

namespace tdaspect {

struct Mapper
{
    bool  enabled = false;
    float w = 0, h = 0;          // 入力画像のピクセルサイズ(0なら変換しない)

    bool  on() const { return enabled && w > 0 && h > 0; }
    float aspect() const { return (h > 0) ? (w / h) : 1.0f; }

    float x(float u)  const { return u; }                                   // u は 0〜1 のまま
    float y(float v)  const { return on() ? 0.5f + (v - 0.5f) / aspect() : v; }
    float dx(float d) const { return d; }
    float dy(float d) const { return on() ? d / aspect() : d; }
};

// "Aspect Correct UVs" トグルを追加する(Body Track CHOP と同じラベル・既定Off)
template <class ParamManager, class NumericParameter>
inline void appendAspectCorrect(ParamManager* manager, const char* page = nullptr)
{
    NumericParameter p("Aspectcorrectuv");
    p.label = "Aspect Correct UVs";
    if (page) p.page = page;
    p.defaultValues[0] = 0;
    manager->appendToggle(p);
}

} // namespace tdaspect
