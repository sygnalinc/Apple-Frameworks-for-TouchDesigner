# Metal Upscale TOP

**English** | [日本語](#日本語)

## English

Real-time super resolution. **The macOS answer to the Windows+NVIDIA-only Nvidia Upscaler TOP.**
Two backends, switched with the Backend menu.

### Measured (M2)

| Backend | Time | Output | Use |
|---|---|---|---|
| **MetalFX Spatial** (macOS 13+) | **about 16 ms** (720p 2x) | Any factor 1–4x, BGRA8 | Real time. A game-style upscaler |
| **VT Super Resolution** (macOS 26+) | about 1.9 s (4x, 720p→5120x2880) | **Fixed 4x**, RGBA16F | ML super resolution, take-your-time quality |
| **VT Low Latency ML** (macOS 26+) | **about 21 ms** (640x360→1280x720) | **Fixed 2x, input 96–960 px** | **Real-time ML super resolution.** For low-resolution sources (webcams, old material) |

### Parameters

| Name | Description |
|---|---|
| Active | Processing On/Off |
| Backend | MetalFX Spatial / VT Super Resolution / VT Low Latency ML |
| Scale Factor | Output factor 1–4 (MetalFX only; VT is fixed at 4x) |
| Download Model | Fetch the ML model for VT (pulse). **Only needed the first time.** Progress appears in the warning text and in `model_status` |

There is no Flip parameter (upscaling does not depend on orientation, so the input is processed
and returned in whatever orientation it arrives).

### Info CHOP

`executes / submits / analyzes / process_ms / model_status`
(model_status: -1 = unused, 0 = download needed, 1 = downloading, 2 = ready)

### Notes

- Under **TouchDesigner Non-Commercial** the resolution is capped at 1280x1280. Output above the
  cap is **scaled down automatically** with a warning (without it TD renders garbage). Use a
  commercial license if you need full resolution.

- **Which VT scale factors are available depends on the hardware.** The first entry of
  `supportedScaleFactors` is used (on M2 that is 4x only)
- VT's input limit is 1080 lines for the Video type (anything larger shows a configuration error)
- VT's ML model comes from Apple's asset delivery (if the OS already has it no pulse is needed —
  if `model_status=2` it just works)
- MetalFX Spatial is spatial upscaling and needs no motion vectors. The Temporal version needs
  motion vectors plus depth, so it is not supported (can be added on request)
- **VT Low Latency only supports the 420v (YCbCr) pixel format** — unlike the 64RGBAHalf of the
  other VT paths (measured). BGRA↔420v conversion is done internally with vImage. Input must be
  96–960 px and the factor is fixed at 2x; out-of-range input shows an error
- **Running it alongside ANE plugins (CoreML DAT etc.) makes it far slower** through ANE
  contention (LLSR measured: 4 ms alone → 324 ms with YOLO running)

### Build

```
cd MetalUpscale && ./build.sh   # → build/MetalUpscaleTOP.plugin
```

## 日本語

リアルタイム超解像。**Windows+NVIDIA 専用の Nvidia Upscaler TOP の macOS 代替**。
バックエンド2種を Backend メニューで切替。

### 実測(M2)

| Backend | 処理時間 | 出力 | 用途 |
|---|---|---|---|
| **MetalFX Spatial**(macOS 13+) | **約16ms**(720p 2x) | 任意倍率 1〜4x・BGRA8 | リアルタイム。ゲーム系アップスケーラ |
| **VT Super Resolution**(macOS 26+) | 約1.9秒(4x・720p→5120x2880) | **倍率は固定 4x**・RGBA16F | ML超解像・じっくり系(高品質) |
| **VT Low Latency ML**(macOS 26+) | **約21ms**(640x360→1280x720) | **2x固定・入力96〜960px** | **リアルタイムML超解像**。低解像度ソース(ウェブカメラ・古い素材)向け |

### パラメータ

| 名前 | 内容 |
|---|---|
| Active | 処理の実行 On/Off |
| Backend | MetalFX Spatial / VT Super Resolution / VT Low Latency ML |
| Scale Factor | 出力倍率 1〜4(MetalFX 時のみ。VT は固定 4x) |
| Download Model | VT 用 ML モデルの取得(パルス)。**初回のみ必要**。進捗は警告文と `model_status` に出る |

Flip パラメータは無い(拡大処理は向きに依存しないため、入力をそのままの向きで処理して返す)。

### Info CHOP

`executes / submits / analyzes / process_ms / model_status`
(model_status: -1=未使用 0=要ダウンロード 1=ダウンロード中 2=準備完了)

### 注意

- **TouchDesigner Non-Commercial** では解像度が 1280x1280 に制限される。上限を超える出力は**自動で上限内へ縮小**し、その旨を警告に出す(縮小しないと TD 側で絵が崩れるため)。フル解像度が要るなら商用ライセンスを使う

- **VT の対応倍率はハードウェア依存**。`supportedScaleFactors` の先頭を使う(M2 実測 4x のみ)
- VT の入力上限は Video タイプで縦1080(それ以上は設定エラーを表示)
- VT の ML モデルは Apple のアセット配信から取得(OS が既に持っている場合はパルス不要。
  `model_status=2` ならそのまま動く)
- MetalFX Spatial は動きベクトル不要の空間アップスケール。時間方向の
  Temporal 版はモーションベクトル+深度が必要なため未対応(要望があれば拡張)
- **VT Low Latency の対応ピクセル形式は 420v(YCbCr)のみ**(他のVT系の64RGBAHalfと
  異なる・実測)。内部で vImage により BGRA↔420v 変換している。入力は 96〜960px、
  倍率2x固定。範囲外の入力はエラー表示
- **ANE系プラグイン(CoreML DAT等)と同時実行するとANE競合で大幅に遅くなる**
  (LLSR実測: 単独4ms→YOLO併走時324ms)

### ビルド

```
cd MetalUpscale && ./build.sh   # → build/MetalUpscaleTOP.plugin
```
