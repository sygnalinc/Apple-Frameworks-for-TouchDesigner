# Upscale TOP

リアルタイム超解像。**Windows+NVIDIA 専用の Nvidia Upscaler TOP の macOS 代替**。
バックエンド2種を Backend メニューで切替。

## 実測(M2・1280x720入力)

| Backend | 処理時間 | 出力 | 用途 |
|---|---|---|---|
| **MetalFX Spatial**(macOS 13+) | **約16ms**(2x) | 任意倍率 1〜4x・BGRA8 | リアルタイム。ゲーム系アップスケーラ |
| **VT Super Resolution**(macOS 26+) | 約1.9秒(4x・720p→5120x2880) | **倍率は固定 4x**・RGBA16F | ML超解像・じっくり系(高品質) |

## パラメータ

| 名前 | 内容 |
|---|---|
| Active | 処理の実行 On/Off |
| Backend | MetalFX Spatial / VT Super Resolution |
| Scale Factor | 出力倍率 1〜4(MetalFX 時のみ。VT は固定 4x) |
| Download Model | VT 用 ML モデルの取得(パルス)。**初回のみ必要**。進捗は警告文と `model_status` に出る |
| Flip Image Vertically | 実質**出力の上下反転スイッチ**(**既定Off=ソースと同じ正立**・Onで上下逆になる)。拡大処理自体は向きに依存しないため通常は触らない。上流が top-down で入ってくる素材(GL系レンダーターゲット等)の二重反転打ち消し用 |

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

## ビルド

```
cd Upscale && ./build.sh   # → build/UpscaleTOP.plugin
```
