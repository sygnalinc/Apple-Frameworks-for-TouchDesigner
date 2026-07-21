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
| **Output** | **Visualize(RGBA8・色で可視化・既定) / Flow Vectors(RG32Float・下流で使う用)** |
| Output Units | UV / Pixels(Flow時のみ意味を持つ) |
| Flip Image Vertically | 入力の上下反転(既定On・必須) |

## Info CHOP

`executes / submits / analyzes / analyze_ms`。

## 黒い画面に見えるとき（重要）

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

## 注意

- 最初の1フレームは前フレームが無いので出力されない
- 解像度が変わると前フレームを破棄して仕切り直す

## ビルド

```
cd VisionFlow && ./build.sh   # → build/VisionFlowTOP.plugin
```
