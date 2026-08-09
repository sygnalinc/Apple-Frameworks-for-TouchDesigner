# Metal Denoise TOP

**English** | [日本語](#日本語)

## English

Removes temporal noise from video with Apple's **ML temporal noise filter**
(VTTemporalNoiseFilter, macOS 26+) — for example reducing grain from a camera in a dark room.

### ⚠ Limited hardware support

**On M2 it measures `isSupported=false` (maximumDimensions = 0x0) and does not run.** In that
case the node **passes the input through unchanged and raises a warning** —
"Temporal noise filter not supported on this hardware — passing the input through unchanged".
It is deliberately a warning rather than an error, so that opening a network on an unsupported
machine does not break everything downstream. The implementation should work as-is on supported
hardware (presumably newer Apple Silicon), but **it has not been verified on real data with the
M2 used for this repository**.

The same applies below macOS 26: a warning plus passthrough, never an error.

### Parameters

| Name | Description |
|---|---|
| Active | Processing On/Off |
| Filter Strength | Denoising strength 0–1 (default 0.5) |

There is no Flip parameter (denoising does not depend on orientation, so the input is processed
and returned in whatever orientation it arrives).

### Info CHOP

`executes / submits / analyzes / process_ms`

### Implementation notes

- Input and output are 64RGBAHalf (a direct match for TD's RGBA16Float). The config's
  `previousFrameCount` previous frames are retained and passed along (the first call sets
  hasDiscontinuity = true)
- The same VTFrameProcessor pipeline (session, CVPixelBufferPool) as Metal FrameInterp

### Build

```
cd MetalDenoise && ./build.sh   # → build/MetalDenoiseTOP.plugin
```

## 日本語

Apple の **ML テンポラルノイズフィルタ**(VTTemporalNoiseFilter・macOS 26+)で
映像の時間方向ノイズを除去する。暗所カメラのざらつき低減など。

### ⚠ 対応ハードウェアが限られる

**M2 実測では `isSupported=false`(maximumDimensions=0x0)で動作しない**。
その場合ノードは**入力をそのまま素通しして警告**を出す
("Temporal noise filter not supported on this hardware — passing the input through unchanged")。
非対応マシンで開いただけのネットワークが下流ごと壊れないよう、**エラーではなく警告**にしてある。
対応環境(より新しい世代のApple Siliconと推定)ではそのまま動く実装になっているが、
**本リポジトリのM2では実データ検証未実施**。

macOS 26 未満でも同じく警告 + 素通しで、エラーにはしない。

### パラメータ

| 名前 | 内容 |
|---|---|
| Active | 処理 On/Off |
| Filter Strength | ノイズ除去強度 0〜1(既定0.5) |

Flip パラメータは無い(ノイズ除去は向きに依存しないため、入力をそのままの向きで処理して返す)。

### Info CHOP

`executes / submits / analyzes / process_ms`

### 実装メモ

- 入出力 64RGBAHalf(TD の RGBA16Float 直結)。config の
  `previousFrameCount` ぶん前フレームを保持して渡す(初回は hasDiscontinuity=true)
- Metal FrameInterp と同じ VTFrameProcessor パイプライン(セッション・CVPixelBufferPool)

### ビルド

```
cd MetalDenoise && ./build.sh   # → build/MetalDenoiseTOP.plugin
```
