# Vision Pose CHOP — TouchDesigner custom operator (macOS)

**English** | [日本語](#日本語)

## English

A TD-native custom CHOP that runs multi-person body pose estimation on a TOP's image with Apple
Vision (`VNDetectHumanBodyPoseRequest`) and outputs **exactly the same channel layout as TD's
built-in Body Track CHOP** (NVIDIA, 2D, multi-person). Everything happens inside TD — no external
app, OSC or extra runtime — and it is meant as a drop-in macOS replacement for the Windows+NVIDIA
Body Track CHOP.

The channel layout was checked against real Body Track CHOP output (a bclip sample) and matches
**exactly in both names and order** (1680 channels with Rotations on, 864 off, for 8 bodies).

Measured (M2, 1252x736, 5 people): analysis keeps up 1:1 with cook (60 fps, no dropped frames).
Processing runs asynchronously on a worker thread and never blocks cook (results lag 1–2 frames).

### Usage

**Option A: load it in a CPlusPlus CHOP (quick, no restart)**
1. Create a CPlusPlus CHOP and set Plugin Path to `build/VisionPoseCHOP.plugin`
2. On the "Vision Pose" custom parameter page, set `TOP` to your video source

**Option B: install it as a custom operator (becomes the `Visionpose` operator)**
```
mkdir -p ~/Library/Application\ Support/Derivative/TouchDesigner099/Plugins
cp -R build/VisionPoseCHOP.plugin ~/Library/Application\ Support/Derivative/TouchDesigner099/Plugins/
# restart TD → "Vision Pose" appears under CHOP in the OP Create Dialog
```

### Parameters

| Parameter | Default | Description |
|---|---|---|
| TOP | — | Path of the TOP to analyse |
| Active | On | Enable/disable analysis |
| Max Bodies | 8 | Number of body slots to output (**1–100**; the slider shows up to 10. Changes the channel count) |
| Rotations (layout only) | Off | Emit the same rx/ry/rz channels as Body Track's Rotations (**the values are always 0** — for layout compatibility) |
| Flip Image Vertically | **On** | TD's TOP download is upside down (bottom-up), so this defaults to On. Normally leave it alone |

### Output channels (Body Track CHOP 2D compatible; 108 per body, 210 with Rotations)

| Channel | Description |
|---|---|
| `body{i}:valid` | Whether it is being tracked (1/0). i starts at 1 |
| `body{i}/bbox:u` `:v` `:width` `:height` | Bounding box (centre + size; the box around the confident joints) |
| `body{i}/trackingid` | Persistent ID (starting at 1, maintained by nearest-neighbour matching between frames — the equivalent of People Tracking) |
| `body{i}/{kp}:u` `:v` `:confidence` | 34 keypoints (0–1, bottom-left origin) |
| `body{i}/{kp}:rx` `:ry` `:rz` | Only with Rotations on. **Always 0, since Vision does not provide them** |

The 34 keypoints (Maxine's names and order): `pelvis left_hip right_hip torso left_knee right_knee
neck left_ankle right_ankle left_big_toe right_big_toe left_small_toe right_small_toe
left_heel right_heel nose left_eye right_eye left_ear right_ear left_shoulder right_shoulder
left_elbow right_elbow left_wrist right_wrist left_pinky_knuckle right_pinky_knuckle
left_middle_tip right_middle_tip left_index_knuckle right_index_knuckle left_thumb_tip right_thumb_tip`

How keypoints Vision does not have are handled (**identifiable by confidence = 0**):
- Toes and heels (big_toe/small_toe/heel) → the **ankle position** on the same side, confidence 0
- Fingers (pinky/middle/index/thumb) → the **wrist position** on the same side, confidence 0
- `torso` → the midpoint of neck and root (pelvis) (confidence is the lower of the two)

Body slots are maintained by tracking (the same person stays on the same `body{i}/trackingid` even
as people come and go; when lost, valid goes to 0, and on return they take a free slot with a new
trackingid).

Info CHOP (diagnostics): `executes / submits / analyzes / last_w / last_h / last_bytes`.
If `analyzes` keeps up with `executes`, no frames are being dropped.

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

### Build

```
./build.sh    # → build/VisionPoseCHOP.plugin (needs Xcode; TD's C++ SDK headers come from inside TD.app)
```

## 日本語

TOP の映像を Apple Vision（`VNDetectHumanBodyPoseRequest`）で多人数ボディポーズ推定し、
**TD 標準の Body Track CHOP（NVIDIA・2D複数人）と同一のチャンネル形式**で出力する
TD ネイティブのカスタム CHOP。外部アプリ・OSC・追加ランタイム不要で TD 内で完結し、
Windows+NVIDIA 専用の Body Track CHOP を macOS で置き換えるドロップイン用途を想定。

チャンネルレイアウトは実機の Body Track CHOP 出力（bclip サンプル）と突き合わせて
**チャンネル名・順序とも完全一致**を確認済み（Rotations 有効時 1680ch / 無効時 864ch・8体時）。

実測（M2 / 1252x736 / 5人）: 解析が cook と 1:1 で追従（60fps・フレーム落ちなし）。
処理はワーカースレッドで非同期実行され、cook をブロックしない（結果は1〜2フレーム遅れ）。

### 使い方

**方法A: CPlusPlus CHOP でロード（手軽・再起動不要）**
1. CPlusPlus CHOP を作成し、Plugin Path に `build/VisionPoseCHOP.plugin` を指定
2. カスタムパラメータページ「Vision Pose」で `TOP` に映像ソースを指定

**方法B: カスタムOPとしてインストール（`Visionpose` オペレータになる）**
```
mkdir -p ~/Library/Application\ Support/Derivative/TouchDesigner099/Plugins
cp -R build/VisionPoseCHOP.plugin ~/Library/Application\ Support/Derivative/TouchDesigner099/Plugins/
# TD を再起動 → OP Create Dialog の CHOP に「Vision Pose」が現れる
```

### パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| TOP | — | 解析する映像の TOP パス |
| Active | On | 解析の有効/無効 |
| Max Bodies | 8 | 出力する body 枠数（**1〜100**・スライダー表示は10まで。チャンネル数が変わる） |
| Rotations (layout only) | Off | Body Track の Rotations と同じ rx/ry/rz チャンネルを出す（**値は常に0**・レイアウト互換用） |
| Flip Image Vertically | **On** | TD の TOP ダウンロードは上下逆（bottom-up）なので既定 On。通常触らない |

### 出力チャンネル（Body Track CHOP 2D 互換・body ごとに 108ch / Rotations 時 210ch）

| チャンネル | 内容 |
|---|---|
| `body{i}:valid` | トラッキング中か（1/0）。i は 1 始まり |
| `body{i}/bbox:u` `:v` `:width` `:height` | バウンディングボックス（中心+サイズ。信頼関節の外接矩形） |
| `body{i}/trackingid` | 永続ID（1始まり。フレーム間の最近傍マッチで維持 = People Tracking 相当） |
| `body{i}/{kp}:u` `:v` `:confidence` | 34キーポイント（0〜1・左下原点） |
| `body{i}/{kp}:rx` `:ry` `:rz` | Rotations 有効時のみ。**Vision では取れないため常に 0** |

34キーポイント（Maxine 準拠の名前・順序）: `pelvis left_hip right_hip torso left_knee right_knee
neck left_ankle right_ankle left_big_toe right_big_toe left_small_toe right_small_toe
left_heel right_heel nose left_eye right_eye left_ear right_ear left_shoulder right_shoulder
left_elbow right_elbow left_wrist right_wrist left_pinky_knuckle right_pinky_knuckle
left_middle_tip right_middle_tip left_index_knuckle right_index_knuckle left_thumb_tip right_thumb_tip`

Vision に無いキーポイントの扱い（**confidence=0 で判別可能**）:
- つま先・かかと（big_toe/small_toe/heel）→ 同側の **足首の位置**を confidence 0 で出力
- 手指（pinky/middle/index/thumb）→ 同側の **手首の位置**を confidence 0 で出力
- `torso` → neck と root(pelvis) の中点（confidence は両者の低い方）

body スロットはトラッキングで維持される（人が入れ替わっても同じ人は同じ body{i}/trackingid に留まる。
ロストすると valid=0 になり、復帰時は空きスロットに新しい trackingid で入る）。

Info CHOP（動作診断）: `executes / submits / analyzes / last_w / last_h / last_bytes`。
`analyzes` が `executes` に追従していればフレーム落ちなし。

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

### ビルド

```
./build.sh    # → build/VisionPoseCHOP.plugin（要 Xcode。TD の C++ SDK ヘッダはTD.app内のものを参照）
```
