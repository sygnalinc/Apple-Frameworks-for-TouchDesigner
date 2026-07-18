# Vision Contours SOP

入力TOPのエッジ輪郭をApple Visionの`VNDetectContoursRequest`で抽出し、閉じたLine
primitiveとして出力するSOP。輪郭をSweep、Extrude、Particle、レーザー描画などの
TouchDesignerジオメトリ処理へ直接渡せる。macOS 11以降。

## 出力仕様

- 座標: `P.x/P.y` = 0〜1、左下原点。`P.z=0`
- 各輪郭は始点を末尾に複製した閉じたLine primitive
- Pointカスタム属性:

| 属性 | 内容 |
|---|---|
| `contourid` | 検出結果内の輪郭番号 |
| `parentid` | 包含する親輪郭の番号。親なしは-1 |
| `depth` | 輪郭階層の深さ。トップレベルは0 |
| `closed` | 常に1 |

## パラメータ

| 名前 | 内容 |
|---|---|
| TOP | 入力TOP |
| Active | 解析On/Off |
| Max Contours | 出力上限。内部上限100、スライダー表示10 |
| Minimum Points | これ未満の点数の輪郭を除外 |
| Maximum Points per Contour | 輪郭ごとの点数上限。超過時は均等間引き |
| Maximum Image Dimension | Vision内部の解析最大辺。既定512、最小64 |
| Contrast Adjustment | 解析前のコントラスト。既定2.0 |
| Simplify Epsilon | Ramer–Douglas–Peucker簡略化。0で無効 |
| Detect Dark on Light | 暗い物体/明るい背景向け最適化 |
| Flip Image Vertically | 既定On。TDのTOP入力には必須 |

## Info CHOP

`executes / submits / analyzes / analyze_ms / detected / contours / points`。
`detected`はVisionの全検出数、`contours`はフィルタ後の出力数。

## 注意

- 推論はワーカースレッドで非同期。cookをブロックせず、結果は1〜2フレーム遅れる
- 出力点数は入力内容で変動する。Maximum Image Dimension、Simplify、Maximum Pointsで調整する
- 静止画でも処理パラメータ変更時は自動的に再解析する

## ビルド

```sh
cd VisionContours && ./build.sh
```
