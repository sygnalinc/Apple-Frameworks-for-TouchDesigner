# Vision Flow TOP

**English** | [日本語](#日本語)

## English

Produces an **optical flow (motion vector field)** from consecutive frames of the input TOP.
**The macOS answer to the Windows+NVIDIA-only Optical Flow TOP.** Uses
`VNGenerateOpticalFlowRequest`.

### Measured (M2, 1280x720, Accuracy = Medium)

- Analysis about 64 ms → **roughly 15 fps**. It runs asynchronously so TD itself stays at 60 fps
- The output is RG32Float at the input's resolution

### Output

A two-channel RG32Float texture. R = dx, G = dy (movement from the previous frame to this one).

| Units | Value |
|---|---|
| UV (default) | Normalised by resolution. **+v is up on screen** (consistent with TD's uv; the sign is flipped from Vision's downward y) |
| Pixels | Vision's raw values (in pixels; +y is down on screen) |

Example: at 60 fps, motion of 22% of the frame width per second → dx ≈ 0.0037/frame in UV units
(confirmed to match).

### Parameters

| Name | Description |
|---|---|
| Active | Analysis On/Off |
| Accuracy | Low / Medium (default) / High / Very High. Higher is slower |
| **Output** | **Visualize (RGBA8, colour visualisation, default) / Flow Vectors (RG32Float, for downstream use)** |
| Output Units | UV / Pixels (only meaningful in Flow mode) |
| Flip Image Vertically | Flip the input (default On, required) |

### Info CHOP

`executes / submits / analyzes / analyze_ms`

### When the picture looks black (important)

**The easy answer: set `Output` to `Visualize (Color)`.** Motion is shown directly as colour
(hue = direction, brightness = speed) with no amplification node. Switch to `Flow` only when you
need the raw vectors downstream.

The raw optical flow output (`Flow`) is a motion vector field, so **looking almost black is
normal**. Nvidia's Optical Flow TOP behaves the same way. Check the following:

1. **Is the input actually moving?** A still image or a paused movie gives flow = 0, i.e. pure
   black. Worse, **a still image only arrives once**, so flow is never computed at all (black
   forever). Play a Movie File In, use a camera, or feed moving material
2. **UV mode (the default) normalises by resolution, so the values are tiny** (even motion of 22%
   of the frame width per second is dx ≈ 0.004/frame). **That is black to the eye.** To see it:
   - Amplify ×20–50 with a **Math TOP** (Multiply), or lift it with a **Level TOP**
   - To see negatives too, **×N then +0.5 offset** in a Math TOP (R/G become visible around 0.5)
   - Setting Output Units to **Pixels** makes the numbers larger (moving areas look blown out)
3. To use it as data, turn it into numbers with a **TOP to CHOP** (no display needed)

> Verification: running `VNGenerateOpticalFlowRequest` on a synthetic input where an object moves
> +30 px between two frames measured **a maximum flow of ≈ 23 px with a negative dx in the moving
> region** (both detection and direction correct). The plugin is fine; a black picture means
> either a static input or small, unamplified values as above.

### Notes

- The very first frame produces no output (there is no previous frame)
- A resolution change discards the previous frame and starts over

### Build

```
cd VisionFlow && ./build.sh   # → build/VisionFlowTOP.plugin
```

## 日本語

入力 TOP の連続フレームから**オプティカルフロー(動きベクトル場)**を生成する。
**Windows+NVIDIA 専用の Optical Flow TOP の macOS 代替**。
`VNGenerateOpticalFlowRequest`。

### 実測(M2・1280x720・Accuracy=Medium)

- 解析 約64ms → **約15fps**。非同期実行で TD 本体は 60fps を維持
- 出力は入力と同解像度の RG32Float

### 出力仕様

RG32Float の2チャンネルテクスチャ。R=dx, G=dy(前フレーム→現フレームの移動量)。

| Units | 値 |
|---|---|
| UV (既定) | 解像度で正規化。**+v は画面上向き**(TD の uv 系に整合。Vision の y 下向きから符号反転済み) |
| Pixels | Vision の生値(画素単位・+y は画面下向き) |

例: 60fps で画面幅の 22%/秒 の動き → UV 単位で dx ≈ 0.0037/frame(実測一致を確認済み)。

### パラメータ

| 名前 | 内容 |
|---|---|
| Active | 解析の実行 On/Off |
| Accuracy | Low / Medium(既定)/ High / Very High。高精度ほど遅い |
| **Output** | **Visualize(RGBA8・色で可視化・既定) / Flow Vectors(RG32Float・下流で使う用)** |
| Output Units | UV / Pixels(Flow時のみ意味を持つ) |
| Flip Image Vertically | 入力の上下反転(既定On・必須) |

### Info CHOP

`executes / submits / analyzes / analyze_ms`。

### 黒い画面に見えるとき（重要）

**一番かんたん: `Output` を `Visualize (Color)` にする。** 動きが色（向き=色相・速さ=明るさ）で
そのまま見える（増幅ノード不要）。生ベクトルが要るとき（下流でフロー値を使う）だけ `Flow` にする。

オプティカルフローの生出力（`Flow`）は「動きベクトル場」なので、**そのままだとほぼ黒く見えるのが
正常**。Nvidia の Optical Flow TOP も同じ。以下を確認する:

1. **入力が動いている映像か**。静止画・止まった映像だとフローは 0 = 真っ黒。
   さらに**静止画は1フレームしか来ない**ので、フロー自体が一度も計算されない
   （＝ずっと黒）。Movie File In を再生する / カメラ / 動く素材を入れる
2. **UV モード（既定）は解像度で正規化するので値がとても小さい**（例: 画面幅22%/秒の
   動きでも dx ≈ 0.004/frame）。**そのままでは肉眼で黒**。可視化するには:
   - **Math TOP**（Multiply）で ×20〜50 して増幅、または **Level TOP** で持ち上げる
   - 負値も見たいなら Math TOP で **×N した後に +0.5 オフセット**（R/G が 0.5 中心で見える）
   - Output Units を **Pixels** にすると値が大きくなる（動いた所が白飛び気味に見える）
3. データとして使うなら **TOP to CHOP** で数値化する（表示は不要）

> 検証: 2フレーム間で物体を +30px 動かした合成入力で `VNGenerateOpticalFlowRequest` を実行し、
> **最大フロー ≈ 23px・動いた領域で dx が負**（動き検出・方向とも正しい）を実測確認済み。
> プラグインは正常。黒く見えるのは上記の「入力が静止」か「値が小さく未増幅」が原因。

### 注意

- 最初の1フレームは前フレームが無いので出力されない
- 解像度が変わると前フレームを破棄して仕切り直す

### ビルド

```
cd VisionFlow && ./build.sh   # → build/VisionFlowTOP.plugin
```
