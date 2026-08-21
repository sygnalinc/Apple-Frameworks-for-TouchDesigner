# Vision Rect CHOP

**English** | [日本語](#日本語)

## English

Detects multiple projected rectangles in an image with Apple Vision — paper, cards, screens,
signage — for corner pinning, perspective correction and region selection. macOS 10.14 or later.

Each `rect{i}` outputs 14 channels:
`valid / confidence / bbox:u,v,w,h / tl:u,v / tr:u,v / br:u,v / bl:u,v`.
Coordinates are 0–1 with a bottom-left origin, and multiple rectangles are ordered by centre u,
left to right.

| Parameter | Description |
|---|---|
| TOP | Input TOP |
| Active | Detection On/Off |
| Max Rectangles | Up to 100, default 10 |
| Minimum/Maximum Aspect Ratio | Range of short side ÷ long side (0–1) |
| Minimum Size | Minimum edge as a fraction of the image's short side |
| Minimum Confidence | Minimum confidence |
| Quadrature Tolerance | Angle tolerated away from a right angle (0–45 degrees) |
| Flip Image Vertically | Default On |

Info CHOP: `executes/submits/analyzes/analyze_ms/rects`. Inference is asynchronous, and even a
still image is re-analysed when a processing parameter changes.

### Aspect Correct UVs

`Aspect Correct UVs` (default **Off**) rescales uv so that one uv unit is the same pixel distance
horizontally and vertically. Same role and same default as the parameter of the same name on TD's
built-in **Body Track CHOP**.

```
aspect = input width / input height
u' = u                             (stays 0..1)
v' = 0.5 + (v - 0.5) / aspect      (shrunk to 1/aspect about the centre)
the bbox height (a v distance) is also 1/aspect; the width is unchanged
```

Because `u` stays in 0..1, instancing with `tx = u - 0.5` / `ty = v - 0.5` lands exactly on the
source video **with the camera's Ortho Width left at 1** (no manual scaling). Leave it Off when
you want raw 0..1 image coordinates.

### Corner pinning an image onto a detected rectangle

Use `tl/tr/br/bl` to warp another image onto the detected rectangle with a projective transform.
See `/project1/VisionRect` in `demo.toe` (a video is played onto two laptop screens).

The chain is `source video → Vision Rect → Shuffle (Sequence All Channels) → GLSL TOP`, where the
GLSL TOP's input 0 is the source video and input 1 is the image to paste.

| Watch out for | Details |
|---|---|
| Aspect Correct UVs | **Off.** A warp in TOP space needs raw 0–1 image coordinates (with it On, v shrinks and the paste is displaced) |
| Passing the CHOP | Use a Shuffle CHOP's `Sequence All Channels` to turn `Nch×1sample` into `1ch×Nsample` before feeding the GLSL Array (texture buffer). Connecting the CHOP directly makes **texel count = sample count**, so only one texel arrives |
| Rectangle count | Deriving it in the shader as `textureSize(uRects) / 14` keeps it working when Max Rectangles changes |
| Latency | Detection is asynchronous, so with fast camera movement the paste lags by 1–2 frames |
| False positives | If the keyboard surface and the like get picked up, lower `Maximum Aspect Ratio` (0.8 in the example) |

The paste is done by inverse mapping: build the projective transform `M` from the unit square to
the four corners, apply `inverse(M)` to each output pixel to find `st` in the pasted image, and
composite only where `st` is inside 0–1.

### Rectifying a detected rectangle (perspective correction)

The inverse of corner pinning — cut the detected quad out and straighten it to face the camera.
**TouchDesigner's stock Corner Pin TOP does this** on its Extract page:

1. Wire the source into a Corner Pin TOP and set **Mapping = Perspective** (the default bilinear
   distorts a trapezoid)
2. Set the four Extract corners (unit `fraction`) by expression:
   `op('visionrect1')['rect1/tl:u']` and so on — tl/tr/bl/br × u/v, eight expressions
3. Keep this operator's `Aspect Correct UVs` **off** — Extract wants raw 0–1 image coordinates
4. Output resolution is the Common page (defaults to the input's; larger than the cut means upscaling)

This repo's CI Keystone TOP (experimental) does the same thing; it auto-sizes its output to the
rectangle's real pixel size, at the cost of a CPU round trip (an extra frame or two of latency).
Either way the detection itself is asynchronous, so with a moving camera the corners trail by a
frame or two. The demo's `rectify` branch in `/project1/VisionRect` shows the Corner Pin wiring.

### Build

```sh
cd VisionRect && ./build.sh
```

## 日本語

Apple Visionで映像内の投影矩形を複数検出するCHOP。紙、カード、画面、看板などの
コーナーピン、射影補正、領域選択に使える。macOS 10.14以降。

各`rect{i}`に`valid / confidence / bbox:u,v,w,h / tl:u,v / tr:u,v / br:u,v / bl:u,v`
の14チャンネルを出力する。座標は0〜1・左下原点、複数矩形は中心uの左→右順。

| パラメータ | 内容 |
|---|---|
| TOP | 入力TOP |
| Active | 検出On/Off |
| Max Rectangles | 最大100、既定10 |
| Minimum/Maximum Aspect Ratio | 短辺÷長辺の範囲（0〜1） |
| Minimum Size | 画像短辺に対する最小辺比率 |
| Minimum Confidence | 最低信頼度 |
| Quadrature Tolerance | 直角から許容する角度（0〜45度） |
| Flip Image Vertically | 既定On |

Info CHOPは`executes/submits/analyzes/analyze_ms/rects`。推論は非同期で、静止画も
処理パラメータ変更時に再解析する。

### Aspect Correct UVs（アスペクト比補正）

`Aspect Correct UVs`（既定 **Off**）は uv の1単位が縦横で同じピクセル距離になるよう再スケールする。
TD標準 **Body Track CHOP** の同名パラメータと同じ役割・同じ既定値。

```
aspect = 入力幅 / 入力高さ
u' = u                             （0〜1 のまま）
v' = 0.5 + (v - 0.5) / aspect      （中心を保って 1/aspect に縮小）
bbox の height（v方向の距離）も 1/aspect、width は不変
```

`u` が 0〜1 のままなので、`tx = u - 0.5` / `ty = v - 0.5` でインスタンシングすると
**カメラの Ortho Width を 1 のまま**で元映像にぴったり重なる（手動スケール不要）。
生の 0〜1 画像座標が欲しいときは Off のままにする。

### 四隅に画像を貼り込む（corner pin）

`tl/tr/br/bl` を使って、検出した矩形へ別の映像を射影変換で貼り込める。
実例は `demo.toe` の `/project1/VisionRect`（ノートPCの画面2枚に映像を流し込む）。

構成は `元映像 → Vision Rect → Shuffle(Sequence All Channels) → GLSL TOP` で、
GLSL TOP の入力0が元映像、入力1が貼り込む画像。

| 注意 | 内容 |
|---|---|
| Aspect Correct UVs | **Off**。TOP空間のワープには生の 0〜1 画像座標が要る（Onだと v が縮んで位置がずれる） |
| CHOP の渡し方 | Shuffle CHOP の `Sequence All Channels` で `Nch×1sample` → `1ch×Nsample` にしてから GLSL の Array（texture buffer）へ。CHOPを直接繋ぐと **texel数=サンプル数**になり1 texel しか渡らない |
| 矩形数 | シェーダ側で `textureSize(uRects) / 14` から求めれば Max Rectangles を変えても壊れない |
| 遅れ | 検出は非同期なので、カメラが速く動くと貼り込みが1〜2フレーム遅れる |
| 誤検出 | キーボード面などが拾われるときは `Maximum Aspect Ratio` を下げる（実例では 0.8） |

貼り込みは逆変換で行う。単位正方形 → 四隅 の射影変換 `M` を作り、出力画素 `uv` に
`inverse(M)` を掛けて貼り込む画像側の `st` を求め、`0〜1` の内側だけ合成する。

### 検出した矩形を正対化する(透視補正)

貼り込みの逆 — 検出した四角形を切り出して正面向きに起こす。
**TouchDesigner 標準の Corner Pin TOP の Extract ページでできる**:

1. 元映像を Corner Pin TOP に繋ぎ、**Mapping = Perspective** にする(既定の bilinear は台形が歪む)
2. Extract の四隅(単位 `fraction`)へ式で四隅を入れる:
   `op('visionrect1')['rect1/tl:u']` など — tl/tr/bl/br × u/v の8本
3. この op の `Aspect Correct UVs` は **Off のまま**(Extract は生の 0〜1 画像座標を受ける)
4. 出力解像度は Common ページ(既定=入力と同じ。切り出しの実寸より大きいと拡大になる)

このリポジトリの CI Keystone TOP(experimental)も同じことをする。あちらは出力解像度が矩形の
実寸に自動で合う代わりに、CPU 経由のぶん1〜2フレーム余計に遅れる。どちらでも検出自体は
非同期なので、カメラが動く素材では四隅が1〜2フレーム遅れて追う。
demo.toe の `/project1/VisionRect` の `rectify` ブランチが Corner Pin の配線例。

### ビルド

```sh
cd VisionRect && ./build.sh
```
