# FrameInterp TOP

Apple の動画ML処理 **VTFrameProcessor**(VideoToolbox・macOS 15.4+)による
フレーム補間とモーションブラー。

## 実測(M2・1280x720)

- 処理 約67ms → **約15fps**。非同期実行で TD 本体は 60fps を維持
- 入出力とも 64RGBAHalf(TD の RGBA16Float と同一レイアウト)で変換コストゼロ

## モード

| Mode | 内容 |
|---|---|
| Interpolate | 前フレームと現フレームの**中間フレームを ML 補間で生成**。Phase(0〜1)で補間位置を指定。0.5 で中間。フレームレート変換/スローモーションの要素技術(Cache TOP と組み合わせて任意フレーム間の補間にも) |
| Motion Blur | 前フレームからの動きに基づく ML モーションブラー。Strength 1〜100 |

## パラメータ

| 名前 | 内容 |
|---|---|
| Active | 処理の実行 On/Off |
| Mode | Interpolate / Motion Blur |
| Interpolation Phase | 補間位置 0〜1(Interpolate 時) |
| Blur Strength | ブラー強度 1〜100(Motion Blur 時) |

Flip パラメータは無い(補間/ブラーは向きに依存しないため、入力をそのままの向きで処理して返す)。

## Info CHOP

`executes / submits / analyzes / process_ms`。

## 注意

- **macOS 15.4+ 必須**(未満はエラー表示)
- 出力は常に1フレーム分。リアルタイム再生中は「1フレーム前と現在の中間」が出る
  (=約半フレーム遅れの映像)。真のスローモーション生成は入力を止めながら
  Phase をスイープする使い方で
- VTFrameProcessor の対応ピクセル形式は **64RGBAHalf のみ**(実測)。
  TD 側 RGBA16Float ダウンロードと直結している
- 解像度・モード変更時はセッションを作り直すため1フレーム分結果が飛ぶ

## ビルド

```
cd FrameInterp && ./build.sh   # → build/FrameInterpTOP.plugin
```
