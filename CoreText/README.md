# CoreText TOP

Apple のテキストレンダリング(Core Text + Core Graphics)で文字を描く TOP。
**TD標準 Text TOP より自由で美しいタイポグラフィ**を狙ったオペレータ。

## Text TOP との違い(できること)

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

## 実測(M2)

- 1280×720・SF Weight750・グラデ+シャドウ+縁取り: パラメータ変更から1〜2フレームで反映(非同期レンダ)
- 縦書き(ヒラギノ明朝・28文字)・絵文字混在・Hiragino/Helvetica等のフォント指定を視認検証済み

## パラメータ

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

## Style DAT(リッチテキスト / ルビ)

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

### SOP の形を使う

TOP は SOP をワイヤ接続できないので、**SOP to DAT** を挟みます:

```
circle SOP → SOP to DAT (extract = points) → CoreText の Path DAT
```

`P(0)`(x)と `P(1)`(y)列を自動認識し、`Normalize Path to Area` が点群を描画領域へ自動フィット
するので、SOPの座標スケールは気にしなくて構いません。SOPを編集すれば組版もリアルタイムに追従します。

## 注意・制約

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

## 利用例

`sample.toe` の `/project1/coretext_demo` に3機能のデモがあります。

| ノード | 内容 |
|---|---|
| `rich` + `style_rich` | 「夜景」だけ赤・150px・W900、「Neon」だけ青・下線 |
| `ruby` + `style_ruby` | 縦書き(ヒラギノ明朝)+ 令和/八年/東京にルビ |
| `shape` + `shape_path` | 星形の Path DAT にテキストを流し込み |
| `shape_sop` + `sop_shape` → `sop_dat` | **SOPの形**に流し込み(circle SOP → SOP to DAT → Path DAT) |

## ビルド

```
cd CoreText && ./build.sh   # → build/CoreTextTOP.plugin
```
