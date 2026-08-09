# Vision Pose 3D CHOP — single-person 3D pose (macOS 14+)

**English** | [日本語](#日本語)

## English

A TD-native custom CHOP that estimates the 3D body pose (17 joints, in metres) of **the most
prominent person** in a TOP's image, using `VNDetectHumanBodyPose3DRequest`.

The single-person 3D counterpart to the 2D multi-person
[Vision Pose CHOP](../VisionPose/) (Body Track compatible, 60 fps).

### Performance (important)

| | Value (M2, 1252x736 input) |
|---|---|
| First analysis | **about 17 s** (loading/compiling the 3D model; fast afterwards) |
| Steady state | **about 0.5 s per frame (≈ 2 fps)** |

Not suited to real-time per-frame use. Aim it at pose judgement, measurement and snapshot-style
uses. (Execution is asynchronous and cook never blocks, so TD's frame rate does not drop — the
channel values simply update about twice a second.)

### Output channels (91)

| Channel | Description |
|---|---|
| `valid` | Whether a person was detected (1/0) |
| `bodyheight` | Estimated height (metres) |
| `heightestimation` | 0 = reference (estimated from a default height) / 1 = measured (real, when depth such as LiDAR is available) |
| `camera:tx,ty,tz` | Camera position (metres, relative to the scene origin) |
| `{joint}:tx,ty,tz` | Joint 3D position (metres, **scene origin = the person's root**, y up) |
| `{joint}:u,v` | The joint's 2D projection into the input image (0–1, bottom-left origin) |

The 17 joints: `root spine center_shoulder center_head top_head
left_shoulder left_elbow left_wrist right_shoulder right_elbow right_wrist
left_hip left_knee left_ankle right_hip right_knee right_ankle`

Coordinate system: the person's root (hips) is the scene origin. Standing upright, for example,
`top_head:ty ≈ +0.77` and `right_ankle:ty ≈ -0.87` (with an estimated height of 1.8 m). Distance
and direction relative to the camera come from `camera:*`.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| TOP | — | Path of the TOP to analyse |
| Active | On | Enable/disable analysis |
| Flip Image Vertically | **On** | TD's TOP download is upside down (bottom-up), so this defaults to On |

Info CHOP (diagnostics): `executes / submits / analyzes / analyze_ms` (ms per analysis).

### Aspect Correct UVs

`Aspect Correct UVs` (default **Off**) rescales uv so that one uv unit is the same pixel distance
horizontally and vertically. Same role and same default as the parameter of the same name on TD's
built-in **Body Track CHOP**.

```
aspect = input width / input height
u' = u                             (stays 0..1)
v' = 0.5 + (v - 0.5) / aspect      (shrunk to 1/aspect about the centre)
```

**Only `u,v` are affected**; `tx,ty,tz` are in metres and never touched. Because `u` stays in
0..1, instancing with `tx = u - 0.5` / `ty = v - 0.5` lands exactly on the source video **with the
camera's Ortho Width left at 1** (no manual scaling). Leave it Off when you want raw 0..1 image
coordinates.

### Build

```
./build.sh    # → build/VisionPose3DCHOP.plugin (needs macOS 14+)
```

For how to load it, see the [root README](../README.md) (a CPlusPlus CHOP, or the Plugins folder).

## 日本語

TOP の映像から**最も目立つ1人**の3Dボディポーズ（17関節・メートル単位）を推定する
TD ネイティブのカスタム CHOP。`VNDetectHumanBodyPose3DRequest` を使用。

2D複数人の [VisionPose CHOP](../VisionPose/)（Body Track 互換・60fps）と対になる単一人物・3D版。

### 性能特性（重要）

| | 値（M2・1252x736入力） |
|---|---|
| 初回解析 | **約17秒**（3Dモデルの初回ロード/コンパイル。以後は速い） |
| 定常解析 | **約0.5秒/フレーム（≒2fps）** |

リアルタイムの毎フレーム用途には向かない。姿勢の判定・計測・スナップショット的な
用途向け（cook はブロックしない非同期実行なので、TD のフレームレートは落ちない。
チャンネル値が約0.5秒間隔で更新される、という動き方になる）。

### 出力チャンネル（91ch）

| チャンネル | 内容 |
|---|---|
| `valid` | 検出できたか（1/0） |
| `bodyheight` | 推定身長（メートル） |
| `heightestimation` | 0=reference（既定身長から推定）/ 1=measured（実測。LiDAR等の深度がある場合） |
| `camera:tx,ty,tz` | カメラ位置（メートル・シーン原点基準） |
| `{joint}:tx,ty,tz` | 関節の3D位置（メートル・**シーン原点=人物root**・y上向き） |
| `{joint}:u,v` | 関節の入力画像への2D投影（0〜1・左下原点） |

17関節: `root spine center_shoulder center_head top_head
left_shoulder left_elbow left_wrist right_shoulder right_elbow right_wrist
left_hip left_knee left_ankle right_hip right_knee right_ankle`

座標系: 人物の root（腰）がシーン原点。例: 直立時は `top_head:ty ≈ +0.77`、
`right_ankle:ty ≈ -0.87`（身長1.8m推定時）。カメラとの距離・向きは `camera:*` から分かる。

### パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| TOP | — | 解析する映像の TOP パス |
| Active | On | 解析の有効/無効 |
| Flip Image Vertically | **On** | TD の TOP ダウンロードは上下逆（bottom-up）のため既定 On |

Info CHOP（動作診断）: `executes / submits / analyzes / analyze_ms`（1解析の所要ms）。

### Aspect Correct UVs（アスペクト比補正）

`Aspect Correct UVs`（既定 **Off**）は uv の1単位が縦横で同じピクセル距離になるよう再スケールする。
TD標準 **Body Track CHOP** の同名パラメータと同じ役割・同じ既定値。

```
aspect = 入力幅 / 入力高さ
u' = u                             （0〜1 のまま）
v' = 0.5 + (v - 0.5) / aspect      （中心を保って 1/aspect に縮小）
```

**影響するのは `u,v` だけ**で、`tx,ty,tz`（メートル）は変換しない。
`u` が 0〜1 のままなので、`tx = u - 0.5` / `ty = v - 0.5` でインスタンシングすると
**カメラの Ortho Width を 1 のまま**で元映像にぴったり重なる（手動スケール不要）。
生の 0〜1 画像座標が欲しいときは Off のままにする。

### ビルド

```
./build.sh    # → build/VisionPose3DCHOP.plugin（要 macOS 14+）
```

使い方は [ルート README](../README.md) 参照（CPlusPlus CHOP でロード or Plugins フォルダへ）。
