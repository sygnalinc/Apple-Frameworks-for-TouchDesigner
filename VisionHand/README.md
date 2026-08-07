# Vision Hand CHOP — 手指トラッキング（macOS）

TOP の映像から複数の手の**21関節**（`VNDetectHumanHandPoseRequest`）を推定する
TD ネイティブのカスタム CHOP。左右の判定（chirality）つき。

## 出力チャンネル（Max Hands = N で hand1..handN・各 65ch）

| チャンネル | 内容 |
|---|---|
| `hand{i}:valid` | 検出できたか（1/0） |
| `hand{i}/chirality` | **-1=左手 / 1=右手 / 0=不明**（映像に映った手の左右） |
| `hand{i}/{joint}:u,v,confidence` | 21関節（0〜1・左下原点） |

21関節: `wrist` + 各指4点
`thumb_cmc/mp/ip/tip` `index_mcp/pip/dip/tip` `middle_*` `ring_*` `little_*`

hand の並びは手首の x で左→右にソート。

## パラメータ

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

## 注意

- 手が映像内で小さすぎると検出されない（引きの全身5人などでは困難）。
  手元が映る画角か、Crop TOP で寄せてから入力するのが確実
- 実測: ライブカメラの両手を chirality 込みで検出（スマホを持つ両手 → 右手/左手を正しく判定）

Info CHOP: `executes / submits / analyzes`。ビルドは `./build.sh`。
