# CoreText TOP

Apple のテキストレンダリング(Core Text + Core Graphics)で文字を描く TOP。
**TD標準 Text TOP より自由で美しいタイポグラフィ**を狙ったオペレータ。

## Text TOP との違い(できること)

- **フォントはプルダウン選択**(インストール済み全ファミリーを列挙・M2実測252件)、
  または **フォントファイル(.ttf/.otf/.ttc)を直接指定**(未インストールでも使える)。
  既定はSFシステムフォント。`Weight` 100〜900 を**無段階**指定(可変フォントの `wght` 軸。
  無い場合は600以上でBold近似)
- **プロポーショナルメトリクス(palt)**: OpenType `'palt'` で自動文字詰め
  (CSSの `font-feature-settings: 'palt'` 相当)。「」や句読点のアキが詰まり、
  見出し向けのプロポーショナル詰め組みになる(対応フォント: ヒラギノ等)
- **カラー絵文字** 😀🎉(Apple Color Emoji をそのまま描画)
- **日本語縦書き**(Vertical Text): 右→左の段組・縦用約物(。、の位置)も正しい
- **高品質AA**: サブピクセル位置指定・リガチャ(none/standard/all)・トラッキング・行送り・両端揃え
- **グラデーション塗り**(2色・角度)/ **縁取り**(外側アウトライン)/ **ドロップシャドウ**
- 複数行は **Text DAT 参照**(`Text DAT` パラメータ。セルを行/タブで連結)

## 実測(M2)

- 1280×720・SF Weight750・グラデ+シャドウ+縁取り: パラメータ変更から1〜2フレームで反映(非同期レンダ)
- 縦書き(ヒラギノ明朝・28文字)・絵文字混在・Hiragino/Helvetica等のフォント指定を視認検証済み

## パラメータ

| ページ | パラメータ | 説明 |
|---|---|---|
| CoreText | Text / Text DAT | 描画テキスト。DAT指定時はDAT優先(複数行向け) |
| | Font | インストール済みフォントのプルダウン(既定 System Font (SF)) |
| | Font File | .ttf/.otf/.ttc の直接指定(Fontより優先・未インストール可) |
| | Proportional Metrics (palt) | OpenType 'palt' 自動文字詰め(対応フォントのみ効く) |
| | Font Size / Weight / Italic | サイズ(px)/ ウェイト100〜900(可変フォント)/ 斜体 |
| | Tracking / Line Height / Ligatures | 字間(pt)/ 行送り倍率 / リガチャ |
| | Horizontal/Vertical Align | 左/中/右/両端揃え・上/中/下 |
| | Vertical Text | 縦書き(右→左の段組) |
| | Word Wrap / Padding | 折り返し / 余白(px) |
| Style | Font Color / Background Color | 文字色 / 背景色(既定は透明背景) |
| | Gradient Fill / Color 2 / Angle | グラデーション塗り(Font Color→Color 2・角度0°=上→下) |
| | Stroke Width / Color | 縁取り(外側アウトライン・px) |
| | Drop Shadow / Color / Offset / Blur | ドロップシャドウ |
| Output | Width / Height | 出力解像度(既定1280×720) |

Info CHOP: `executes / renders / width / height / lines`。Info DAT: `resolved_font / lines`。
フォント名が解決できずフォールバックした場合は Warning に表示。

## 注意・制約

- **縁取りはマスク膨張方式(外側アウトライン)**。グリフのアウトラインパスは使わない
  (システムUIフォントのアウトライン抽出は TD プロセス内でゴミ輪郭が混入する実挙動があるため)。
  絵文字にも縁が付く
- **グラデーション時は絵文字もグラデ塗りのシルエット**になる(テキスト全体をマスクにして塗るため)。
  カラー絵文字を出したい場合はグラデーションをOffに
- 縦書き時の Vertical Align は未適用(全域レイアウト)。両端揃え(Justify)は横書きのみ
- 1文字も描けないフォント名を指定するとフォールバック(Warning参照)
- レンダはワーカースレッド(パラメータ変更のシグネチャ検知)。cook 非ブロック・1〜2フレーム遅延

## ビルド

```
cd CoreText && ./build.sh   # → build/CoreTextTOP.plugin
```
