# Vision Rect CHOP

Apple Visionで映像内の投影矩形を複数検出するCHOP。紙、カード、画面、看板などの
コーナーピン、射影補正、領域選択に使える。macOS 10.14以降。

各`rect{i}`に`valid / confidence / bbox:u,v,w,h / tl:u,v / tr:u,v / br:u,v / bl:u,v`
の14チャンネルを出力する。座標は0〜1・左下原点、複数矩形は中心uの左→右順。

| パラメータ | 内容 |
|---|---|
| TOP | 入力TOP |
| Active | 検出On/Off |
| Max Rectangles | 最大100、既定10 |
| Minimum/Maximum Aspect Ratio | 短辺÷長辺の範囲（0〜1） |
| Minimum Size | 画像短辺に対する最小辺比率 |
| Minimum Confidence | 最低信頼度 |
| Quadrature Tolerance | 直角から許容する角度（0〜45度） |
| Flip Image Vertically | 既定On |

Info CHOPは`executes/submits/analyzes/analyze_ms/rects`。推論は非同期で、静止画も
処理パラメータ変更時に再解析する。


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

### 四隅に画像を貼り込む（corner pin）

`tl/tr/br/bl` を使って、検出した矩形へ別の映像を射影変換で貼り込める。
実例は `demo.toe` の `/project1/VisionRect`（ノートPCの画面2枚に映像を流し込む）。

構成は `元映像 → Vision Rect → Shuffle(Sequence All Channels) → GLSL TOP` で、
GLSL TOP の入力0が元映像、入力1が貼り込む画像。

| 注意 | 内容 |
|---|---|
| Aspect Correct UVs | **Off**。TOP空間のワープには生の 0〜1 画像座標が要る（Onだと v が縮んで位置がずれる） |
| CHOP の渡し方 | Shuffle CHOP の `Sequence All Channels` で `Nch×1sample` → `1ch×Nsample` にしてから GLSL の Array（texture buffer）へ。CHOPを直接繋ぐと **texel数=サンプル数**になり1 texel しか渡らない |
| 矩形数 | シェーダ側で `textureSize(uRects) / 14` から求めれば Max Rectangles を変えても壊れない |
| 遅れ | 検出は非同期なので、カメラが速く動くと貼り込みが1〜2フレーム遅れる |
| 誤検出 | キーボード面などが拾われるときは `Maximum Aspect Ratio` を下げる（実例では 0.8） |

貼り込みは逆変換で行う。単位正方形 → 四隅 の射影変換 `M` を作り、出力画素 `uv` に
`inverse(M)` を掛けて貼り込む画像側の `st` を求め、`0〜1` の内側だけ合成する。

## ビルド

```sh
cd VisionRect && ./build.sh
```
