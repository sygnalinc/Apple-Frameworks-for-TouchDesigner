# CoreText TOP

**English** | [日本語](#日本語)

## English

Draws text with Apple's text rendering stack (Core Text + Core Graphics). Aimed at **freer and
better-looking typography than TD's built-in Text TOP**.

### What it adds over the Text TOP

- **Fonts are picked from the standard macOS font panel** (pulse `Choose Font`, pick in the
  panel, and the result appears in the Font field). You can also **point at a font file
  (.ttf/.otf/.ttc) directly** — it does not have to be installed. The default is the SF system
  font. `Weight` is **continuous** from 100 to 900 (the `wght` axis of a variable font; without
  one, 600+ approximates Bold)
- **Shear (faux italic)**: `Shear X / Y` skews the font matrix. **Any typeface can be slanted by
  an arbitrary angle, including Japanese faces with no italic**, and the stroke, embolden and
  gradient all follow the deformation
- **Proportional metrics (palt)**: OpenType `'palt'` automatic kerning (the equivalent of CSS
  `font-feature-settings: 'palt'`). Gaps around 「」 and punctuation tighten up into proportional
  setting suited to headlines (works on fonts that support it, e.g. Hiragino)
- **Rich text (per-range styling)**: a Style DAT lets you **target a substring or an index range**
  and change its colour, size, weight, font, tracking and underline (headline + body, or a single
  emphasised word, in one node)
- **Ruby (furigana)**: **real ruby** via `CTRubyAnnotation` — above the line horizontally, to the
  right vertically
- **Shaped layout**: flow the text into a rectangle / circle / ellipse / rounded rect / polygon /
  **arbitrary path** (Core Text accepts any CGPath, not just rectangles). The path can come from a
  Table DAT with `u v` columns or **from a SOP via SOP to DAT** (edit the SOP and the layout
  follows live)
- **Colour emoji** 😀🎉 (Apple Color Emoji is drawn as-is)
- **Japanese vertical text**: right-to-left columns with correct vertical punctuation forms
- **High-quality AA**: subpixel positioning, ligatures (none/standard/all), tracking, line
  spacing, justification
- **Line breaking (Text Wrap)**: the equivalent of CSS `text-wrap`, with five modes including
  **Balance** (even line lengths) and **Pretty** (avoid one orphaned character/word on the last
  line)
- **Truncation**: when the text does not fit, **trim the tail / head / middle with `…`** (the
  equivalent of CSS `text-overflow: ellipsis`). Emoji and composed characters are never split
- **Gradient fill** (two colours + angle) / **stroke** (outer outline) / **drop shadow**
- **Line image (input 0)**: the input TOP's image is **laid under each line at that line's real
  position and width** (image underlines, highlighter markers, bands). Line metrics also come out
  on the Info CHOP / Info DAT so you can build your own decoration in TD
- Multi-line text comes from a **Text DAT** (the `Text DAT` parameter; cells are joined by
  newline/tab)

### Measured (M2)

- 1280×720, SF Weight 750, gradient + shadow + stroke: a parameter change shows up in 1–2 frames
  (asynchronous render)
- Vertical text (Hiragino Mincho, 28 characters), mixed emoji and explicit fonts
  (Hiragino/Helvetica etc.) verified visually

### Parameters

| Page | Parameter | Description |
|---|---|---|
| CoreText | Text / Text DAT | Text to draw. A DAT takes priority (for multi-line) |
| | Edit Text (live Text DAT) | **For live typing.** Pressing it creates and connects an editing Text DAT as a dock chip, and **every keystroke renders immediately** (the Text field only commits on Enter). **Does nothing if a Text DAT is already connected** (it never overwrites) |
| | Style DAT (rich text / ruby) | **Range style table** (below): rich text, ruby, vertical glyph forms |
| | Font | Shows what the font panel selected (PostScript name; can also be typed. Empty = SF) |
| | Font File | Point at a .ttf/.otf/.ttc directly (takes priority over Font; need not be installed) |
| | Choose Font (macOS Font Panel) | Opens the **standard macOS font panel**. The choice is written back to Font / Font Size |
| | Proportional Metrics (palt) | OpenType 'palt' automatic kerning (only on fonts that support it) |
| | Font Size / Weight / Italic | Size (px) / weight 100–900 (variable fonts) / italic (the typeface's real italic) |
| | Shear X / Shear Y (deg) | **Shear (faux italic).** Shearing the font matrix works **on any typeface**, including Japanese ones, at any angle. Stroke / embolden / gradient / shadow all follow |
| | Slant Axis (deg) | The `slnt` axis of a variable font (**only if the typeface has one** — the designer's real slant) |
| | Auto Fit Font Size | **Shrink until it fits the drawing area** (Font Size is the upper limit). With Word Wrap on, the size that fits when wrapped; off, the size that fits on one line. The size actually used is Info CHOP `fitted_size` |
| | Tracking / Line Height / Ligatures | Letter spacing (pt, -100 to 100 so glyphs can overlap) / line spacing multiplier (0+ — **the first baseline never moves at any value**; only the gaps stretch or shrink, and small values overlap the lines) / ligatures |
| | Horizontal/Vertical Align | Left / centre / right / justify, top / middle / bottom |
| | Vertical Text | Vertical writing (right-to-left columns) |
| | Text Wrap | Line breaking (CSS text-wrap equivalent): **Wrap** = wrap at the width / **No Wrap** = never break / **Balance** = even line lengths / **Pretty** = avoid an orphan on the last line / **Stable** = same as Wrap |
| | Truncate (overflow) | **What to do when it does not fit** (CSS `text-overflow: ellipsis` equivalent): Off (clip) / Tail / Head / Middle |
| | Ellipsis | Ellipsis string (default `…`; `...` or ` ▶` also fine) |
| | Layout Shape | Shape of the layout area: Rectangle / Ellipse / Rounded Rect / Polygon / Path DAT |
| | Polygon Sides / Corner Round / Polygon Rotate | Polygon side count / corner rounding (0-1) / polygon rotation (degrees) |
| | Path DAT (u v / SOP to DAT) | Point list for Shape = Path. Accepts `u v` (0–1) and **auto-detects the `P(0)` / `P(1)` columns of a SOP to DAT** (a header row is detected automatically) |
| | Normalize Path to Area | Fit the point cloud's bounding box to the area automatically (default On). **Lets you pass SOP units unchanged** |
| | Padding | Margin (px, all four sides) |
| | Padding Left / Right / Top / Bottom | **Extra amount per side** (px). Effective margin = `Padding` + that side's extra. Negative values make a side narrower than the shared value |
| Line Image | Enable Line Image (input 0) | **Lay input 0's image under each line** (underline, marker, band). Follows each line's real position and width |
| | Apply To | All Lines / First Line / Last Line |
| | Width | Text Width (exactly the line's glyph width) / Full Area Width |
| | Offset Below Baseline (px) | Offset downward from the baseline. **Negative overlaps the text** (marker style) |
| | Offset X (px) | Horizontal offset (positive = right, negative = left) |
| | Thickness (px) | Line height. **0 = keep the input image's aspect ratio** |
| | Extend Ends (px) | Extend both ends (negative shortens) |
| | Draw Over Text | On = draw above the glyphs (default is below) |
| Style | Font Color / Background Color | Text colour / background colour (transparent by default) |
| | Embolden (px) | **Synthetic bold**: mask dilation makes the text heavier than the font's maximum weight (combines with gradient and stroke). **Closed counters (the hole in o or 口) are protected** and never fill in |
| | Gradient Fill / Color 2 / Angle | Gradient fill (Font Color → Color 2, angle 0° = top to bottom) |
| | Stroke Width / Color | Outline (outer, px) |
| | Drop Shadow / Color / Offset / Blur | Drop shadow |
| Common | Output Resolution | **Resolution is set on the Common page like any other TOP** (Custom etc.). Use Input falls back to 1280×720 |

Info CHOP: `executes / renders / width / height / lines / fitted_size / truncated` plus
**line metrics** `line{i}/u v w h baseline` (TD uv, 0–1, bottom-left origin; `v` = the line's
bottom, `baseline` = the baseline; 32 fixed slots). Info DAT: `resolved_font / lines` plus a
**one-row-per-text-line table of pixel values** (`x_px y_px w_px h_px baseline_px`). If a font
name cannot be resolved and a fallback is used, it is reported as a warning.

Line metrics let you build **per-line decoration in TD** beyond the line image (drive a Transform
TOP by expression for line boxes, per-line animation, …).

### Style DAT (rich text / ruby)

Put the column names in row 1; each following row is one range style. **Only the columns you
need** are required (blank cells inherit from the main parameters).

**Specifying the range** (either one):

| Column | Description |
|---|---|
| `text` | Applies to **every occurrence** of this substring (the easiest option) |
| `start` / `length` | By character index (**in composed characters**, so an emoji counts as one) |

**Style columns**:

| Column | Description |
|---|---|
| `r` `g` `b` `a` | Text colour (0–1) |
| `size` / `weight` / `italic` | Size (px) / weight (100–900) / italic (0/1) |
| `font` | Font name (PostScript or family name) |
| `tracking` | Letter spacing (pt) |
| `underline` | Underline (0/1) |
| `ruby` / `rubysize` | **Ruby (furigana)** / ruby's relative size (default 0.5) |
| `upright` | Glyph orientation in vertical text: `1` = upright (vertical form) / `0` = horizontal form (rotated 90°). Stands Latin text up or lays it down. **Typeface dependent** (works with SF + Latin; Japanese faces such as Hiragino keep digits' vertical form laid down, so nothing changes) |

Example (one word of the headline red and large, ruby over the kanji):

```
text    r    g    b    a   size  weight  ruby
夜景    0.9  0.2  0.2  1   150   900
漢字                                      かんじ
```

#### Using a SOP's shape

A TOP cannot take a SOP as a wired input, so put a **SOP to DAT** in between:

```
circle SOP → SOP to DAT (extract = points) → CoreText's Path DAT
```

The `P(0)` (x) and `P(1)` (y) columns are recognised automatically, and `Normalize Path to Area`
fits the points to the drawing area, so the SOP's coordinate scale does not matter. Edit the SOP
and the layout follows live.

### Notes and limitations

- Under **TouchDesigner Non-Commercial** the resolution is capped at 1280x1280. Output above the
  cap is **scaled down automatically** with a warning (without it TD renders garbage). Use a
  commercial license if you need full resolution.

- **Stroke and Embolden use mask dilation**, not the glyph outline path (extracting outlines from
  the system UI font demonstrably picks up garbage contours inside the TD process). Emoji get an
  outline too. Dilation only reaches **background that is reachable from the image edge**, so
  closed counters like o and 回 do not fill in (protected by a flood fill)
- **With a gradient, emoji become a gradient-filled silhouette** (the whole text is used as a mask
  for the fill). Turn the gradient off to keep colour emoji
- Vertical Align does not apply to vertical text (it lays out over the whole area). Justify is
  horizontal-only
- **Vertical Align has no effect on non-rectangular Layout Shapes** (the text flows from the top
  through the whole shape)
- **Tate-chu-yoko (horizontal digits inside vertical text) is not supported** — Core Text has no
  API for it. The `upright` column can only switch between standing up and lying down (and that
  is typeface dependent). For years and the like in vertical text, **kanji numerals** are the
  reliable choice (`令和八年`)
- A Style DAT `start`/`length` range shifts when truncation kicks in (a `text` range is searched
  against the truncated string, so it does not shift)
- Naming a font that cannot draw anything falls back (see the warning)
- **Shear, Italic and Slant Axis are three different things.** Italic switches to the typeface's
  real italic (no change if it has none); Slant Axis is the variable-font `slnt` axis (only if the
  typeface has one — SF does not); Shear is a geometric transform and works on anything. Shear
  does not change advance widths, so at steep angles glyphs crowd their neighbours (the usual
  oblique behaviour)
- **Truncate and Auto Fit are different strategies.** With Auto Fit on (shrink to show everything)
  the text almost always fits, so Truncate never fires. For "fixed size, elide the overflow", use
  Auto Fit off + Truncate
- Truncation finds the largest amount that fits by **binary search** (snapped to composed-character
  boundaries so emoji are never split). Info CHOP `truncated` (0/1) tells you whether it happened
- Margins are **`Padding` (all four sides) plus each side's extra**. Using `Padding` alone works
  exactly as before. Changing the margin also moves **the wrap positions, the auto fit and the
  shape's area**
- The line image is **composited in the same render pass as the text** (so a transparent
  background still passes downstream). If the input TOP is a movie every frame re-renders (a still
  or constant only re-renders on parameter changes)
- Line metrics are produced for vertical text and non-rectangular shapes too, but the line image
  is laid out on a horizontal basis (vertical rules along a vertical column are not supported)
- Rendering happens on a worker thread (parameter changes are detected by signature). Cook never
  blocks; latency is 1–2 frames

### Examples

`demo.toe`'s `/project1/coretext` contains demos of each feature.

| Node | Description |
|---|---|
| `rich` + `style_rich` | 「夜景」red at 150px W900, "Neon" blue and underlined |
| `ruby` + `style_ruby` | Vertical text (Hiragino Mincho) with ruby over 令和 / 八年 / 東京 |
| `shape` + `shape_path` | Text flowed into a star-shaped Path DAT |
| `shape_sop` + `sop_shape` → `sop_dat` | Flowed into **a SOP's shape** (circle SOP → SOP to DAT → Path DAT) |
| `typewriter` + `type_source` → `typer` → `type_out` | One character at a time, driven by `absTime.seconds` |

### Build

```
cd CoreText && ./build.sh   # → build/CoreTextTOP.plugin
```

## 日本語

Apple のテキストレンダリング(Core Text + Core Graphics)で文字を描く TOP。
**TD標準 Text TOP より自由で美しいタイポグラフィ**を狙ったオペレータ。

### Text TOP との違い(できること)

- **フォントは macOS標準フォントパネルで選択**(`Choose Font` パルス→パネルで選ぶと
  Font 欄に結果が表示される)。**フォントファイル(.ttf/.otf/.ttc)の直接指定**も可(未インストールでも使える)。
  既定はSFシステムフォント。`Weight` 100〜900 を**無段階**指定(可変フォントの `wght` 軸。
  無い場合は600以上でBold近似)
- **シアー(疑似イタリック)**: `Shear X / Y` でフォント行列を傾ける。**イタリック体を持たない
  和文書体でも角度を無段階で指定**でき、縁取り・Embolden・グラデも一緒に変形する
- **プロポーショナルメトリクス(palt)**: OpenType `'palt'` で自動文字詰め
  (CSSの `font-feature-settings: 'palt'` 相当)。「」や句読点のアキが詰まり、
  見出し向けのプロポーショナル詰め組みになる(対応フォント: ヒラギノ等)
- **リッチテキスト(範囲ごとのスタイル)**: Style DAT で**文字列や範囲を指定して**色・サイズ・
  ウェイト・フォント・字間・下線を個別に変えられる(1ノードで見出し+本文、一語だけ強調 等)
- **ルビ(振り仮名)**: `CTRubyAnnotation` による**本物のルビ**。横書きは上、縦書きは右に付く
- **シェイプ組版**: 矩形/円・楕円/角丸/多角形/**任意パス** にテキストを流し込める
  (Core Text は矩形以外の CGPath を受け付ける)。パスは Table DAT の `u v` でも、
  **SOP → SOP to DAT でも渡せる**(SOPを編集すると組版がリアルタイムに追従)
- **カラー絵文字** 😀🎉(Apple Color Emoji をそのまま描画)
- **日本語縦書き**(Vertical Text): 右→左の段組・縦用約物(。、の位置)も正しい
- **高品質AA**: サブピクセル位置指定・リガチャ(none/standard/all)・トラッキング・行送り・両端揃え
- **改行制御(Text Wrap)**: CSSの `text-wrap` 相当。**Balance**(各行の文字数を均等に)・
  **Pretty**(最終行に一文字/一単語だけ残る孤立を回避)を含む5モード
- **省略(Truncate)**: 領域に収まらないとき **末尾/先頭/中央を `…` で切り詰め**る
  (CSS `text-overflow: ellipsis` 相当)。絵文字・結合文字を割らない
- **グラデーション塗り**(2色・角度)/ **縁取り**(外側アウトライン)/ **ドロップシャドウ**
- **ライン画像(入力0)**: 入力TOPの画像を**各行の実位置・実幅に合わせて自動で敷く**
  (画像による下線・蛍光マーカー・帯)。行メトリクスは Info CHOP / Info DAT にも出るので
  TD側で自由な装飾も組める
- 複数行は **Text DAT 参照**(`Text DAT` パラメータ。セルを行/タブで連結)

### 実測(M2)

- 1280×720・SF Weight750・グラデ+シャドウ+縁取り: パラメータ変更から1〜2フレームで反映(非同期レンダ)
- 縦書き(ヒラギノ明朝・28文字)・絵文字混在・Hiragino/Helvetica等のフォント指定を視認検証済み

### パラメータ

| ページ | パラメータ | 説明 |
|---|---|---|
| CoreText | Text / Text DAT | 描画テキスト。DAT指定時はDAT優先(複数行向け) |
| | Edit Text (live Text DAT) | **リアルタイム入力用**。押すと編集用Text DATがドックチップとして自動生成・接続され、**タイプごとに即レンダ反映**(Text欄はEnter確定のため)。**Text DAT が接続済みの場合は何もしない**(上書きしない) |
| | Style DAT (rich text / ruby) | **範囲スタイル表**(下記)。リッチテキスト・ルビ・縦組み形の指定 |
| | Font | フォントパネルで選んだ結果の表示欄(PostScript名・手入力も可。空=SF) |
| | Font File | .ttf/.otf/.ttc の直接指定(Fontより優先・未インストール可) |
| | Choose Font (macOS Font Panel) | **macOS標準フォントパネル**を開く。選択すると Font/Font Size に自動反映 |
| | Proportional Metrics (palt) | OpenType 'palt' 自動文字詰め(対応フォントのみ効く) |
| | Font Size / Weight / Italic | サイズ(px)/ ウェイト100〜900(可変フォント)/ 斜体(書体が持つ本物のイタリック) |
| | Shear X / Shear Y (deg) | **シアー(疑似イタリック)**。フォント行列にせん断を入れるので**書体を問わず**角度指定でき、和文書体も傾けられる。縁取り/Embolden/グラデ/シャドウも追従 |
| | Slant Axis (deg) | 可変フォントの `slnt` 軸(**書体が軸を持つ場合のみ**。書体デザイナー設計の本物の傾き) |
| | Auto Fit Font Size | **描画領域に収まるまで自動縮小**(Font Sizeが上限)。Word Wrap Onなら折り返して収まるサイズ、Offなら1行のまま収まるサイズ。実サイズはInfo CHOP `fitted_size` |
| | Tracking / Line Height / Ligatures | 字間(pt・-100〜100で重なりも可)/ 行送り倍率(0〜・**どの値でも1行目のベースラインは動かない**。行間だけが伸縮し、小さくすると行が重なる)/ リガチャ |
| | Horizontal/Vertical Align | 左/中/右/両端揃え・上/中/下 |
| | Vertical Text | 縦書き(右→左の段組) |
| | Text Wrap | 改行制御(CSS text-wrap相当): **Wrap**=幅で折返し / **No Wrap**=改行なし / **Balance**=各行の長さを均等化 / **Pretty**=最終行の孤立を回避 / **Stable**=Wrapと同じ |
| | Truncate (overflow) | **領域に収まらない場合の省略**(CSS `text-overflow: ellipsis` 相当): Off(クリップ)/ Tail(末尾を省略)/ Head(先頭を省略)/ Middle(中央を省略) |
| | Ellipsis | 省略記号(既定 `…`。`...` や ` ▶` など任意) |
| | Layout Shape | 組版領域の形: Rectangle / Ellipse / Rounded Rect / Polygon / Path DAT |
| | Polygon Sides / Corner Round / Polygon Rotate | 多角形の辺数 / 角丸(0-1)/ 多角形の回転(度) |
| | Path DAT (u v / SOP to DAT) | Shape=Path 用の点列。`u v`(0〜1)のほか **SOP to DAT の `P(0)` `P(1)` 列を自動認識**(ヘッダ行は自動判定) |
| | Normalize Path to Area | 点群のバウンディングボックスを領域に自動フィット(既定On)。**SOPの単位のまま渡せる** |
| | Padding | 余白(px・4辺共通) |
| | Padding Left / Right / Top / Bottom | **各辺への追加量**(px)。実効余白 = `Padding` + その辺の追加量。負値で共通値より狭くもできる |
| Line Image | Enable Line Image (input 0) | **入力0の画像を各行の下に敷く**(下線・マーカー・帯)。行の実位置・実幅に自動追従 |
| | Apply To | All Lines / First Line / Last Line |
| | Width | Text Width(行の文字幅ぴったり)/ Full Area Width(描画領域の幅) |
| | Offset Below Baseline (px) | ベースラインから下へのオフセット。**負値で文字に重ねる**(マーカー風) |
| | Offset X (px) | 水平オフセット(正=右・負=左)。行位置から左右にずらす |
| | Thickness (px) | ラインの高さ。**0=入力画像のアスペクト比を維持** |
| | Extend Ends (px) | 両端の延長(負値で短縮) |
| | Draw Over Text | On=文字の上に描く(既定は文字の下) |
| Style | Font Color / Background Color | 文字色 / 背景色(既定は透明背景) |
| | Embolden (px) | **合成ボールド**: マスク膨張でフォントの最大ウェイト以上に太らせる(グラデ/縁取り併用可)。**閉じた内側(oや口の穴)は保護**され潰れない |
| | Gradient Fill / Color 2 / Angle | グラデーション塗り(Font Color→Color 2・角度0°=上→下) |
| | Stroke Width / Color | 縁取り(外側アウトライン・px) |
| | Drop Shadow / Color / Offset / Blur | ドロップシャドウ |
| Common | Output Resolution | **他のTOPと同じくCommonページで解像度指定**(Custom等)。Use Input時は1280×720 |

Info CHOP: `executes / renders / width / height / lines / fitted_size / truncated` +
**行メトリクス** `line{i}/u v w h baseline`(TDのuv・0〜1・左下原点。`v`=行の下端・`baseline`=ベースライン。
スロットは32行ぶん固定)。Info DAT: `resolved_font / lines` + **1行=1テキスト行の px 値テーブル**
(`x_px y_px w_px h_px baseline_px`)。フォント名が解決できずフォールバックした場合は Warning に表示。

行メトリクスを使うと、ライン画像に限らず **行単位の装飾をTD側で自由に組める**
(Transform TOP を式で駆動して行ボックス・行アニメーション等)。

### Style DAT(リッチテキスト / ルビ)

1行目をヘッダ行にして列名を書き、2行目以降が1つの範囲スタイルになります。**必要な列だけ**でOK
(空欄は本体パラメータを継承)。

**範囲の指定**(どちらか):

| 列 | 内容 |
|---|---|
| `text` | この部分文字列の**全出現**に適用(いちばん手軽) |
| `start` / `length` | 文字インデックスで指定(**合成文字単位**なので絵文字も1文字と数える) |

**スタイルの列**:

| 列 | 内容 |
|---|---|
| `r` `g` `b` `a` | 文字色(0〜1) |
| `size` / `weight` / `italic` | サイズ(px)/ ウェイト(100〜900)/ 斜体(0/1) |
| `font` | フォント名(PostScript名またはファミリー名) |
| `tracking` | 字間(pt) |
| `underline` | 下線(0/1) |
| `ruby` / `rubysize` | **ルビ(振り仮名)** / ルビの相対サイズ(既定 0.5) |
| `upright` | 縦書き時のグリフの向き: `1`=縦組み形(正立)/ `0`=横組み形(90°回転)。欧文を寝かせる/起こす。**効きは書体依存**(SF+欧文では効く。ヒラギノ等の和文書体は数字の縦組み形が横倒しで固定のため変わらない) |

例(見出しの一語を赤く大きく、漢字にルビ):

```
text    r    g    b    a   size  weight  ruby
夜景    0.9  0.2  0.2  1   150   900
漢字                                      かんじ
```

#### SOP の形を使う

TOP は SOP をワイヤ接続できないので、**SOP to DAT** を挟みます:

```
circle SOP → SOP to DAT (extract = points) → CoreText の Path DAT
```

`P(0)`(x)と `P(1)`(y)列を自動認識し、`Normalize Path to Area` が点群を描画領域へ自動フィット
するので、SOPの座標スケールは気にしなくて構いません。SOPを編集すれば組版もリアルタイムに追従します。

### 注意・制約

- **TouchDesigner Non-Commercial** では解像度が 1280x1280 に制限される。上限を超える出力は**自動で上限内へ縮小**し、その旨を警告に出す(縮小しないと TD 側で絵が崩れるため)。フル解像度が要るなら商用ライセンスを使う

- **縁取り/Emboldenはマスク膨張方式**。グリフのアウトラインパスは使わない
  (システムUIフォントのアウトライン抽出は TD プロセス内でゴミ輪郭が混入する実挙動があるため)。
  絵文字にも縁が付く。膨張は**画像端から到達できる外側の背景のみ**に適用されるため、
  o・回 などの閉じたカウンターは潰れない(フラッドフィルで保護)
- **グラデーション時は絵文字もグラデ塗りのシルエット**になる(テキスト全体をマスクにして塗るため)。
  カラー絵文字を出したい場合はグラデーションをOffに
- 縦書き時の Vertical Align は未適用(全域レイアウト)。両端揃え(Justify)は横書きのみ
- **矩形以外の Layout Shape では Vertical Align は効かない**(形の全域に上から流し込む)
- **縦中横(数字を横に並べる)は非対応**。Core Text に該当APIが無いため、`upright` 列で
  「正立させる/寝かせる」の切り替えまでが可能(かつ書体依存)。縦書きで年号などを組むときは
  **漢数字**を使うのが確実(`令和八年`)
- Style DAT の `start`/`length` 指定は、Truncate で省略が発生すると範囲がずれる
  (`text` 指定なら省略後の文字列に対して探索されるのでズレない)
- 1文字も描けないフォント名を指定するとフォールバック(Warning参照)
- **Shear と Italic / Slant Axis は別物**。Italic=書体の本物のイタリック体に切替(持たない書体では
  無変化)、Slant Axis=可変フォントの `slnt` 軸(軸を持つ書体のみ。SFは非対応)、
  Shear=幾何変形なのでどの書体でも効く。シアーは字送り幅を変えないため、深い角度では
  隣の字と接近する(通常のオブリークと同じ挙動)
- **Truncate と Auto Fit は別戦略**。Auto Fit(縮小して全文を見せる)がOnだとほぼ収まるので
  Truncate は発動しない。「サイズは固定で入り切らない分は …」なら Auto Fit Off + Truncate を使う
- 省略は**収まる最大量を二分探索**して求める(合成文字境界にスナップするので絵文字を割らない)。
  実際に省略されたかは Info CHOP `truncated`(0/1)で分かる
- 余白は **`Padding`(4辺共通)+ 各辺の追加量**の合算。`Padding` だけを使う従来の指定はそのまま動く。
  余白を変えると**折り返し位置・オートフィット・シェイプの領域も追従**する
- ライン画像は**テキストと同じレンダパスで合成**される(透明背景のまま下流に渡せる)。
  入力TOPが動画なら毎フレーム再レンダになる(静止画・定数はパラメータ変更時のみ)
- 縦書き・矩形以外の Layout Shape でも行メトリクスは出るが、ライン画像の敷き方は横書き基準
  (縦書きの段に沿った縦ラインは未対応)
- レンダはワーカースレッド(パラメータ変更のシグネチャ検知)。cook 非ブロック・1〜2フレーム遅延

### 利用例

`demo.toe` の `/project1/coretext` に各機能のデモがあります。

| ノード | 内容 |
|---|---|
| `rich` + `style_rich` | 「夜景」だけ赤・150px・W900、「Neon」だけ青・下線 |
| `ruby` + `style_ruby` | 縦書き(ヒラギノ明朝)+ 令和/八年/東京にルビ |
| `shape` + `shape_path` | 星形の Path DAT にテキストを流し込み |
| `shape_sop` + `sop_shape` → `sop_dat` | **SOPの形**に流し込み(circle SOP → SOP to DAT → Path DAT) |
| `typewriter` + `type_source` → `typer` → `type_out` | `absTime.seconds` 駆動で一文字ずつ表示 |

### ビルド

```
cd CoreText && ./build.sh   # → build/CoreTextTOP.plugin
```
