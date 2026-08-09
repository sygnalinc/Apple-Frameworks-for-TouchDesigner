# PDFKit TOP

**English** | [日本語](#日本語)

## English

Handles PDFs with **PDFKit**. Renders the chosen page to BGRA8, and exposes the document structure
(metadata / outline / page text / annotations) through the **Info DAT** (the former **PDFKit DAT**
is merged in).

### Automatic Info DAT (no setup)

**Just place the operator** and a pre-filled Callbacks DAT (`<node>_callbacks`) is created and
docked to it as a **closed ↓ chip**, exactly like the shader DAT of a GLSL TOP.
**The moment you turn the `Info DAT` toggle ON, an Info DAT (`<node>_info`) is created next to
it** (nothing happens if one already exists — duplicate guard). Edit `onInfoDAT` inside the chip
to change the name or placement.

### Image output

Set File, Page (0-based) and DPI and the page is rendered on a white background (worker thread,
cook never blocks). PDF coordinates (bottom-left origin) are row-flipped to TD's display
orientation.

### Info DAT (document structure — formerly PDFKit DAT)

Switch the table with the `Info DAT Mode` parameter and point an Info DAT at this node:

| Info DAT Mode | Output |
|---|---|
| Info | key/value: pages/title/author/subject/creator/producer/encrypted/locked/page 0 size |
| Outline | level / title / page (the bookmark hierarchy) |
| Text | line / text (the chosen page's text, line by line) |
| Annotations | type / x / y / w / h / contents (coordinates in PDF points, bottom-left origin) |

Text and Annotations operate on the page given by the `Page` parameter.

### Info CHOP

`executes / width / height / pages`

### Measured (M2)

With a two-page test PDF (`Assets/sample_doc.pdf`):
- TOP: 612×792 pt rendered at 150 DPI to **1275×1650**
- Info DAT Info: 10 rows including `pages=2 / title=TDAppleOps Sample PDF / author=SYGNAL Inc.`
- Info DAT Text: the page's four body lines extracted line by line
- Info DAT Annotations: `(none)` for a PDF with no annotations (the 6-column header is still
  correct)

### Parameters

File / Page (0-based; shared by rendering and Text/Annotations) / DPI / Info DAT Mode

### Notes

- Under **TouchDesigner Non-Commercial** the resolution is capped at 1280x1280. Output above the
  cap is **scaled down automatically** with a warning (without it TD renders garbage). Use a
  commercial license if you need full resolution.

- The coordinate system is PDF points (bottom-left origin)
- The old **PDFKit DAT** was merged into this TOP's Info DAT and removed (2026-07-21)

### Build

```
cd PDFKit && ./build.sh   # → build/PDFKitTOP.plugin
```

## 日本語

**PDFKit** で PDF を扱う。指定ページを BGRA8 に描画し、文書構造(メタデータ/アウトライン/
ページテキスト/注釈)は **Info DAT** で出す(旧 **PDFKit DAT** を統合)。

### Info DAT の自動生成(操作不要)

**OPを配置するだけ**で雛形入りの Callbacks DAT(`<node名>_callbacks`)が自動生成され、
GLSL TOP のシェーダDATと同じ**閉じた↓チップ**としてノードにドックされる。
**`Info DAT` トグルを ON にした瞬間、隣に Info DAT(`<node名>_info`)が自動生成**される
(既にあれば何もしない=二重生成ガード)。生成位置や名前はチップ内の `onInfoDAT` を編集して変えられる。

### 映像出力

File / Page(0始まり)/ DPI を指定して白背景にページを描画(ワーカースレッド・cook非ブロック)。
PDF座標(左下原点)はTD表示向きに行反転済み。

### Info DAT(文書構造・旧 PDFKit DAT)

`Info DAT Mode` パラメータでテーブルを切替え、Info DAT をこのノードに向けて読む:

| Info DAT Mode | 出力 |
|---|---|
| Info | key/value: pages/title/author/subject/creator/producer/encrypted/locked/page0サイズ |
| Outline | level / title / page(ブックマーク階層) |
| Text | line / text(指定ページのテキストを行ごとに) |
| Annotations | type / x / y / w / h / contents(座標はPDFポイント・左下原点) |

Text / Annotations は `Page` パラメータのページを対象にする。

### Info CHOP

`executes / width / height / pages`

### 実測(M2)

2ページのテストPDF(`Assets/sample_doc.pdf`)で:
- TOP: 612×792pt を 150DPI で **1275×1650** に描画
- Info DAT Info: `pages=2 / title=TDAppleOps Sample PDF / author=SYGNAL Inc.` 等10行
- Info DAT Text: ページ本文4行を行ごとに抽出
- Info DAT Annotations: 注釈なしPDFで `(none)`(6列ヘッダは正しく出力)

### パラメータ

File / Page(0始まり・描画とText/Annotations共用)/ DPI / Info DAT Mode

### 注意

- **TouchDesigner Non-Commercial** では解像度が 1280x1280 に制限される。上限を超える出力は**自動で上限内へ縮小**し、その旨を警告に出す(縮小しないと TD 側で絵が崩れるため)。フル解像度が要るなら商用ライセンスを使う

- 座標系はPDFポイント(左下原点)
- 旧 **PDFKit DAT** は本TOPのInfo DATに統合され廃止(2026-07-21)

### ビルド

```
cd PDFKit && ./build.sh   # → build/PDFKitTOP.plugin
```
