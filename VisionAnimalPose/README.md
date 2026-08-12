# Vision Animal Pose CHOP

**English** | [日本語](#日本語)

## English

Detects the 2D pose of dogs and cats with Apple Vision's `VNDetectAnimalBodyPoseRequest`.
macOS 14 or later. Multiple detections are ordered left to right across the frame.

### Output

80 channels per Max Animals slot.

- `animal{i}:valid`
- `animal{i}/bbox:u,v,w,h` (computed from the joints that meet the confidence threshold)
- `animal{i}/{joint}:u,v,confidence` (25 joints)

The joints are 6 ear points, 2 eyes, the nose, the neck, 6 front-leg points, 6 hind-leg points and
3 tail points. Coordinates are 0–1 with a bottom-left origin.

#### `top` / `bottom` in joint names means "tip / base" (confirmed by measurement)

They refer to the **distal / proximal end** of that body part, not to screen up and down.

| Joint | Meaning |
|---|---|
| `ear_top` / `ear_middle` / `ear_bottom` | The **tip** of the ear → middle → the **base** where it joins the head |
| `tail_top` / `tail_middle` / `tail_bottom` | The **tip** of the tail → middle → the **base** at the hips |

So when drawing a skeleton, the spine is **`neck` → `tail_bottom` (the hips)**, and the hind legs
also grow from `tail_bottom`. Using `neck` → `tail_top` draws **a line crossing empty space from
the neck to the tip of the tail** on a cat with its tail up. On a floppy-eared dog, `ear_top`
(the tip) sits below `ear_bottom` (the base) on screen — consistent with this definition.

### Parameters

| Name | Description |
|---|---|
| TOP | Input TOP |
| Active | Inference On/Off |
| Max Animals | Number of output slots. Internal limit 100, slider shows 10 |
| Minimum Joint Confidence | Joints below this are zeroed. Default 0.1 |
| Flip Image Vertically | Default On. Required for TD TOP input |

### Info CHOP

`executes / submits / analyzes / analyze_ms / animals`

### Aspect Correct UVs

`Aspect Correct UVs` (default **Off**) rescales uv so that one uv unit is the same pixel distance
horizontally and vertically. Same role and same default as the parameter of the same name on TD's
built-in **Body Track CHOP**.

```
aspect = input width / input height
u' = u                             (stays 0..1)
v' = 0.5 + (v - 0.5) / aspect      (shrunk to 1/aspect about the centre)
the bbox height (a v distance) is also 1/aspect; the width is unchanged
```

Because `u` stays in 0..1, instancing with `tx = u - 0.5` / `ty = v - 0.5` lands exactly on the
source video **with the camera's Ortho Width left at 1** (no manual scaling). Leave it Off when
you want raw 0..1 image coordinates.

### Notes

- Apple trained this on dogs and cats. Accuracy on other animals is not guaranteed
- Joints drop out easily when the subject is small, heavily occluded, or side-on
- Inference is asynchronous on a worker thread; results lag by 1–2 frames

### Build

```sh
cd VisionAnimalPose && ./build.sh
```

## 日本語

Apple Visionの`VNDetectAnimalBodyPoseRequest`で犬・猫の2D姿勢を検出するCHOP。
macOS 14以降。複数検出は画面の左から右へ並べる。

### 出力仕様

Max Animalsの各スロットに80チャンネルを出力する。

- `animal{i}:valid`
- `animal{i}/bbox:u,v,w,h`（信頼度を満たす関節から算出）
- `animal{i}/{joint}:u,v,confidence`（25関節）

関節は耳6点、目2点、鼻、首、前脚6点、後脚6点、尾3点。座標は0〜1・左下原点。

#### 関節名の `top` / `bottom` は「先端 / 付け根」（実測で確認）

画面の上下ではなく、その部位の**遠位端 / 近位端**を指す。

| 関節 | 意味 |
|---|---|
| `ear_top` / `ear_middle` / `ear_bottom` | 耳の**先端** → 中 → 頭に付く**付け根** |
| `tail_top` / `tail_middle` / `tail_bottom` | 尻尾の**先端** → 中 → 腰に付く**付け根** |

そのため骨格線を引くときの背骨は **`neck` → `tail_bottom`（腰）**、後脚も `tail_bottom` から生やす。
`neck` → `tail_top` にすると、尻尾を立てた猫で**首から尻尾の先まで空中を横切る線**になる。
垂れ耳の犬では `ear_top`（先端）が `ear_bottom`（付け根）より画面下に来る＝この定義で一貫している。

### パラメータ

| 名前 | 内容 |
|---|---|
| TOP | 入力TOP |
| Active | 推論On/Off |
| Max Animals | 出力スロット数。内部上限100、スライダー表示10 |
| Minimum Joint Confidence | 未満の関節を0クリア。既定0.1 |
| Flip Image Vertically | 既定On。TDのTOP入力には必須 |

### Info CHOP

`executes / submits / analyzes / analyze_ms / animals`。

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

### 注意

- Appleの学習対象は犬・猫。ほかの動物での精度は保証されない
- 被写体が小さい、遮蔽が多い、横を向いている場合は関節が欠落しやすい
- 推論はワーカースレッドで非同期。結果は1〜2フレーム遅れる

### ビルド

```sh
cd VisionAnimalPose && ./build.sh
```
