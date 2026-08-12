# CI Glass TOP

**English** | [日本語](#日本語)

## English

Applies the macOS frosted-glass look — and macOS 26's Liquid Glass — to an image.

Input 0 is the background. Input 1 is an optional mask (white = glass); without it the operator
builds a rounded rectangle from `Corner Radius` and `Inset`.

### Why it is rebuilt rather than borrowed

**The real API cannot be turned into a texture.** `NSVisualEffectView` with `.behindWindow` is
composited by the window server against what is literally behind the window on screen; rendering
the view offscreen with `cacheDisplay` yields a flat translucent panel with no blur at all
(measured — the checkerboard behind it stayed perfectly sharp). The same applies to
`NSGlassEffectView`.

So the effect is rebuilt in Core Image. The presets are not guesses: the real views were put on
screen over a known test image, captured with `screencapture`, and the numbers solved from the
composite:

```
output over black = tint x alpha
output over white = (1 - alpha) + tint x alpha
```

### Measured presets

Frosted (`NSVisualEffectView`), tint / alpha / blur radius in points:

| Material | Dark | Light |
|---|---|---|
| HUD Window | (0.20, 0.23, 0.24) · 0.45 · 35 | (0.87, 0.89, 0.89) · 0.53 · 35 |
| Popover | (0.19, 0.21, 0.21) · 0.64 · 35 | (0.87, 0.89, 0.89) · 0.65 · 33 |
| Menu | (0.18, 0.20, 0.20) · 0.73 · 35 | (0.87, 0.88, 0.89) · 0.78 · 32 |
| Sidebar / Under Window | (0.18, 0.20, 0.20) · 0.83 · 34 | (0.87, 0.88, 0.89) · 0.90 · 25 |
| Titlebar | (0.24, 0.26, 0.26) · 0.81 · 38 | (0.95, 0.96, 0.97) · 0.81 · 38 |
| Fullscreen UI | (0.20, 0.22, 0.22) · 0.54 · 37 | (0.87, 0.89, 0.89) · 0.53 · 35 |

The blur is roughly the same across materials (25–38 pt); what actually distinguishes them is
**alpha and tint**. `sheet` is deliberately absent — measured at alpha 1.0 and blur 0, it does not
let anything through at all.

Liquid Glass (`NSGlassEffectView`, macOS 26). Measured over a white backdrop: `Regular` lets 0.39
through, `Clear` 0.81 — Clear is far more transparent. It also brightens along the border
(measured +0.13 on dark, +0.68 on light over black).

### Edge refraction (Liquid only)

The signature of Liquid Glass is that the border bends the background. This is done by blurring the
shape mask and treating **the gradient of that blurred mask as an inward normal** — it is large only
near the border. The background is sampled along that normal (refraction) and the gradient
magnitude is added as a rim highlight. Because it works off the mask, an arbitrary shape on input 1
refracts exactly like the built-in rounded rectangle.

Note that `CIWarpKernel` cannot sample an image (it only returns coordinates), so refraction and rim
are done together in one general `CIKernel`.

### Parameters

`Style` (Frosted / Liquid Glass) · `Material` (contents follow Style) · `Appearance` (Light / Dark) ·
`Blur Scale` · `Saturation` · `Tint Amount` · `Custom Tint` + `Tint Color` · `Corner Radius` ·
`Inset` · `Edge Refraction` · `Edge Rim` · `Flip Vertically`.

`Saturation` defaults to 1.8 — macOS vibrancy boosts saturation, and this is the one value that was
not solved from the captures, so treat it as taste rather than measurement.

### Measured (M2)

1280x720 input, both styles render with no errors. The Info CHOP reports the resolved
`blur_radius` and `alpha`, which is the quickest way to confirm a preset actually took effect.

### Build

```sh
./build.sh
```

## 日本語

macOS のすりガラス、および macOS 26 の Liquid Glass を画像に適用する。

入力0が背景。入力1は任意のマスク（白い所がガラス）。無ければ `Corner Radius` と `Inset` から
角丸矩形を作る。

### 借りずに作り直している理由

**本物の API はテクスチャにできない。** `NSVisualEffectView` の `.behindWindow` は、
ウインドウサーバーが「画面上でそのウインドウの背後にあるもの」と合成する仕組みで、
`cacheDisplay` でオフスクリーンに描いてもぼけない（実測。背後の市松模様が一切透けず、
のっぺりした半透明の板になる）。`NSGlassEffectView` も同じ。

そのため Core Image で組み直している。プリセットは推測ではなく、**実物を画面に出して
既知のテスト画像に重ね、`screencapture` で取り込んで**合成式から解いた値。

```
黒地での出力 = tint × alpha
白地での出力 = (1 - alpha) + tint × alpha
```

### 実測プリセット

Frosted（`NSVisualEffectView`）。ティント / alpha / ブラー半径（pt）:

| マテリアル | Dark | Light |
|---|---|---|
| HUD Window | (0.20, 0.23, 0.24) · 0.45 · 35 | (0.87, 0.89, 0.89) · 0.53 · 35 |
| Popover | (0.19, 0.21, 0.21) · 0.64 · 35 | (0.87, 0.89, 0.89) · 0.65 · 33 |
| Menu | (0.18, 0.20, 0.20) · 0.73 · 35 | (0.87, 0.88, 0.89) · 0.78 · 32 |
| Sidebar / Under Window | (0.18, 0.20, 0.20) · 0.83 · 34 | (0.87, 0.88, 0.89) · 0.90 · 25 |
| Titlebar | (0.24, 0.26, 0.26) · 0.81 · 38 | (0.95, 0.96, 0.97) · 0.81 · 38 |
| Fullscreen UI | (0.20, 0.22, 0.22) · 0.54 · 37 | (0.87, 0.89, 0.89) · 0.53 · 35 |

ブラーはどのマテリアルでもほぼ同じ（25〜38pt）で、**違いは主に alpha とティント**だった。
`sheet` は意図的に外してある — 実測で alpha 1.0・ブラー 0、つまり**そもそも何も透けない**。

Liquid Glass（`NSGlassEffectView`・macOS 26）。白地での透け具合の実測は
`Regular` 0.39 / `Clear` 0.81 で、Clear の方がはるかに素通し。縁が明るくなることも確認
（黒地の上で dark +0.13 / light +0.68）。

### 縁の屈折（Liquid のみ）

Liquid Glass の特徴は縁で背景が歪むこと。実装は、形のマスクをぼかし、
**そのぼかしたマスクの勾配を内向きの法線として使う**（縁の近くだけ大きくなる）。
その法線方向に背景をサンプルして屈折を作り、勾配の大きさをリムの明るさに足している。
マスク由来なので、**入力1に任意の形を繋いでも内蔵の角丸矩形と同じように屈折する**。

なお `CIWarpKernel` は画像をサンプルできない（座標しか返さない）ため、
屈折とリムは1つの汎用 `CIKernel` にまとめている。

### パラメータ

`Style`（Frosted / Liquid Glass）/ `Material`（中身は Style に連動）/ `Appearance`（Light / Dark）/
`Blur Scale` / `Saturation` / `Tint Amount` / `Custom Tint` + `Tint Color` / `Corner Radius` /
`Inset` / `Edge Refraction` / `Edge Rim` / `Flip Vertically`。

`Saturation` の既定 1.8 は、macOS の vibrancy が彩度を持ち上げることに由来する。
**この値だけはキャプチャから解いていない**ので、実測ではなく好みの値として扱うこと。

### 実測（M2）

1280×720 入力で両スタイルともエラーなく描画。Info CHOP に解決後の `blur_radius` と `alpha` を
出しているので、**プリセットが実際に効いたかはこれを見るのが早い**（非同期なので、
パラメータを変えた直後の値は1手前のものになる）。

### ビルド

```sh
./build.sh
```
