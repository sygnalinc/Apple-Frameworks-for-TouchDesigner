# VisionFlow TOP

入力 TOP の連続フレームから**オプティカルフロー(動きベクトル場)**を生成する。
**Windows+NVIDIA 専用の Optical Flow TOP の macOS 代替**。
`VNGenerateOpticalFlowRequest`。

## 実測(M2・1280x720・Accuracy=Medium)

- 解析 約64ms → **約15fps**。非同期実行で TD 本体は 60fps を維持
- 出力は入力と同解像度の RG32Float

## 出力仕様

RG32Float の2チャンネルテクスチャ。R=dx, G=dy(前フレーム→現フレームの移動量)。

| Units | 値 |
|---|---|
| UV (既定) | 解像度で正規化。**+v は画面上向き**(TD の uv 系に整合。Vision の y 下向きから符号反転済み) |
| Pixels | Vision の生値(画素単位・+y は画面下向き) |

例: 60fps で画面幅の 22%/秒 の動き → UV 単位で dx ≈ 0.0037/frame(実測一致を確認済み)。

## パラメータ

| 名前 | 内容 |
|---|---|
| Active | 解析の実行 On/Off |
| Accuracy | Low / Medium(既定)/ High / Very High。高精度ほど遅い |
| Output Units | UV / Pixels(上記) |
| Flip Image Vertically | 入力の上下反転(既定On・必須) |

## Info CHOP

`executes / submits / analyzes / analyze_ms`。

## 注意

- 最初の1フレームは前フレームが無いので出力されない
- 解像度が変わると前フレームを破棄して仕切り直す
- 可視化するには Math TOP で 0.5 オフセットする(負値は表示上黒く潰れる)、
  もしくは TOP to CHOP で数値として使う

## ビルド

```
cd VisionFlow && ./build.sh   # → build/VisionFlowTOP.plugin
```
