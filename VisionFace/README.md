# Vision Face CHOP — face detection + landmarks (macOS)

**English** | [日本語](#日本語)

## English

A TD-native custom CHOP that detects multiple faces (`VNDetectFaceLandmarksRequest`) in a TOP's
image. Intended as the macOS answer to the Windows+NVIDIA-only Face Track CHOP (the channel layout
is our own).

### Output channels (Max Faces = N, 16 channels each; 168 with Landmarks on)

| Channel | Description |
|---|---|
| `face{i}:valid` | Whether a face was detected (1/0) |
| `face{i}/bbox:u,v,width,height` | Face bounding box (centre + size, 0–1) |
| `face{i}/roll` `yaw` `pitch` | Face orientation in radians (**an axis that cannot be obtained is 0**) |
| `face{i}/left_eye:u,v` `right_eye` `nose` `mouth` | Centres of the main landmarks (normalised image coordinates) |
| `face{i}/p{0..84}:u,v` | Only with Landmarks on: all 85 landmark points. They are ordered **per region, in the correct order within that region**, so joining consecutive indices draws the contour |

Faces are sorted left to right by the x of the bbox centre.

### How far `yaw` actually reaches

Measured against frames whose direction was confirmed by eye:

| The subject | `yaw` | `body:facing` (Vision Pose 3D) |
|---|---|---|
| Facing the lens | −4.2° | −5.8° |
| Turned 90° to the right | **+48.0°** | +90.7° |
| Turned 90° to the right | **+41.1°** | +89.4° |
| Turned 90° to the left | **no face detected** | −90.2° |
| Back to the camera | **no face detected** | +136.9° |

Two things to plan around. `yaw` **saturates near ±45–50°** — a full profile does not read as 90°,
so treat it as "how far the head is turned", not as an absolute heading. And the face has to be
findable at all: full profile is hit-and-miss and a back view returns nothing, so gate on the
face's own `valid` before using the angle.

Within that range the sign agrees with the body's facing, so the two can be combined: **Vision Pose
3D's `body:facing` gives the torso through the full circle, `yaw` here gives the head relative to
the camera.** That is how you tell "body square to the audience but looking off to the side" from
"whole body turned".

### Parameters

| Parameter | Default | Description |
|---|---|---|
| TOP | — | Path of the TOP to analyse |
| Active | On | Enable/disable analysis |
| Max Faces | 5 | Maximum faces to detect (**1–100**; the slider shows up to 10) |
| All Landmark Points (85) | Off | Output all 85 points as p0..p84 (more channels) |
| Flip Image Vertically | **On** | TD's TOP download is upside down, so this defaults to On |

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

### Landmark ordering (p0..p84)

Vision's raw `allPoints` ordering is not usable for drawing, so the points are **repacked per
region** before output. Joining consecutive indices gives you the contour, eyes, brows and lips
directly (the nose has a caveat below).

| Range | Region | Points | Closed |
|---|---|---|---|
| 0-16 | faceContour | 17 | open |
| 17-22 / 23-28 | leftEye / rightEye | 6 / 6 | closed |
| 29-34 / 35-40 | leftEyebrow / rightEyebrow | 6 / 6 | open |
| 41-48 | nose | 8 | open |
| 49-54 | noseCrest | 6 | open |
| 55-64 | medianLine | 10 | open |
| 65-78 | outerLips | 14 | closed |
| 79-84 | innerLips | 6 | closed |

The counts are measured on macOS 26 (constant across 288 samples: 12 faces × several frames), for
**85 points** in total. `allPoints` only returns 76 because **medianLine overlaps other regions**.

Unused slots are sentinels with `u = v = -1`, so skip them when drawing.

**Joining the nose points consecutively looks asymmetric.** That is how Vision orders them, not a
packing problem on our side (the same structure was confirmed across several faces):

| Symptom | The actual data | How to draw it |
|---|---|---|
| A long diagonal from the midline to the left nostril | `nose`'s `p41` is the bottom of the bridge (on the midline), and `p42` jumps straight to the left nostril | Start the nostril sweep **at `p42`** |
| A one-sided spur below the bridge | In `noseCrest`, `49→52` is the straight bridge and **`p53` / `p54` are the left and right nostrils** (a pair at the same height) | Draw the bridge **`49-52`** and the nostril bar **`53-54`** separately |
| The bridge appears as a double line | `medianLine` (55-64) is the midline from the glabella to the chin and overlaps the bridge, nose and contour points | Do not draw `medianLine` |

`demo.toe`'s `VisionFace/geo2/contour` is built along these lines and serves as the reference
implementation.

> **Before v0.9.2 the contour was allocated only 16 points, so the 17th was dropped, one side
> ended short and the face looked asymmetric.** Allocating fewer slots than the real count
> silently truncates the tail. Counting *used* slots **only reveals under-fill, never
> truncation** — measure the region's `pointCount` directly.

### Notes

- **Face Capture Quality** (toggle, default Off): with it on, `face{i}/quality` (a 0–1 shot-quality
  score from VNDetectFaceCaptureQualityRequest) is added after roll/yaw/pitch. Good for a photo
  booth that picks the best expression automatically. With it off the channels are unchanged

- Detection is unstable when faces are small (a wide full-body shot, say). A bust-up framing is
  reliable
- **Drawn faces (a print on a T-shirt, for instance) can also be detected as faces** (this is how
  Vision works)
- Measured: bbox and the relative positions of eyes/nose/mouth confirmed correct on a face photo

Info CHOP: `executes / submits / analyzes`. Build with `./build.sh`.

## 日本語

TOP の映像から複数の顔（`VNDetectFaceLandmarksRequest`）を検出する
TD ネイティブのカスタム CHOP。Windows+NVIDIA 専用 Face Track CHOP の macOS 代替を想定
（チャンネル形式は独自）。

### 出力チャンネル（Max Faces = N・各 16ch / Landmarks 有効時 168ch）

| チャンネル | 内容 |
|---|---|
| `face{i}:valid` | 検出できたか（1/0） |
| `face{i}/bbox:u,v,width,height` | 顔バウンディングボックス（中心+サイズ・0〜1） |
| `face{i}/roll` `yaw` `pitch` | 顔の向き（ラジアン。**取得できない軸は 0**） |
| `face{i}/left_eye:u,v` `right_eye` `nose` `mouth` | 主要ランドマークの中心（画像正規化座標） |
| `face{i}/p{0..84}:u,v` | Landmarks オン時のみ・全85ランドマーク点。**領域ごとに、その領域内の正しい順序**で並ぶので連番で結べば輪郭が描ける |

face の並びは bbox 中心の x で左→右にソート。

### `yaw` が実際にどこまで出るか

向きを目視で確認したフレームで実測:

| 被写体 | `yaw` | `body:facing`（Vision Pose 3D） |
|---|---|---|
| レンズを向いている | −4.2° | −5.8° |
| 右へ90度 | **+48.0°** | +90.7° |
| 右へ90度 | **+41.1°** | +89.4° |
| 左へ90度 | **顔が検出されない** | −90.2° |
| 背中を向けている | **顔が検出されない** | +136.9° |

見込んでおくべき点が2つ。`yaw` は **±45〜50度あたりで頭打ち**になり、真横を向いても 90度にはならない。
絶対的な方位ではなく「頭をどれだけひねっているか」として扱う。そもそも顔が見つかる必要もあり、
真横は当たり外れがあり背面では何も返らないので、**角度を使う前に顔側の `valid` で門番する**。

その範囲内では体の向きと符号が一致するので、組み合わせて使える。**Vision Pose 3D の `body:facing`
が全周の体の向きを、ここの `yaw` がカメラに対する頭の向きを与える。** 「体は客席に正対したまま
顔だけ横を向いている」と「体ごと向きを変えた」を区別できるのはこの組み合わせ。

### パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| TOP | — | 解析する映像の TOP パス |
| Active | On | 解析の有効/無効 |
| Max Faces | 5 | 検出する顔の最大数（**1〜100**・スライダー表示は10まで） |
| All Landmark Points (85) | Off | 全85点を p0..p84 として出力（チャンネル数が増える） |
| Flip Image Vertically | **On** | TD の TOP ダウンロードは上下逆のため既定 On |

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

### ランドマークの並び（p0..p84）

`allPoints` の生の並びは描画に使えないため、**領域ごとに詰め直して**出力している。
連番で結べば輪郭・目・眉・唇がそのまま線になる（鼻だけは後述の注意あり）。

| 範囲 | 領域 | 点数 | 閉じる |
|---|---|---|---|
| 0-16 | faceContour（輪郭） | 17 | 開 |
| 17-22 / 23-28 | leftEye / rightEye | 6 / 6 | 閉 |
| 29-34 / 35-40 | leftEyebrow / rightEyebrow | 6 / 6 | 開 |
| 41-48 | nose | 8 | 開 |
| 49-54 | noseCrest | 6 | 開 |
| 55-64 | medianLine | 10 | 開 |
| 65-78 | outerLips | 14 | 閉 |
| 79-84 | innerLips | 6 | 閉 |

点数は macOS 26 実測（12顔×複数フレーム=288サンプルで一定）。合計 **85点**。
`allPoints` が 76 しか返さないのは **medianLine が他領域と重複している**ため。

未使用スロットは `u = v = -1` の番兵なので、描画側でスキップする。

**鼻は連番で結ぶと左右非対称に見える。** Vision の並びがそうなっているためで、
プラグインのパッキングの問題ではない（複数の顔で同じ構造を確認済み）:

| 症状 | 実データ | 描き方 |
|---|---|---|
| 正中から左の小鼻へ長い斜線が出る | `nose` の `p41` は鼻筋の下端（正中）で、`p42` でいきなり左の小鼻へ飛ぶ | 小鼻の掃引は **`p42` から**始める |
| 鼻筋の下に片側だけ突起が出る | `noseCrest` は `49→52` が鼻筋の直線、**`p53` / `p54` は左右の小鼻**（同じ高さの対） | 鼻筋 **`49-52`** と 小鼻の横棒 **`53-54`** を分けて描く |
| 鼻筋が二重線になる | `medianLine`(55-64) は眉間〜顎の正中線で、鼻筋・鼻・輪郭の点と重複する | `medianLine` は描かない |

`demo.toe` の `VisionFace/geo2/contour` はこの方針で組んである（実装例）。

> **以前は輪郭を16点で確保していたため17点目が落ち、片側だけ短く終わって左右非対称に
> 見えていた**（v0.9.2 以前）。確保数を実測より小さくすると末尾が黙って切り捨てられる。
> 「使用スロット数を数える」検証では**不足しか分からず超過は見えない**ので、
> 領域の `pointCount` を直接計測すること。

### 注意

- **Face Capture Quality**(トグル・既定Off): Onで `face{i}/quality`(0〜1の顔写り
  スコア・VNDetectFaceCaptureQualityRequest)が roll/yaw/pitch の後に追加される。
  フォトブースの「ベスト表情自動選択」に。Offなら従来とチャンネル互換

- 顔が小さい（引きの全身ショット等）と検出が不安定。バストアップ程度の画角が確実
- **絵に描かれた顔（Tシャツのプリント等）も顔として検出しうる**（Vision の仕様）
- 実測: 顔写真で bbox・目/鼻/口の位置関係が正しく出力されることを確認

Info CHOP: `executes / submits / analyzes`。ビルドは `./build.sh`。
