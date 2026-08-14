# Vision Track CHOP

初期バウンディングボックスで指定した**任意のオブジェクト**を映像内で追跡する。
`VNTrackObjectRequest` + `VNSequenceRequestHandler`。人以外も追える点で
Blob Track TOP(Nvidia 専用)の代替に近い。

## 実測(M2・1280x720)

- 追跡 約3〜5ms/frame(60fps 余裕)。実写テクスチャのターゲットで
  平行移動に対し誤差 0.002uv 程度で追従(1〜2フレーム遅れ)

## 使い方

1. `TOP` に入力映像を指定
2. `Init Bbox Center / Size`(uv・中心+サイズ)で追跡対象を囲む
3. `Start Tracking` をパルス → 以降追従。見失ったら(valid=0)再度パルスで再シード

## 出力チャンネル

| チャンネル | 内容 |
|---|---|
| valid | 追跡中=1(見失う/停止中=0) |
| u, v | bbox 中心(uv・左下原点) |
| w, h | bbox サイズ(uv) |
| confidence | 追跡信頼度 0〜1 |

## パラメータ

| 名前 | 内容 |
|---|---|
| TOP | 入力 TOP |
| Init Bbox Center / Size | 追跡開始時の bbox(uv) |
| Start / Stop Tracking | 追跡の開始(再シード)/停止(パルス) |
| Tracking Level | Accurate(既定)/ Fast |
| Min Confidence | これ未満は valid=0(既定 0.3) |
| Flip Image Vertically | 入力の上下反転(既定On・必須) |

## Info CHOP

`executes / submits / analyzes / analyze_ms / seeds / losses`。
`losses` が増えたら追跡が切れた回数。切れた理由は node の警告文に出る。


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

## 注意

- **Revision1 を明示している**。Revision2(既定)は macOS 26 実測で
  "Internal error: unexpected tracked object bounding box size" を返して一切動かない
- テンプレート型トラッカーなので**無地・単色の被写体は苦手**(bbox が膨張しつつ漂流する)。
  テクスチャのある実物体はしっかり追う
- bbox はワーカー適用時(1フレーム後)の映像でシードされる。高速に動く対象は
  少し大きめの bbox で囲むとよい
- 追跡対象は1つ。複数対象は VisionPose(人)/ ノードを複数置く(物)で対応

## ビルド

```
cd VisionTrack && ./build.sh   # → build/VisionTrackCHOP.plugin
```
