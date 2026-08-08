# Vision Face CHOP — 顔検出+ランドマーク（macOS）

TOP の映像から複数の顔（`VNDetectFaceLandmarksRequest`）を検出する
TD ネイティブのカスタム CHOP。Windows+NVIDIA 専用 Face Track CHOP の macOS 代替を想定
（チャンネル形式は独自）。

## 出力チャンネル（Max Faces = N・各 16ch / Landmarks 有効時 168ch）

| チャンネル | 内容 |
|---|---|
| `face{i}:valid` | 検出できたか（1/0） |
| `face{i}/bbox:u,v,width,height` | 顔バウンディングボックス（中心+サイズ・0〜1） |
| `face{i}/roll` `yaw` `pitch` | 顔の向き（ラジアン。**取得できない軸は 0**） |
| `face{i}/left_eye:u,v` `right_eye` `nose` `mouth` | 主要ランドマークの中心（画像正規化座標） |
| `face{i}/p{0..84}:u,v` | Landmarks オン時のみ・全85ランドマーク点。**領域ごとに、その領域内の正しい順序**で並ぶので連番で結べば輪郭が描ける |

face の並びは bbox 中心の x で左→右にソート。

## パラメータ

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


### ランドマークの並び（p0..p75）

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

`demo.toe` の `VisionFace/geo2/contour` はこの方針で組んである。

> **以前は輪郭を16点で確保していたため17点目が落ち、片側だけ短く終わって左右非対称に
> 見えていた**（v0.9.2 以前）。確保数を実測より小さくすると末尾が黙って切り捨てられる。
> 「使用スロット数を数える」検証では**不足しか分からず超過は見えない**ので、
> 領域の `pointCount` を直接計測すること。

`demo.toe` の Vision Face 例（`geo2/contour`）が実装例。

## 注意

- **Face Capture Quality**(トグル・既定Off): Onで `face{i}/quality`(0〜1の顔写り
  スコア・VNDetectFaceCaptureQualityRequest)が roll/yaw/pitch の後に追加される。
  フォトブースの「ベスト表情自動選択」に。Offなら従来とチャンネル互換

- 顔が小さい（引きの全身ショット等）と検出が不安定。バストアップ程度の画角が確実
- **絵に描かれた顔（Tシャツのプリント等）も顔として検出しうる**（Vision の仕様）
- 実測: 顔写真で bbox・目/鼻/口の位置関係が正しく出力されることを確認

Info CHOP: `executes / submits / analyzes`。ビルドは `./build.sh`。
