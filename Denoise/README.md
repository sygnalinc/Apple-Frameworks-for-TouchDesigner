# Denoise TOP

Apple の **ML テンポラルノイズフィルタ**(VTTemporalNoiseFilter・macOS 26+)で
映像の時間方向ノイズを除去する。暗所カメラのざらつき低減など。

## ⚠ 対応ハードウェアが限られる

**M2 実測では `isSupported=false`(maximumDimensions=0x0)で動作しない**。
その場合ノードは "Temporal noise filter not supported on this hardware" のエラー表示になる
(クラッシュはしない)。対応環境(より新しい世代のApple Siliconと推定)では
そのまま動く実装になっているが、**本リポジトリのM2では実データ検証未実施**。

## パラメータ

| 名前 | 内容 |
|---|---|
| Active | 処理 On/Off |
| Filter Strength | ノイズ除去強度 0〜1(既定0.5) |

Flip パラメータは無い(ノイズ除去は向きに依存しないため、入力をそのままの向きで処理して返す)。

## Info CHOP

`executes / submits / analyzes / process_ms`

## 実装メモ

- 入出力 64RGBAHalf(TD の RGBA16Float 直結)。config の
  `previousFrameCount` ぶん前フレームを保持して渡す(初回は hasDiscontinuity=true)
- FrameInterp と同じ VTFrameProcessor パイプライン(セッション・CVPixelBufferPool)

## ビルド

```
cd Denoise && ./build.sh   # → build/DenoiseTOP.plugin
```
