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

### Output channels (89)

| Channel | Description |
|---|---|
| `valid` | Whether a person was detected (1/0) |
| `cam:facing` | **Which way the performer faces** relative to the lens (degrees; 0 = facing you, ±90 = profile, ±180 = back to you) |
| `cam:distance` | Lens-to-hips distance (metres) |
| `cam:fov` | The horizontal FOV the reconstruction used (degrees) — drop it into a Camera COMP's FOV Angle and the 3D skeleton lands on the source video |
| `{joint}:tx,ty,tz` | Joint 3D position (metres, y up; origin set by **Coordinate Space**) |
| `{joint}:u,v` | The joint's 2D projection into the input image (0–1, bottom-left origin) |

The 17 joints: `root spine center_shoulder center_head top_head
left_shoulder left_elbow left_wrist right_shoulder right_elbow right_wrist
left_hip left_knee left_ankle right_hip right_knee right_ankle`

### Coordinate Space

| Value | Origin | What it looks like |
|---|---|---|
| `root` (default) | The person's hips | Vision's native output. Standing upright, `top_head:ty ≈ +0.77` and `right_ankle:ty ≈ -0.87` (estimated height 1.8 m). **The figure never translates** — jumping or walking toward the camera only changes the shape of the limbs |
| `camera` | The camera | The figure moves as the person does: jumps lift it, walking toward the camera brings it closer (measured: `root:tz` ≈ -2.4 for a subject about 2.4 m away — the subject sits at negative Z) |

`camera` multiplies each joint by **`cameraOriginMatrix` itself — not its inverse**. Despite the
name, that matrix is the *model → camera* transform.

This was verified rather than assumed. For each candidate the camera-space points were projected
(`x/z`, `y/z`), a focal length was fitted by least squares, and the residual against Vision's own
`pointInImage` was measured over 8 frames:

| Candidate | Mean reprojection residual (normalised image coords) |
|---|---|
| **`M * p`** | **0.00000** — exact, on every frame |
| `p - t` (subtract the translation) | 0.01309 |
| `inverse(M) * p` | 0.02663 |

So the forward matrix is right and the other two are wrong. Camera space is **−Z forward**, the
same convention as a TD camera: put a Camera COMP at the origin with default rotation and it looks
straight down the real camera's axis. Since TD's FOV Angle is horizontal, a full body at ~2.5 m
needs the camera pulled back (the example uses `tz = 2.5`) or a wider FOV.

### The `cam:` channels

`cam:*` describes the **relationship between the performer's own frame and the camera** — nothing
about the camera in absolute terms. Either side moving changes it: a locked-off tripod still
produces a swinging `cam:facing` when the performer turns.

| Channel | Use it for |
|---|---|
| `cam:facing` | Trigger on "turns to face the audience", crossfade between front/side looks, drive a spatial-audio pan |
| `cam:distance` | Proximity effects: brightness, reverb, particle density as someone walks in |
| `cam:fov` | Feed a Camera COMP's FOV Angle to land the skeleton on the source video |

**`cam:facing` is computed from the shoulders, not from an Euler decomposition.** The camera's
rotation as Euler angles splits the facing information across two axes: on footage where the
subject is filmed entirely from behind, the yaw term sits at −35° the whole time while the *pitch*
term flips to ±178°. Taking the chest normal (shoulder vector × up) and an `atan2` gives one angle
covering the full circle instead — measured +125…+138° on that back-facing clip, +5…+10° when the
dancer faces the lens, ±74…81° in profile.

Earlier versions also published `cam:tx,ty,tz`, `cam:rx,ry,rz`, `cam:azimuth` and `cam:elevation`.
They were removed after checking what they actually added: the azimuth/elevation pair is `root:u,v`
restated as angles (converting through `cam:fov` reproduces them exactly), and the position/rotation
sextet only served to park a TD camera in `root` space — which produces the same picture as
`camera` space with the camera at the origin.

Note `cam:distance` is **not** `root:tz`; it is the length of the whole vector. Measured on one
frame: hips at 2.16 m along the body's Z but 2.52 m away in total, a 16 % difference.

### Camera FOV — set this if you care about distances

Left at 0, Vision assumes a **horizontal FOV of 98.824°** — a very wide lens. That number is not
estimated from the footage: it comes out identical on all 8 clips measured here, across both
1280x720 and 1920x1080 and completely different framings. It is a fixed assumption.

Give the operator the real lens angle and it passes proper intrinsics
(`VNImageOptionCameraIntrinsics`) to Vision, which honours them. Same frame, in TouchDesigner:

| Camera FOV | `cam:distance` |
|---|---|
| 0 (Vision's 98.8° assumption) | 2.8 m |
| 120° | 2.05 m |
| 70° | 5.14 m |
| 40° | 8.54 m |

**The pose itself does not change.** Joint positions in `root` space are bit-identical at every
FOV — Vision estimates the body independently of the lens. What the FOV fixes is *where the body
is placed relative to the camera*: `cam:distance` and all `camera`-space joint coordinates.

So: leave it at 0 if you only use the skeleton's shape. Set it if you use distances, camera-space
positions, or want the overlay to match a narrow lens.

**Can you recover the FOV from `cam:distance`?** Not from Vision's own distance — the two are
locked together, because the distance was derived from whatever FOV was assumed. Measured on one
frame, `distance × tan(FOV/2)` stays at 2.55–2.62 across the whole sweep, so the product is a
constant of the shot (how large the performer appears), not new information.

That constant is exactly what makes a one-off calibration possible. Measure the real lens-to-
performer distance once with a tape, read `cam:distance` with Camera FOV at 0, then

```
K   = distance_auto × tan(98.824° / 2)
FOV = 2 × atan(K / distance_real)
```

For the frame above (K = 2.59): a real distance of 5 m implies a 55° lens, 3 m implies 82°.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| TOP | — | Path of the TOP to analyse |
| Active | On | Enable/disable analysis |
| Camera FOV (deg, 0 = auto) | 0 | Horizontal FOV of the real lens. 0 leaves Vision's own assumption — see below |
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

### 出力チャンネル（89ch）

| チャンネル | 内容 |
|---|---|
| `valid` | 検出できたか（1/0） |
| `cam:facing` | **演者がレンズに対してどちらを向いているか**（度・0=正面 / ±90=真横 / ±180=背面） |
| `cam:distance` | レンズ〜腰の距離（メートル） |
| `cam:fov` | 再構成に使われた水平画角（度）。Camera COMP の FOV Angle に入れると3D骨格が元映像に重なる |
| `{joint}:tx,ty,tz` | 関節の3D位置（メートル・y上向き・原点は **Coordinate Space** で決まる） |
| `{joint}:u,v` | 関節の入力画像への2D投影（0〜1・左下原点） |

17関節: `root spine center_shoulder center_head top_head
left_shoulder left_elbow left_wrist right_shoulder right_elbow right_wrist
left_hip left_knee left_ankle right_hip right_knee right_ankle`

### Coordinate Space（座標の基準）

| 値 | 原点 | 見え方 |
|---|---|---|
| `root`（既定） | 人物の腰 | Vision そのまま。直立時は `top_head:ty ≈ +0.77`、`right_ankle:ty ≈ -0.87`（身長1.8m推定時）。**図は決して平行移動しない** — 跳んでも近づいても、変わるのは手足の形だけ |
| `camera` | カメラ | 人の動きがそのまま図の動きになる。跳べば持ち上がり、近づけば手前に来る（実測: 約2.4m 先の被写体で `root:tz` ≈ -2.4。被写体は -Z 側） |

`camera` は各関節に **`cameraOriginMatrix` そのもの（逆行列ではない）** を掛ける。
名前に反して、この行列は *model → カメラ* の変換である。

これは推測ではなく実測で決めた。各候補でカメラ空間の点を射影し（`x/z`, `y/z`）、焦点距離を
最小二乗で当てはめて、Vision 自身が返す `pointInImage` との残差を8フレームで測った:

| 候補 | 平均再投影残差（正規化画像座標） |
|---|---|
| **`M * p`** | **0.00000** — 全フレームで厳密に一致 |
| `p - t`（平行移動を引く） | 0.01309 |
| `inverse(M) * p` | 0.02663 |

つまり順方向の行列が正解で、他の2つは誤り。カメラ空間は **-Z が前方**で、TD のカメラと同じ規約。
Camera COMP を原点・回転0で置けば、実カメラの光軸をそのまま向く。ただし TD の FOV Angle は
**水平**なので、2.5m 先の全身を入れるにはカメラを引くか（利用例は `tz = 2.5`）FOV を広げる必要がある。

### cam: チャンネル

`cam:*` は**演者自身の座標系とカメラの関係**を表す量で、カメラの絶対的な情報ではない。
どちらが動いても変化するので、三脚で固定していても演者が振り向けば `cam:facing` は振れる。

| チャンネル | 使い道 |
|---|---|
| `cam:facing` | 「客席を向いた」をトリガに演出を切り替える、音を左右に振る |
| `cam:distance` | 近づくほど明るく/リバーブを減らす等の近接演出 |
| `cam:fov` | Camera COMP の FOV Angle に入れて骨格を元映像に重ねる |

**`cam:facing` は Euler 分解ではなく肩ベクトルから求めている。** カメラ回転を Euler 角で出すと
向きの情報が2軸に分裂する: 全編ずっと後ろ姿の映像で yaw は −35° 付近のまま動かず、代わりに
pitch が ±178° に振れた。胸の法線（肩ベクトル × 上方向）を `atan2` すれば1本の角度で全周を
表せる。実測で 後ろ姿 +125〜138° / 正面 +5〜10° / 真横 ±74〜81°。

以前は `cam:tx,ty,tz` / `cam:rx,ry,rz` / `cam:azimuth` / `cam:elevation` も出していたが、
実際に何が増えているのかを確認して削除した。azimuth・elevation は `root:u,v` を角度にしただけ
（`cam:fov` 経由で完全に一致することを実測）。位置・回転の6つは `root` 空間で TD カメラを
実カメラに合わせる用途専用で、それは `camera` 空間＋カメラ原点と同じ絵になる。

`cam:distance` は `root:tz` **ではない**。ベクトル全体の長さで、あるフレームの実測では
体のZ方向に 2.16m でも総距離は 2.52m と 16% 違った。

### Camera FOV — 距離を使うなら設定する

0 のままだと Vision は**水平画角 98.824° の広角**を仮定する。これは映像から推定した値ではなく、
ここで測った8クリップすべて（1280x720 と 1920x1080、画角もフレーミングもばらばら）で
まったく同じ値が出る**固定の仮定**。

実カメラの画角を渡すと、`VNImageOptionCameraIntrinsics` として Vision に伝わり、
Vision はそれを尊重する。TouchDesigner 上で同一フレームを測った結果:

| Camera FOV | `cam:distance` |
|---|---|
| 0（Vision の 98.8° 仮定） | 2.8 m |
| 120° | 2.05 m |
| 70° | 5.14 m |
| 40° | 8.54 m |

**姿勢そのものは変わらない。** `root` 空間の関節座標は画角を変えても完全に同一で、Vision は
レンズと無関係に体の形を推定している。画角が効くのは**体をカメラに対してどこに置くか**、
つまり `cam:distance` と `camera` 空間の関節座標だけ。

骨格の形しか使わないなら 0 のままでよい。距離やカメラ基準の座標を使うなら、あるいは望遠寄りの
レンズで撮った映像に重ねたいなら設定する。

**`cam:distance` から FOV を逆算できるか?** Vision が出す距離からは**できない**。距離は
仮定した FOV から導かれた値なので循環する。同一フレームで測ると `distance × tan(FOV/2)` は
2.55〜2.62 とほぼ一定で、この積は「演者がどれだけ大きく写っているか」というショット固有の
定数であって、新しい情報ではない。

裏を返せば、その定数を使えば**一度だけの実測で較正できる**。実際のレンズ〜演者の距離を
メジャーで測り、Camera FOV = 0 のときの `cam:distance` を読んで:

```
K   = distance_auto × tan(98.824° / 2)
FOV = 2 × atan(K / 実距離)
```

上のフレーム（K = 2.59）なら、実距離 5m で 55°、3m で 82° のレンズということになる。

### パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| TOP | — | 解析する映像の TOP パス |
| Active | On | 解析の有効/無効 |
| Camera FOV (deg, 0 = auto) | 0 | 実カメラの水平画角。0 なら Vision の仮定のまま。下記参照 |
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
