# CoreImage RAW TOP

**English** | [日本語](#日本語)

## English

Develops DNG / Apple ProRAW / camera RAW **in real time** with `CIRAWFilter` and outputs an
RGBA16Float TOP. Exposure, white balance, noise reduction, sharpness and contrast are adjustable.

- A file-input source TOP. Development runs on a worker thread and never blocks cook
- Output is **RGBA16Float** (extended linear sRGB), ready for TD's HDR / linear workflow
- Parameter changes are detected and trigger an automatic re-develop

### Measured (M2)

- **Verified on real ProRAW.** `Assets/sample_raw.DNG` (iPhone ProRAW, 4032x3024) ships with the
  repo, so the example works straight after cloning
- Opening it fills the parameters from the file: **Temperature 3374.6 K, Tint 12.07,
  Contrast 0.10**
- A full-size develop at Scale 1.0 takes about 10 s the first time on a 48 MP file; Scale 0.25 is
  light
- **The output used to be broken (fixed).** `[CIContext render:...]` was told `kCIFormatRGBA16`
  (**16-bit unsigned integer**) while the TOP was declared `RGBA16Float` (**half float**). The bits
  were reinterpreted, giving NaN and values like -4696 on a real RAW — the image came out white.
  `kCIFormatRGBAh` is the matching pair. **A non-RAW JPEG hides this; it only showed up once a real
  RAW went in**
- `CIRAWFilter` also accepts JPEG/TIFF, but a non-RAW input is developed as if it were sensor data
  (it blows out), so it cannot be used to judge the result

### Output

- TOP: **RGBA16Float**, in the space chosen by Output Color Space (sRGB by default)
- Info CHOP: `executes / submits / develops / valid`

### Parameters

| Parameter | Description |
|---|---|
| RAW File | DNG / ProRAW / camera RAW file |
| Exposure (EV) | Exposure compensation |
| Boost | Shadow/tone boost (0 = linear, 1 = standard) |
| Reload Settings From File | Pull the file's own settings into the parameters again, discarding your edits |
| Output Color Space | sRGB (default) / Display P3 / Adobe RGB / Linear sRGB |
| Neutral Temperature (K) | White balance colour temperature. Filled in from the file |
| Neutral Tint | White balance tint correction. Filled in from the file |
| Luminance Noise Reduction | Luminance noise reduction (supported RAW only) |
| Color Noise Reduction | Colour noise reduction (supported RAW only) |
| Sharpness | Sharpness (supported RAW only) |
| Contrast | Contrast |
| Scale Factor | Decode resolution scale (0.1–1.0, to reduce load) |
| Flip Vertically | Flip the output vertically (default On) |

### Matching what Preview shows

The develop defaults now land on Apple's own decode. Measured on an iPhone ProRAW DNG, mean RGB
over the frame, against a PNG exported from Preview:

| | mean RGB | \|Δ\| vs Preview |
|---|---|---|
| Before 0.9.7 (white balance forced to 6500 K, linear output) | 0.886 / 0.517 / **0.056** | 0.263 |
| The file's own settings + sRGB (current default) | 0.673 / 0.594 / 0.448 | 0.108 |
| ImageIO's own default decode | 0.672 / 0.593 / 0.451 | 0.107 |
| The camera's embedded preview in the DNG | 0.666 / 0.584 / 0.423 | 0.122 |
| Preview's PNG export | 0.784 / 0.700 / 0.552 | — |

Two things were wrong. The sliders **overwrote the file's as-shot white balance** (3375 K / tint
12.07 on that file) with a fixed 6500 K, which crushed blue to 0.056 — that is the colour cast you
see. And the result was written in **linear** light, which TD displays as-is, so the midtones sank.

**Opening a file now loads that file's own settings into the parameters** — white balance,
contrast, noise reduction and sharpness — so the sliders start where the camera left them and you
edit from there. Nothing is hidden behind a toggle. Use **Reload Settings From File** to go back to
the file's values after editing.

The current default now agrees with ImageIO's decode to within \|Δ\| = 0.009. **Preview's export is
the outlier**: it is about +0.55 EV brighter than every Apple RAW path, including the camera's own
embedded preview. Applying the file's HDR gain map does not explain it — `expandToHDR` and
`CIToneMapHeadroom` both come out *darker*, not brighter. If you want that brighter look, set
**Exposure to about +0.55**; that brings \|Δ\| down to 0.033.

### Notes

- Under **TouchDesigner Non-Commercial** the resolution is capped at 1280x1280. Output above the
  cap is **scaled down automatically** with a warning (without it TD renders garbage). Use a
  commercial license if you need full resolution.

- Supported formats are whatever RAW macOS understands (vendor DNG, Apple ProRAW, …). A file for
  which `filterWithImageURL` returns nil shows `Not a supported RAW file`
- Some RAW files do not support noise reduction or sharpness; those parameters are then ignored
  (each `*Supported` flag is checked before applying)

### Build

```
cd CoreImageRAW && ./build.sh   # → build/CoreImageRAWTOP.plugin
```

## 日本語

DNG / Apple ProRAW / カメラRAW を `CIRAWFilter` で**リアルタイム現像**し、RGBA16Float TOP として
出力する。露出・ホワイトバランス・ノイズ除去・シャープネス・コントラストを調整できる。

- ファイル入力のソースTOP。現像はワーカースレッドで行い cook をブロックしない
- 出力は **RGBA16Float**(拡張リニアsRGB)。TDのHDR/リニアワークフローに直結
- パラメータ変更を検知して自動で再現像

### 実測(M2)

- **実 ProRAW で確認済み**。`Assets/sample_raw.DNG`(iPhone ProRAW・4032x3024)を同梱しているので、
  clone した直後から利用例が動く
- 開くとパラメータがファイルの値で埋まる: **Temperature 3374.6K / Tint 12.07 / Contrast 0.10**
- Scale=1.0 のフル現像は 48MP で初回に約10秒。Scale=0.25 なら軽い
- **かつて出力が壊れていた(修正済み)**: `[CIContext render:...]` の format が
  `kCIFormatRGBA16`(**16bit符号なし整数**)なのに、TOP へは `RGBA16Float`(**半精度浮動小数**)として
  上げていた。ビット列が別物として解釈され、実RAWで NaN や -4696 のような値になっていた
  (画面は真っ白)。`kCIFormatRGBAh` に修正。**非RAWのJPEG等では気づきにくく、実RAWを入れて初めて
  露見した**
- CIRAWFilter は JPEG/TIFF も受け付けるが、非RAW入力はセンサーデータ前提の現像とずれる
  (白飛びする)ため視覚評価には使えない

### Apply EXIF Orientation

既定 On。撮影時のカメラの向き(EXIF Orientation)を反映する。`CIRAWFilter.orientation` は
既定でファイルの値を持っているので、**Off にしたときだけ** `.up` にしてセンサーそのままの
向きで出す。実測(iPhone ProRAW・orientation=3): On で正立、Off で180度反転。

### 出力仕様

- TOP: **RGBA16Float**。色空間は Output Color Space で選ぶ(既定 sRGB)
- Info CHOP: `executes / submits / develops / valid`

### パラメータ

| パラメータ | 説明 |
|---|---|
| RAW File | DNG / ProRAW / カメラRAW ファイル |
| Exposure (EV) | 露出補正 |
| Boost | シャドウ/トーンのブースト(0=リニア, 1=標準) |
| Reload Settings From File | ファイル自身の設定をもう一度パラメータへ読み込む(編集内容は破棄) |
| Output Color Space | sRGB(既定)/ Display P3 / Adobe RGB / Linear sRGB |
| Neutral Temperature (K) | ホワイトバランス色温度。ファイルから流し込まれる |
| Neutral Tint | ホワイトバランスの色かぶり補正。ファイルから流し込まれる |
| Luminance Noise Reduction | 輝度ノイズ除去(対応RAWのみ) |
| Color Noise Reduction | 色ノイズ除去(対応RAWのみ) |
| Sharpness | シャープネス(対応RAWのみ) |
| Contrast | コントラスト |
| Scale Factor | デコード解像度スケール(0.1〜1.0。負荷軽減に) |
| Flip Vertically | 出力の上下反転(既定 On) |

### Preview の見え方と合わせる

現像の既定値が Apple 自身のデコードと一致するようになった。iPhone ProRAW の DNG で、
画面全体の平均RGBを Preview から書き出した PNG と比較した実測:

| | 平均RGB | \|Δ\| vs Preview |
|---|---|---|
| 0.9.7 より前(WBを6500Kに強制・linear出力) | 0.886 / 0.517 / **0.056** | 0.263 |
| ファイル自身の設定 + sRGB(現在の既定) | 0.673 / 0.594 / 0.448 | 0.108 |
| ImageIO の既定デコード | 0.672 / 0.593 / 0.451 | 0.107 |
| DNG に埋め込まれたカメラ自身のプレビュー | 0.666 / 0.584 / 0.423 | 0.122 |
| Preview の書き出しPNG | 0.784 / 0.700 / 0.552 | — |

原因は2つあった。スライダーが**ファイルの as-shot ホワイトバランス**(この個体は 3375K /
tint 12.07)を固定値 6500K で上書きしていたため青が 0.056 まで潰れており、これが色かぶりの正体。
もう1つは結果を**リニア光のまま**書いていたこと。TD は値をそのまま表示するので中間調が沈む。

**ファイルを開くと、そのファイルが持っている設定がパラメータに入る**ようになった
(ホワイトバランス・コントラスト・ノイズ除去・シャープネス)。撮影時の値からスライダーが始まるので、
そこから編集すればよい。トグルの裏に隠れる値は無い。編集後にファイルの値へ戻したいときは
**Reload Settings From File** を押す。

現在の既定は ImageIO のデコードと \|Δ\| = 0.009 まで一致する。**外れているのは Preview の方**で、
カメラ自身の埋め込みプレビューを含む Apple のどの経路よりも約 +0.55 EV 明るい。HDRゲインマップを
当てても説明できない(`expandToHDR` も `CIToneMapHeadroom` も**逆に暗くなる**)。
Preview の明るさに寄せたいときは **Exposure を +0.55 前後**にする(\|Δ\| = 0.033 まで縮む)。

### 注意

- **TouchDesigner Non-Commercial** では解像度が 1280x1280 に制限される。上限を超える出力は**自動で上限内へ縮小**し、その旨を警告に出す(縮小しないと TD 側で絵が崩れるため)。フル解像度が要るなら商用ライセンスを使う

- 対応形式は macOS が解釈できる RAW(各社DNG・Apple ProRAW 等)。`filterWithImageURL` が nil を返す
  ファイルは `Not a supported RAW file` を表示
- ノイズ除去/シャープネスは RAW によって非対応の場合があり、その場合は該当パラメータを無視する
  (`*Supported` を確認してから適用)

### ビルド

```
cd CoreImageRAW && ./build.sh   # → build/CoreImageRAWTOP.plugin
```
