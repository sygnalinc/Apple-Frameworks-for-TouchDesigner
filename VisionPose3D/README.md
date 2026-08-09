# Vision Pose 3D CHOP — single-person 3D pose (macOS 14+)

**English** | [日本語](#日本語)

## English

A TD-native custom CHOP that estimates the 3D body pose (17 joints, in metres) of **the most
prominent person** in a TOP's image, using `VNDetectHumanBodyPose3DRequest`.

The single-person 3D counterpart to the 2D multi-person
[Vision Pose CHOP](../VisionPose/) (Body Track compatible, 60 fps).

### Performance (important)

| | Value (M2, 1280x720 input) |
|---|---|
| First analysis | **about 17 s** (loading/compiling the 3D model; cached for the rest of the process) |
| Steady state | **about 110–170 ms per analysis (≈ 6–9 per second)** |

Still not a 60 fps operator, but far from a slideshow. Execution is asynchronous and cook never
blocks, so TD's own frame rate does not drop — the channel values simply update a handful of
times per second.

> Earlier versions of this README said 0.5 s (≈2 fps). Two things changed: the request object is
> now **reused across frames** instead of being rebuilt each time (measured side by side on the
> same input: **165 ms vs 323 ms**, and 307 completed analyses vs 141 in the same window), and
> the OS itself got faster. Measured alone, the current build sits at **111 ms / 8.5 analyses per
> second**.

Things that do **not** help (all measured on M2):

| Idea | Result |
|---|---|
| Downscaling the input (1280x720 → 480x270) | 182 ms → 159 ms. Vision resizes internally anyway, so barely worth the accuracy risk |
| Forcing the Neural Engine or GPU with `setComputeDevice:forComputeStage:` | 166 ms (ANE) / 163 ms (GPU) vs 166 ms letting Vision choose — no gain |
| An IOSurface-backed pixel buffer | No difference (158 ms either way) |
| A different request revision | Only revision 1 exists |

### Output channels (91)

| Channel | Description |
|---|---|
| `valid` | Whether a person was detected (1/0) |
| `bodyheight` | Estimated height (metres) |
| `heightestimation` | 0 = reference (estimated from a default height) / 1 = measured (real, when depth such as LiDAR is available) |
| `camera:tx,ty,tz` | Camera position (metres, relative to the scene origin) |
| `{joint}:tx,ty,tz` | Joint 3D position (metres, y up; origin set by **Coordinate Space**) |
| `{joint}:u,v` | The joint's 2D projection into the input image (0–1, bottom-left origin) |

The 17 joints: `root spine center_shoulder center_head top_head
left_shoulder left_elbow left_wrist right_shoulder right_elbow right_wrist
left_hip left_knee left_ankle right_hip right_knee right_ankle`

### Coordinate Space

| Value | Origin | What it looks like |
|---|---|---|
| `root` (default) | The person's hips | Vision's native output. Standing upright, `top_head:ty ≈ +0.77` and `right_ankle:ty ≈ -0.87` (estimated height 1.8 m). **The figure never translates** — jumping or walking toward the camera only changes the shape of the limbs |
| `camera` | The camera | The figure moves as the person does: jumps lift it, walking toward the camera brings it closer (measured: `root:tz` ≈ +2.3 for a subject about 2.4 m away) |

`camera` multiplies each joint by `inverse(cameraOriginMatrix)`, so **the camera's rotation is
included**. Subtracting `camera:tx,ty,tz` downstream in TD is *not* equivalent — that only cancels
the translation. Measured on real footage the two disagree by **0.62 m**: the naive subtraction
puts the hips at `(0.006, -0.144, 2.420)` while the correct transform gives
`(-0.434, -0.573, 2.315)`. Both are 2.424 m from the camera — the distance is right, the direction
is not, because the camera is tilted.

`camera:tx,ty,tz` always stays the camera position in root space, in both modes (in camera space it
would be the origin by definition, which carries no information). To place the skeleton in front of
a TD camera, note the subject sits at **positive Z**.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| TOP | — | Path of the TOP to analyse |
| Active | On | Enable/disable analysis |
| Coordinate Space | root | Origin for `{joint}:tx,ty,tz` — see above |
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

| | 値（M2・1280x720入力） |
|---|---|
| 初回解析 | **約17秒**（3Dモデルの初回ロード/コンパイル。以降はプロセス内でキャッシュ） |
| 定常解析 | **約110〜170ms/回（≒毎秒6〜9回）** |

60fps のオペレータではないが、紙芝居でもない。cook はブロックしない非同期実行なので
TD 側のフレームレートは落ちず、チャンネル値が毎秒数回更新される、という動き方になる。

> 以前この README は 0.5秒（≒2fps）と書いていた。変わった理由は2つ。
> **リクエストを毎フレーム作り直すのをやめて使い回すようにしたこと**
> （同一入力での並走比較で **165ms 対 323ms**、同じ時間に完了した解析数は 307 対 141）と、
> OS 自体が速くなったこと。単独で走らせた現行ビルドは **111ms / 毎秒8.5回**。

**効かなかった手**（いずれもM2で実測）:

| 案 | 結果 |
|---|---|
| 入力を縮小（1280x720 → 480x270） | 182ms → 159ms。Vision が内部でリサイズするので、精度リスクに見合わない |
| `setComputeDevice:forComputeStage:` で ANE / GPU を明示 | ANE 166ms / GPU 163ms に対し、指定なし 166ms。差が無い |
| IOSurface 付きのピクセルバッファ | 差なし（どちらも158ms） |
| 別のリビジョン | revision 1 しか存在しない |

### 出力チャンネル（91ch）

| チャンネル | 内容 |
|---|---|
| `valid` | 検出できたか（1/0） |
| `bodyheight` | 推定身長（メートル） |
| `heightestimation` | 0=reference（既定身長から推定）/ 1=measured（実測。LiDAR等の深度がある場合） |
| `camera:tx,ty,tz` | カメラ位置（メートル・シーン原点基準） |
| `{joint}:tx,ty,tz` | 関節の3D位置（メートル・y上向き・原点は **Coordinate Space** で決まる） |
| `{joint}:u,v` | 関節の入力画像への2D投影（0〜1・左下原点） |

17関節: `root spine center_shoulder center_head top_head
left_shoulder left_elbow left_wrist right_shoulder right_elbow right_wrist
left_hip left_knee left_ankle right_hip right_knee right_ankle`

### Coordinate Space（座標の基準）

| 値 | 原点 | 見え方 |
|---|---|---|
| `root`（既定） | 人物の腰 | Vision そのまま。直立時は `top_head:ty ≈ +0.77`、`right_ankle:ty ≈ -0.87`（身長1.8m推定時）。**図は決して平行移動しない** — 跳んでも近づいても、変わるのは手足の形だけ |
| `camera` | カメラ | 人の動きがそのまま図の動きになる。跳べば持ち上がり、近づけば手前に来る（実測: 約2.4m 先の被写体で `root:tz` ≈ +2.3） |

`camera` は各関節に `inverse(cameraOriginMatrix)` を掛けるので、**カメラの回転（見下ろし角など）も
正しく入る**。TD側で `camera:tx,ty,tz` を引き算しても**等価にはならない** — 打ち消せるのは平行移動だけ。
実素材での実測では **0.62m ずれた**: 引き算だと腰が `(0.006, -0.144, 2.420)`、正しい変換では
`(-0.434, -0.573, 2.315)`。カメラからの距離はどちらも 2.424m で合っているが、
カメラが傾いているぶん**向きが違う**。

`camera:tx,ty,tz` はどちらのモードでも常に root 基準のカメラ位置のまま
（カメラ基準では定義上ゼロになり情報が無いため）。TDのカメラの前に置くときは、
被写体が **+Z 側**に来ることに注意。

### パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| TOP | — | 解析する映像の TOP パス |
| Active | On | 解析の有効/無効 |
| Coordinate Space | root | `{joint}:tx,ty,tz` の原点。上記参照 |
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
