# Vision Trajectory CHOP

Apple Visionのstateful `VNDetectTrajectoriesRequest`で、ボールなど放物運動する小物体の
軌跡を検出するCHOP。macOS 11以降。

各`trajectory{i}`は`valid / a / b / c / radius / points`と、Trajectory Length個の
`point{j}:detected_u,detected_v,projected_u,projected_v`を出力する。式は
`y = a*x^2 + b*x + c`、座標は0〜1・左下原点。

| パラメータ | 内容 |
|---|---|
| TOP | 連続映像入力 |
| Active | 検出On/Off |
| Max Trajectories | 出力スロット。最大100 |
| Trajectory Length | 放物線判定に必要な点数。5〜30 |
| Minimum/Maximum Object Radius | 対象半径の正規化範囲 |
| Target FPS | sample timestampとVisionの処理目標時間 |
| Reset Tracking | stateful requestを初期化 |
| Flip Image Vertically | 既定On |

Info CHOPは`executes/submits/analyzes/analyze_ms/trajectories/frames/resets`。

**一般的な任意物体トラッカーではない**。一定サイズの物体が放物線に沿って移動し、最低5フレーム
蓄積して初めてvalidになる。カット切替、ループ先頭、解像度変更時はReset Trackingを押す。


### Aspect Correct UVs（アスペクト比補正）

`Aspect Correct UVs`（既定 **Off**）は uv の1単位が縦横で同じピクセル距離になるよう再スケールする。
TD標準 **Body Track CHOP** の同名パラメータと同じ役割・同じ既定値。

```
aspect = 入力幅 / 入力高さ
u' = u                             （0〜1 のまま）
v' = 0.5 + (v - 0.5) / aspect      （中心を保って 1/aspect に縮小）
bbox の height（v方向の距離）も 1/aspect、width は不変
```

`u` が 0〜1 のままなので、`tx = u - 0.5` / `ty = v - 0.5` でインスタンシングすると
**カメラの Ortho Width を 1 のまま**で元映像にぴったり重なる（手動スケール不要）。
生の 0〜1 画像座標が欲しいときは Off のままにする。

## ビルド

```sh
cd VisionTrajectory && ./build.sh
```
