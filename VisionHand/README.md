# Vision Hand CHOP — hand tracking (macOS)

**English** | [日本語](#日本語)

## English

A TD-native custom CHOP that estimates the **21 joints** of multiple hands
(`VNDetectHumanHandPoseRequest`) from a TOP's image, with left/right (chirality) detection.

### Output channels (hand1..handN for Max Hands = N, 65 channels each)

| Channel | Description |
|---|---|
| `hand{i}:valid` | Whether a hand was detected (1/0) |
| `hand{i}/chirality` | **-1 = left / 1 = right / 0 = unknown** (which hand it is in the image) |
| `hand{i}/{joint}:u,v,confidence` | 21 joints (0–1, bottom-left origin) |

The 21 joints are `wrist` plus four points per finger:
`thumb_cmc/mp/ip/tip` `index_mcp/pip/dip/tip` `middle_*` `ring_*` `little_*`

Hands are sorted left to right by the wrist's x.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| TOP | — | Path of the TOP to analyse |
| Active | On | Enable/disable analysis |
| Max Hands | 4 | Maximum hands to detect (**1–100**; the slider shows up to 10. More costs more inference) |
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

### Notes

- Hands that are too small in frame are not detected (a wide shot of five full bodies is hard).
  Use a framing that shows the hands, or crop in with a Crop TOP first
- Measured: both hands detected from a live camera with correct chirality (two hands holding a
  phone → right and left correctly identified)

Info CHOP: `executes / submits / analyzes`. Build with `./build.sh`.

## 日本語

TOP の映像から複数の手の**21関節**（`VNDetectHumanHandPoseRequest`）を推定する
TD ネイティブのカスタム CHOP。左右の判定（chirality）つき。

### 出力チャンネル（Max Hands = N で hand1..handN・各 65ch）

| チャンネル | 内容 |
|---|---|
| `hand{i}:valid` | 検出できたか（1/0） |
| `hand{i}/chirality` | **-1=左手 / 1=右手 / 0=不明**（映像に映った手の左右） |
| `hand{i}/{joint}:u,v,confidence` | 21関節（0〜1・左下原点） |

21関節: `wrist` + 各指4点
`thumb_cmc/mp/ip/tip` `index_mcp/pip/dip/tip` `middle_*` `ring_*` `little_*`

hand の並びは手首の x で左→右にソート。

### パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| TOP | — | 解析する映像の TOP パス |
| Active | On | 解析の有効/無効 |
| Max Hands | 4 | 検出する手の最大数（**1〜100**・スライダー表示は10まで。増やすほど推論コスト増） |
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

### 注意

- 手が映像内で小さすぎると検出されない（引きの全身5人などでは困難）。
  手元が映る画角か、Crop TOP で寄せてから入力するのが確実
- 実測: ライブカメラの両手を chirality 込みで検出（スマホを持つ両手 → 右手/左手を正しく判定）

Info CHOP: `executes / submits / analyzes`。ビルドは `./build.sh`。
