# 配線ルールと定番レシピ

全て `demo.toe` の利用例で実際に動いている型。

## cook を回す

全OPが `cookEveryFrameIfAsked`。**出力が誰にも使われていないと cook されない**。
「動かない」「値が更新されない」の大半はこれ。

- **一番簡単**: 下流に Null を置いてビューアをアクティブにする
- **確実**: Execute DAT の `onFrameEnd` で毎フレーム明示的に cook する

```python
# execute DAT の onFrameEnd
def onFrameEnd(frame):
    op('/project1/mychain/classify').cook(force=True)
    return
```

**非同期C++ DATの更新を DAT Execute の `onTableChange` で拾おうとしない。**
安定して発火しない。Execute DAT の `onFrameEnd` でポーリングするほうが確実
(LLM AFM のツール往復、Vision Classify → LLM のキャプション生成で実際に踏んだ)。

連続フレームが前提のOP(**Vision Track / Vision Trajectory**)は特に重要。
間隔を空けた force cook では絶対に成立しない。

## Info CHOP を読む

全OPが診断チャンネルを出す。代表は `executes / submits / analyzes / analyze_ms`。

- `analyzes` が `executes` に追従している → フレーム落ちなし
- `analyzes` が伸びない → 入力が更新されていないか、Active が Off
- `analyze_ms` → 1推論あたりの実測ミリ秒。重いOPを並べる前にここを見る

Cinematic Video / Spatial Video / PDFKit は **Info DAT トグルを On** にすると
隣に Info DAT が自動生成される。CoreWLAN Scan は配置しただけで Callbacks DAT が
ドックチップとして自動接続される。

## Flip

`Flip Image Vertically` は **Vision / Core ML など「意味を読む」系だけ**にあり、**既定 On が正しい**。
TDのテクスチャは bottom-up なので、Off にすると Vision が検出0になる。

向きに依存しない幾何変換系(Metal Upscale / Metal FrameInterp)は、そもそもこのパラメータを持たない。

## Aspect Correct UVs → Ortho Width = 1 で映像に重ねる

uv を出すVision系OP(Pose / Hand / Face / AnimalPose / Pose3D / Track / Rect /
Trajectory / Text、CoreML DAT、Vision Barcode)が持つ。TD標準 Body Track CHOP の
同名パラメータと同じ役割・同じ既定値(**Off**)。

```
aspect = 入力幅 / 入力高さ
u' = u                          （0〜1 のまま）
v' = 0.5 + (v - 0.5) / aspect   （中心を保って 1/aspect に縮小）
```

`u` が 0〜1 のままなので、**On にすると `tx = u-0.5` / `ty = v-0.5` のインスタンシングが
カメラの Ortho Width = 1 のままぴったり重なる**(手動スケール不要)。

生の 0〜1 画像座標が欲しいとき(Crop TOP に渡す等)は Off のまま。
**Vision Saliency は意図的に非対応** — あのuvは Crop TOP 直結前提で生座標である必要がある。

### 点を打つ

1. Vision Pose CHOP の全 `u`/`v` を **Shuffle CHOP の `Sequence All Channels`** で
   「N個の1サンプルch → 1chのNサンプル」に変換(tx用・ty用の2本)
2. Geometry COMP のインスタンシングに tx/ty を割り当て、`-0.5` する
3. Camera を **Ortho・Ortho Width = 1**
4. Render → 元映像と Composite

## 骨格線を引く(Script SOP)

点だけでなく関節を線で結ぶ型。demo.toe の VisionPose / VisionHand / VisionFace /
VisionAnimalPose で動いている。

```
Script SOP(骨を生成) → soptoPOP → outPOP → Geometry COMP → Render
```

**踏みやすい罠が4つある**:

1. **outPOP の render / display フラグを立てる。** 立てないと何も描かれない
   (このTDは POP 世代で、Geometry COMP は POP を描く)
2. **Script SOP は入力が無いと毎フレーム cook しない。**
   custom par `Trigger` を作り、式に `op('../Visionpose1').totalCooks` を入れて dirty にする
3. **ポリゴンは `appendPoly(2, addPoints=False, closed=False)` → `poly[0].point = pa`。**
   `appendPoly(0, ...)` + `line.append()` では1本しか生成されない
4. **script で作った Geometry COMP には既定の `torus1` が入る。** 消さないと画面いっぱいの塗りになる

線が細くて見えないときは Constant MAT の **Wire Width**(既定1px)を上げる。

### Vision の関節名の `top` / `bottom` は「先端 / 付け根」

画面の上下ではない。実測で確認済み:

| 関節 | 意味 |
|---|---|
| `ear_top` / `ear_bottom` | 耳の**先端** / 頭に付く**付け根** |
| `tail_top` / `tail_bottom` | 尻尾の**先端** / 腰に付く**付け根** |

背骨を `neck → tail_top` で結ぶと、尻尾を立てた猫で**首から尻尾の先まで空中を横切る線**になる。
正しくは `neck → tail_bottom`(腰)で、後脚も `tail_bottom` から生やす。

### Vision Face のランドマークの並び

`p0..p75` は**領域ごとに、その領域内の正しい順序**で並ぶので連番で結べば輪郭が描ける。
未使用スロットは `u = v = -1` の番兵なので、描画側でスキップすること
(0のままだと bbox の隅に線が飛ぶ)。範囲は VisionFace/README.md の表を参照。

## マスクを合成する(CoreML SAM2 等)

1. マスクは正方形なので **Fit TOP を `fill`(stretch)** で入力アスペクトに合わせる
2. sigmoid ソフトマスクは背景に中間値が残るので **Threshold TOP(0.5)** を挟む
3. Composite(multiply)は **出力formatを rgba8fixed に固定**
   (Mono32Float 入力に引っ張られてモノクロ化する)

## 検出した四隅に画像を貼り込む(corner pin)

Vision Rect の `tl/tr/br/bl` へ別の映像を射影変換で貼る。実例は demo.toe の
`/project1/VisionRect`(ノートPCの画面2枚に映像を流し込む)。

- **Aspect Correct UVs は Off**。TOP空間のワープには**生の 0〜1 画像座標**が要る
  (On にすると v が縮んで貼り込み位置がずれる)
- CHOP を GLSL に渡すときは **Shuffle CHOP の `Sequence All Channels`** で
  `Nch × 1sample` → `1ch × Nsample` にしてから GLSL TOP の
  **Array(texture buffer)** へ。`texelFetch(uRects, i).r` で任意チャンネルを引ける。
  **CHOPをそのまま texture buffer に繋ぐと texel 数 = サンプル数**になり、
  1サンプルのCHOPでは 1 texel しか渡らない(必ず shuffle する)
- 矩形数はシェーダ側で `textureSize(uRects) / 14` から決めれば `Max Rectangles` を
  変えても壊れない(1矩形 = 14ch)
- 貼り込みは**逆変換**で行う。単位正方形 → 四隅 の射影変換 M を作り、
  出力画素 uv に `inverse(M)` を掛けて貼り込む画像側の st を求め、
  `0..1` の内側だけ合成する
- 検出は非同期なので、カメラが速く動くと貼り込みが**1〜2フレーム遅れる**

## Vision Flow が黒く見えるとき

プラグインは正常。原因は2つ:

- **入力が静止している**。静止画は1フレームしか来ずフロー未計算 = 常に黒
- **UVモード既定は解像度で正規化するので値が極小**。肉眼では黒に見える

`Output` を **`visualize`** にすると、向き=色相 / 速さ=明るさ の RGBA8 で
増幅ノード無しにそのまま見える。生値が要るなら `flow` のまま Math TOP で×20〜50する。

## 音声系

- 音を**生成して出す**CHOP(Speech Synth 等)は実時間ペースで出る。固定ブロックで読み出す
  設計にすると早送りノイズになる(プラグイン側で対処済み)
- **Speech Text / Translate は出力が使われていないと進まない**。「認識されない」「翻訳されない」に
  見えたら、まず cook が回っているかを確認する

## LLM 系

- **LLM MLX の `Model` パラメータを Expression モードにするなら文字列をクォートする。**
  裸で `gemma-3-4b-it-qat-4bit` と書くと Python が数式として解釈し
  `SyntaxError: invalid decimal literal` になる。ローカルフォルダ指定なら
  `project.folder + '/models/gemma-3-4b-it-qat-4bit'`
- **Info DAT を必ず隣に置く。** `status` が `loading model` か `ready` か見えないと
  「動いていない」のか「ロード中」なのか判別できない(初回は数十秒かかる)
- **LLM AFM のツール呼び出しは、プロンプトでツール名を明示する。** オンデバイスモデルは小さく、
  曖昧な聞き方だとツールを使わず「センサーがありません」と答える
