# Metal Upscale TOP

リアルタイム超解像。**Windows+NVIDIA 専用の Nvidia Upscaler TOP の macOS 代替**。
バックエンド2種を Backend メニューで切替。

## 実測(M2)

| Backend | 処理時間 | 出力 | 用途 |
|---|---|---|---|
| **MetalFX Spatial**(macOS 13+) | **約16ms**(720p 2x) | 任意倍率 1〜4x・BGRA8 | リアルタイム。ゲーム系アップスケーラ |
| **VT Super Resolution**(macOS 26+) | 約1.9秒(4x・720p→5120x2880) | **倍率は固定 4x**・RGBA16F | ML超解像・じっくり系(高品質) |
| **VT Low Latency ML**(macOS 26+) | **約21ms**(640x360→1280x720) | **2x固定・入力96〜960px** | **リアルタイムML超解像**。低解像度ソース(ウェブカメラ・古い素材)向け |

## パラメータ

| 名前 | 内容 |
|---|---|
| Active | 処理の実行 On/Off |
| Backend | MetalFX Spatial / VT Super Resolution / VT Low Latency ML |
| Scale Factor | 出力倍率 1〜4(MetalFX 時のみ。VT は固定 4x) |
| Download Model | VT 用 ML モデルの取得(パルス)。**初回のみ必要**。進捗は警告文と `model_status` に出る |

Flip パラメータは無い(拡大処理は向きに依存しないため、入力をそのままの向きで処理して返す)。

## Info CHOP

`executes / submits / analyzes / process_ms / model_status`
(model_status: -1=未使用 0=要ダウンロード 1=ダウンロード中 2=準備完了)

## 注意

- **VT の対応倍率はハードウェア依存**。`supportedScaleFactors` の先頭を使う(M2 実測 4x のみ)
- VT の入力上限は Video タイプで縦1080(それ以上は設定エラーを表示)
- VT の ML モデルは Apple のアセット配信から取得(OS が既に持っている場合はパルス不要。
  `model_status=2` ならそのまま動く)
- MetalFX Spatial は動きベクトル不要の空間アップスケール。時間方向の
  Temporal 版はモーションベクトル+深度が必要なため未対応(要望があれば拡張)
- **VT Low Latency の対応ピクセル形式は 420v(YCbCr)のみ**(他のVT系の64RGBAHalfと
  異なる・実測)。内部で vImage により BGRA↔420v 変換している。入力は 96〜960px、
  倍率2x固定。範囲外の入力はエラー表示
- **ANE系プラグイン(CoreMLDetect等)と同時実行するとANE競合で大幅に遅くなる**
  (LLSR実測: 単独4ms→YOLO併走時324ms)

## ビルド

```
cd MetalUpscale && ./build.sh   # → build/MetalUpscaleTOP.plugin
```
