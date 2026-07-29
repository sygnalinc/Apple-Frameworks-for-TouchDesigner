# CoreText TOP

Apple のテキストレンダリング(Core Text + Core Graphics)で文字を描く TOP。
**TD標準 Text TOP より自由で美しいタイポグラフィ**を狙ったオペレータ。

## Text TOP との違い(できること)

- **フォントは macOS標準フォントパネルで選択**(`Choose Font` パルス→パネルで選ぶと
  Font 欄に結果が表示される)。**フォントファイル(.ttf/.otf/.ttc)の直接指定**も可(未インストールでも使える)。
  既定はSFシステムフォント。`Weight` 100〜900 を**無段階**指定(可変フォントの `wght` 軸。
  無い場合は600以上でBold近似)
- **プロポーショナルメトリクス(palt)**: OpenType `'palt'` で自動文字詰め
  (CSSの `font-feature-settings: 'palt'` 相当)。「」や句読点のアキが詰まり、
  見出し向けのプロポーショナル詰め組みになる(対応フォント: ヒラギノ等)
- **カラー絵文字** 😀🎉(Apple Color Emoji をそのまま描画)
- **日本語縦書き**(Vertical Text): 右→左の段組・縦用約物(。、の位置)も正しい
- **高品質AA**: サブピクセル位置指定・リガチャ(none/standard/all)・トラッキング・行送り・両端揃え
- **改行制御(Text Wrap)**: CSSの `text-wrap` 相当。**Balance**(各行の文字数を均等に)・
  **Pretty**(最終行に一文字/一単語だけ残る孤立を回避)を含む5モード
- **省略(Truncate)**: 領域に収まらないとき **末尾/先頭/中央を `…` で切り詰め**る
  (CSS `text-overflow: ellipsis` 相当)。絵文字・結合文字を割らない
- **グラデーション塗り**(2色・角度)/ **縁取り**(外側アウトライン)/ **ドロップシャドウ**
- 複数行は **Text DAT 参照**(`Text DAT` パラメータ。セルを行/タブで連結)

## 実測(M2)

- 1280×720・SF Weight750・グラデ+シャドウ+縁取り: パラメータ変更から1〜2フレームで反映(非同期レンダ)
- 縦書き(ヒラギノ明朝・28文字)・絵文字混在・Hiragino/Helvetica等のフォント指定を視認検証済み

## パラメータ

| ページ | パラメータ | 説明 |
|---|---|---|
| CoreText | Text / Text DAT | 描画テキスト。DAT指定時はDAT優先(複数行向け) |
| | Edit Text (live Text DAT) | **リアルタイム入力用**。押すと編集用Text DATがドックチップとして自動生成・接続され、**タイプごとに即レンダ反映**(Text欄はEnter確定のため)。**Text DAT が接続済みの場合は何もしない**(上書きしない) |
| | Font | フォントパネルで選んだ結果の表示欄(PostScript名・手入力も可。空=SF) |
| | Font File | .ttf/.otf/.ttc の直接指定(Fontより優先・未インストール可) |
| | Choose Font (macOS Font Panel) | **macOS標準フォントパネル**を開く。選択すると Font/Font Size に自動反映 |
| | Proportional Metrics (palt) | OpenType 'palt' 自動文字詰め(対応フォントのみ効く) |
| | Font Size / Weight / Italic | サイズ(px)/ ウェイト100〜900(可変フォント)/ 斜体 |
| | Auto Fit Font Size | **描画領域に収まるまで自動縮小**(Font Sizeが上限)。Word Wrap Onなら折り返して収まるサイズ、Offなら1行のまま収まるサイズ。実サイズはInfo CHOP `fitted_size` |
| | Tracking / Line Height / Ligatures | 字間(pt・-100〜100で重なりも可)/ 行送り倍率(0〜・**1行目は固定**。1.0未満は行高を詰める)/ リガチャ |
| | Horizontal/Vertical Align | 左/中/右/両端揃え・上/中/下 |
| | Vertical Text | 縦書き(右→左の段組) |
| | Text Wrap | 改行制御(CSS text-wrap相当): **Wrap**=幅で折返し / **No Wrap**=改行なし / **Balance**=各行の長さを均等化 / **Pretty**=最終行の孤立を回避 / **Stable**=Wrapと同じ |
| | Truncate (overflow) | **領域に収まらない場合の省略**(CSS `text-overflow: ellipsis` 相当): Off(クリップ)/ Tail(末尾を省略)/ Head(先頭を省略)/ Middle(中央を省略) |
| | Ellipsis | 省略記号(既定 `…`。`...` や ` ▶` など任意) |
| | Padding | 余白(px) |
| Style | Font Color / Background Color | 文字色 / 背景色(既定は透明背景) |
| | Embolden (px) | **合成ボールド**: マスク膨張でフォントの最大ウェイト以上に太らせる(グラデ/縁取り併用可)。**閉じた内側(oや口の穴)は保護**され潰れない |
| | Gradient Fill / Color 2 / Angle | グラデーション塗り(Font Color→Color 2・角度0°=上→下) |
| | Stroke Width / Color | 縁取り(外側アウトライン・px) |
| | Drop Shadow / Color / Offset / Blur | ドロップシャドウ |
| Common | Output Resolution | **他のTOPと同じくCommonページで解像度指定**(Custom等)。Use Input時は1280×720 |

Info CHOP: `executes / renders / width / height / lines / fitted_size / truncated`。Info DAT: `resolved_font / lines`。
フォント名が解決できずフォールバックした場合は Warning に表示。

## 注意・制約

- **縁取り/Emboldenはマスク膨張方式**。グリフのアウトラインパスは使わない
  (システムUIフォントのアウトライン抽出は TD プロセス内でゴミ輪郭が混入する実挙動があるため)。
  絵文字にも縁が付く。膨張は**画像端から到達できる外側の背景のみ**に適用されるため、
  o・回 などの閉じたカウンターは潰れない(フラッドフィルで保護)
- **グラデーション時は絵文字もグラデ塗りのシルエット**になる(テキスト全体をマスクにして塗るため)。
  カラー絵文字を出したい場合はグラデーションをOffに
- 縦書き時の Vertical Align は未適用(全域レイアウト)。両端揃え(Justify)は横書きのみ
- 1文字も描けないフォント名を指定するとフォールバック(Warning参照)
- **Truncate と Auto Fit は別戦略**。Auto Fit(縮小して全文を見せる)がOnだとほぼ収まるので
  Truncate は発動しない。「サイズは固定で入り切らない分は …」なら Auto Fit Off + Truncate を使う
- 省略は**収まる最大量を二分探索**して求める(合成文字境界にスナップするので絵文字を割らない)。
  実際に省略されたかは Info CHOP `truncated`(0/1)で分かる
- レンダはワーカースレッド(パラメータ変更のシグネチャ検知)。cook 非ブロック・1〜2フレーム遅延

## ビルド

```
cd CoreText && ./build.sh   # → build/CoreTextTOP.plugin
```
