# Vision Contours SOP

**English** | [日本語](#日本語)

## English

Extracts the edge contours of an input TOP with Apple Vision's `VNDetectContoursRequest` and
outputs them as closed Line primitives. The contours feed straight into TouchDesigner geometry
work — Sweep, Extrude, particles, laser output. macOS 11 or later.

### Output

- Coordinates: `P.x/P.y` = 0–1, bottom-left origin. `P.z = 0`
- Each contour is a closed Line primitive whose first point is duplicated at the end
- Point custom attributes:

| Attribute | Description |
|---|---|
| `contourid` | Contour number within the detection |
| `parentid` | Number of the enclosing parent contour; -1 if there is none |
| `depth` | Depth in the contour hierarchy; 0 at the top level |
| `closed` | Always 1 |

### Parameters

| Name | Description |
|---|---|
| TOP | Input TOP |
| Active | Analysis On/Off |
| Max Contours | Output limit. Internal limit 100, slider shows 10 |
| Minimum Points | Discard contours with fewer points than this |
| Maximum Points per Contour | Point cap per contour; excess is decimated evenly |
| Maximum Image Dimension | Vision's internal analysis size (longest side). Default 512, minimum 64 |
| Contrast Adjustment | Contrast before analysis. Default 2.0 |
| Simplify Epsilon | Ramer–Douglas–Peucker simplification. 0 disables it |
| Detect Dark on Light | Optimise for dark objects on a light background |
| Flip Image Vertically | Default On. Required for TD TOP input |
| Aspect Correct UVs | Default Off. Matches the points' vertical extent to the input aspect ratio (below) |

#### Aspect Correct UVs

The points are Vision's 0–1 (bottom-left origin), so **by default they fill a 0–1 square**. With
16:9 footage the contour stretches vertically and spills outside the silhouette when overlaid.

Turning `Aspect Correct UVs` on shrinks only the vertical axis to 1/aspect (horizontal stays 0–1):

```
aspect = input width / input height
P.x' = P.x                              (stays 0..1)
P.y' = 0.5 + (P.y - 0.5) / aspect       (shrunk about the centre)
```

Offset the Geometry COMP by -0.5 and shoot it with a camera at **Ortho Width = 1** and it lands
exactly on the source video. Measured at 1280x720: `P.y` spans `0.2188..0.7812`
(= 0.5 ± 0.5/1.7778). Same role and same default as TD's built-in Body Track CHOP parameter of the
same name, and consistent with the other Vision operators.

Leave it Off when you want the raw 0–1 coordinates (feeding a Sweep or Extrude and scaling
yourself, for instance).

### Info CHOP

`executes / submits / analyzes / analyze_ms / detected / contours / points`.
`detected` is Vision's total detections; `contours` is how many survive filtering.

### Notes

- Inference is asynchronous on a worker thread; cook never blocks and results lag by 1–2 frames
- The point count varies with the input. Tune it with Maximum Image Dimension, Simplify and
  Maximum Points
- Even a still image is re-analysed automatically when a processing parameter changes

### Build

```sh
cd VisionContours && ./build.sh
```

## 日本語

入力TOPのエッジ輪郭をApple Visionの`VNDetectContoursRequest`で抽出し、閉じたLine
primitiveとして出力するSOP。輪郭をSweep、Extrude、Particle、レーザー描画などの
TouchDesignerジオメトリ処理へ直接渡せる。macOS 11以降。

### 出力仕様

- 座標: `P.x/P.y` = 0〜1、左下原点。`P.z=0`
- 各輪郭は始点を末尾に複製した閉じたLine primitive
- Pointカスタム属性:

| 属性 | 内容 |
|---|---|
| `contourid` | 検出結果内の輪郭番号 |
| `parentid` | 包含する親輪郭の番号。親なしは-1 |
| `depth` | 輪郭階層の深さ。トップレベルは0 |
| `closed` | 常に1 |

### パラメータ

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
| Aspect Correct UVs | 既定Off。点の縦方向を入力画像のアスペクト比に合わせる（下記） |

#### Aspect Correct UVs（アスペクト比補正）

点は Vision の 0〜1（左下原点）なので、**そのままだと 0〜1 の正方形に入る**。16:9 の映像だと
輪郭が縦に間延びし、映像に重ねたときシルエットからはみ出す。

`Aspect Correct UVs` を On にすると縦だけを 1/aspect に縮める（横は 0〜1 のまま）:

```
aspect = 入力幅 / 入力高さ
P.x' = P.x                              （0〜1 のまま）
P.y' = 0.5 + (P.y - 0.5) / aspect       （中心を保って縦を縮める）
```

これで **Geometry COMP を -0.5 だけ寄せ、Ortho Width = 1 のカメラ**で撮ると元映像にぴったり
重なる。1280x720 での実測は `P.y` が `0.2188..0.7812`（= 0.5 ± 0.5/1.7778）。
TD標準 Body Track CHOP の同名パラメータと同じ役割・同じ既定値で、他の Vision 系OPとも揃えてある。

素の 0〜1 座標が欲しい場合（Sweep や Extrude に渡して独自にスケールする等）は Off のままでよい。

### Info CHOP

`executes / submits / analyzes / analyze_ms / detected / contours / points`。
`detected`はVisionの全検出数、`contours`はフィルタ後の出力数。

### 注意

- 推論はワーカースレッドで非同期。cookをブロックせず、結果は1〜2フレーム遅れる
- 出力点数は入力内容で変動する。Maximum Image Dimension、Simplify、Maximum Pointsで調整する
- 静止画でも処理パラメータ変更時は自動的に再解析する

### ビルド

```sh
cd VisionContours && ./build.sh
```
