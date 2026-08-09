# Vision Saliency TOP — saliency map + auto framing (macOS)

**English** | [日本語](#日本語)

## English

A TD-native custom TOP that generates a **saliency heat map** of "what draws the eye" from the
input TOP, and alongside it outputs attention regions, a gaze centroid and a suggested crop
rectangle as channels — **directly usable for auto-crop, auto-framing and automated camera work**.

### Modes

| Mode | API | Meaning |
|---|---|---|
| **Attention** | VNGenerateAttentionBasedSaliencyImageRequest | Where a human eye naturally goes (faces, high contrast…) |
| **Objectness** | VNGenerateObjectnessBasedSaliencyImageRequest | Where foreground objects are likely to be (good for cutting out a subject) |

### Output

**TOP**: the saliency heat map (Mono32Float, 68x68 native resolution, 0–1)

**Info CHOP channels** (attach an Info CHOP to read them; coordinates are 0–1, bottom-left origin):

| Channel | Description |
|---|---|
| `regions` | Number of attention regions (up to 3) |
| `region{1..3}_u,v,width,height` | Bounding box of each attention region (centre + size) |
| `focus_u`, `focus_v` | Gaze centroid weighted by saliency (smoothed) |
| `frame_u,v,width,height` | **Suggested crop rectangle** (reflects the parameters below, smoothed, clamped to the frame) |

### Auto-framing recipe

Just write expressions on a Crop TOP's parameters:

```python
cropleft   = op('sal_info')['frame_u'] - op('sal_info')['frame_width']/2
cropright  = op('sal_info')['frame_u'] + op('sal_info')['frame_width']/2
cropbottom = op('sal_info')['frame_v'] - op('sal_info')['frame_height']/2
croptop    = op('sal_info')['frame_v'] + op('sal_info')['frame_height']/2
```

Measured: on footage of a five-piece band, with Aspect = 1.778 (16:9) it automatically tracks a
frame that keeps everyone in shot with margin. For a zoom effect you can also map `frame_*` onto a
Transform TOP's scale and position. `focus_u/v` is "the single point where attention gathers",
which suits spawning effects.

### Parameters

| Parameter | Default | Description |
|---|---|---|
| Active | On | Enable/disable inference |
| Mode | Attention | Switches the mode above |
| Frame Padding | 1.2 | Margin multiplier applied to the box around the attention regions |
| Frame Aspect (W/H, 0=Free) | 0 | Lock the crop rectangle's aspect ratio (e.g. 1.778 = 16:9; 0 = free) |
| Frame Smoothing | 0.7 | EMA smoothing of frame/focus (higher follows more slowly, for smoother camera work) |
| Flip Image Vertically | **On** | TD's TOP download is upside down (bottom-up), so this defaults to On |

On frames with no attention region, frame drifts back to the full screen (0.5, 0.5, 1, 1).

The Info CHOP ends with `executes / analyzes` for diagnostics.

Note: this operator deliberately has **no Aspect Correct UVs** — its uv output is meant to be fed
straight to a Crop TOP, which needs the raw 0–1 image coordinates.

### Build

```
./build.sh    # → build/VisionSaliencyTOP.plugin
```

For how to load it, see the [root README](../README.md) (a CPlusPlus TOP, or the Plugins folder).

## 日本語

入力 TOP の映像から「どこが目を引くか」の**顕著性ヒートマップ**を生成し、あわせて
**オートクロップ / オートフレーミング / カメラワーク自動化にそのまま使える**注目領域・
視線重心・おすすめクロップ矩形をチャンネル出力する TD ネイティブのカスタム TOP。

### モード（切替可能）

| Mode | 使用API | 意味 |
|---|---|---|
| **Attention（視線）** | VNGenerateAttentionBasedSaliencyImageRequest | 人間の視線が自然に向かう場所（顔・高コントラスト等） |
| **Objectness（物体）** | VNGenerateObjectnessBasedSaliencyImageRequest | 前景の物体がありそうな場所（被写体の切り出し向き） |

### 出力

**TOP**: 顕著性ヒートマップ（Mono32Float・68x68 ネイティブ解像度・0〜1）

**Info CHOP チャンネル**（Info CHOP を接続して取り出す・座標は 0〜1・左下原点）:

| チャンネル | 内容 |
|---|---|
| `regions` | 注目領域の数（最大3） |
| `region{1..3}_u,v,width,height` | 各注目領域のバウンディングボックス（中心+サイズ） |
| `focus_u`, `focus_v` | 顕著性で重み付けした視線の重心（スムージング済み） |
| `frame_u,v,width,height` | **おすすめクロップ矩形**（下記パラメータ反映・スムージング済み・画面内クランプ済み） |

### オートフレーミングのレシピ

Crop TOP のパラメータに式を書くだけ:

```python
cropleft   = op('sal_info')['frame_u'] - op('sal_info')['frame_width']/2
cropright  = op('sal_info')['frame_u'] + op('sal_info')['frame_width']/2
cropbottom = op('sal_info')['frame_v'] - op('sal_info')['frame_height']/2
croptop    = op('sal_info')['frame_v'] + op('sal_info')['frame_height']/2
```

実測: 5人のバンド映像に対し、Aspect=1.778（16:9）で全員を余白付きに収めるフレームを
自動追従で切り出せる。ズーム演出なら `frame_*` を Transform TOP のスケール/位置に
写像してもよい。`focus_u/v` は「視線が集まる一点」なのでエフェクトの発生位置向き。

### パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| Active | On | 推論の有効/無効 |
| Mode | Attention | 上記モード切替 |
| Frame Padding | 1.2 | 注目領域の外接矩形に掛ける余白倍率 |
| Frame Aspect (W/H, 0=Free) | 0 | クロップ矩形の縦横比を固定（例 1.778=16:9。0 なら自由） |
| Frame Smoothing | 0.7 | frame/focus の EMA 平滑（大きいほどゆっくり追従・カメラワークが滑らか） |
| Flip Image Vertically | **On** | TD の TOP ダウンロードは上下逆（bottom-up）のため既定 On |

注目領域が無いフレームでは frame は全画面（0.5, 0.5, 1, 1）へ戻っていく。

Info CHOP 末尾に診断用 `executes / analyzes`。

補足: 本OPは**意図的に Aspect Correct UVs を持たない**。この uv は Crop TOP へ直接渡す前提で、
生の 0〜1 画像座標である必要があるため。

### ビルド

```
./build.sh    # → build/VisionSaliencyTOP.plugin
```

使い方は [ルート README](../README.md) 参照（CPlusPlus TOP でロード or Plugins フォルダへ）。
