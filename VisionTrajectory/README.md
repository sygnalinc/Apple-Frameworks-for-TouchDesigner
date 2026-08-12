# Vision Trajectory CHOP

**English** | [日本語](#日本語)

## English

Detects the trajectory of small objects in parabolic motion — a ball, for instance — with Apple
Vision's stateful `VNDetectTrajectoriesRequest`. macOS 11 or later.

Each `trajectory{i}` outputs `valid / a / b / c / radius / points` plus Trajectory Length entries
of `point{j}:detected_u,detected_v,projected_u,projected_v`. The equation is
`y = a*x^2 + b*x + c`, and coordinates are 0–1 with a bottom-left origin.

| Parameter | Description |
|---|---|
| TOP | Continuous video input |
| Active | Detection On/Off |
| Max Trajectories | Output slots. Up to 100 |
| Trajectory Length | Points needed to decide on a parabola. 5–30 |
| Minimum/Maximum Object Radius | Normalised radius range of the target |
| Target FPS | Sample timestamps and Vision's processing target |
| Reset Tracking | Reinitialise the stateful request |
| Flip Image Vertically | Default On |

Info CHOP: `executes/submits/analyzes/analyze_ms/trajectories/frames/resets`.

**This is not a general-purpose object tracker.** An object of consistent size must move along a
parabola, and at least five frames have to accumulate before anything becomes valid. Press Reset
Tracking on a cut, at the start of a loop, or when the resolution changes.

### Aspect Correct UVs

`Aspect Correct UVs` (default **Off**) rescales uv so that one uv unit is the same pixel distance
horizontally and vertically. Same role and same default as the parameter of the same name on TD's
built-in **Body Track CHOP**.

```
aspect = input width / input height
u' = u                             (stays 0..1)
v' = 0.5 + (v - 0.5) / aspect      (shrunk to 1/aspect about the centre)
```

The parabola coefficients follow: `a` and `b` are scaled by 1/aspect and `c` is transformed like a
v value. Because `u` stays in 0..1, instancing with `tx = u - 0.5` / `ty = v - 0.5` lands exactly
on the source video **with the camera's Ortho Width left at 1** (no manual scaling). Leave it Off
when you want raw 0..1 image coordinates.

### Build

```sh
cd VisionTrajectory && ./build.sh
```

## 日本語

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
```

放物線の係数も追従する（`a` と `b` は 1/aspect 倍、`c` は v と同じ変換）。
`u` が 0〜1 のままなので、`tx = u - 0.5` / `ty = v - 0.5` でインスタンシングすると
**カメラの Ortho Width を 1 のまま**で元映像にぴったり重なる（手動スケール不要）。
生の 0〜1 画像座標が欲しいときは Off のままにする。

### ビルド

```sh
cd VisionTrajectory && ./build.sh
```
