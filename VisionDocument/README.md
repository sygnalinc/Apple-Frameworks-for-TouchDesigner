# Vision Document DAT

**English** | [日本語](#日本語)

## English

Uses the new Vision `RecognizeDocumentsRequest` (macOS 26+) to recognise the **paragraph, table,
line, cell and list structure** of a document image and output it as a table DAT. It returns the
**layout structure**, not just OCR text.

- Tables come out as a row/column count plus per-cell entries (row/col + text) — good for turning
  forms and tables into data automatically
- Analysis runs asynchronously in a Swift helper (`RecognizeDocumentsRequest`); cook only polls and
  never blocks

### Measured (M2)

- Tested with a synthetic document (a heading, two paragraphs and a 4×3 table): the **4×3 table was
  recognised and all 12 cells extracted with correct row/col and text** (Region/Q1/Q2,
  North/120/145 …). paragraphs = 15 (text by line)
- Table structure recognition is accurate (merged cells and row/column spans are also available
  through rowRange/columnRange)

### Output (table DAT)

| Column | Description |
|---|---|
| type | paragraph / table / cell / list |
| page | Page number (0 for a single image) |
| index | Element index (table number, paragraph number, list number) |
| row | Table: row count (type=table) / the cell's row (type=cell) / list item number |
| col | Table: column count (type=table) / the cell's column (type=cell) |
| text | Text (the paragraph's full text, the cell's contents, the list item) |

Info CHOP: `executes / paragraphs / tables / lists / cells / analyzing`

### Parameters

| Parameter | Description |
|---|---|
| Document Image | A photo or scan of the document (PNG/JPEG/HEIC…) |

### Notes

- **macOS 26+ required** (the new Vision Swift API). Older versions raise a warning
- Multilingual (following Vision's text recognition)
- Paragraphs are enumerated line by line, so text inside a table also appears as paragraphs. Use
  type=cell for the structured cells

### Build

```
cd VisionDocument && ./build.sh   # → build/VisionDocumentDAT.plugin (Swift helper bundled)
```

## 日本語

新しい Vision の `RecognizeDocumentsRequest`(macOS 26+)で、文書画像の**段落・表・行・セル・
リスト構造**を認識してテーブルDATへ出力する。OCR(文字列)だけでなく**レイアウト構造**を返す。

- 表は行数×列数とセル単位(row/col + テキスト)で取り出せる。フォーム/表の自動データ化に
- 解析は Swift ヘルパ(`RecognizeDocumentsRequest`)で非同期。cook は poll するだけでブロックしない

### 実測(M2)

- 合成文書(見出し＋段落2＋4×3表)で検証: **table 4×3 を認識、12セル全てを正しい row/col と
  テキスト**(Region/Q1/Q2, North/120/145 …)で抽出。paragraphs=15(行単位のテキスト)
- 表構造の認識精度は高い(セルの結合・行列範囲も rowRange/columnRange で取得可能)

### 出力仕様(テーブルDAT)

| 列 | 内容 |
|---|---|
| type | paragraph / table / cell / list |
| page | ページ番号(単一画像は0) |
| index | 要素インデックス(表番号・段落番号・リスト番号) |
| row | 表: 行数(type=table)/ セルの行(type=cell)/ リスト項目番号 |
| col | 表: 列数(type=table)/ セルの列(type=cell) |
| text | テキスト(段落の全文・セルの内容・リスト項目) |

Info CHOP: `executes / paragraphs / tables / lists / cells / analyzing`

### パラメータ

| パラメータ | 説明 |
|---|---|
| Document Image | 文書の写真/スキャン画像(PNG/JPEG/HEIC等) |

### 注意

- **macOS 26+ 必須**(新Vision Swift API)。それ未満は Warning
- 多言語対応(Vision のテキスト認識に準じる)
- 段落(paragraphs)は行単位で列挙されるため、表内テキストも paragraph として重複して現れる。
  構造化されたセルは type=cell を参照する

### ビルド

```
cd VisionDocument && ./build.sh   # → build/VisionDocumentDAT.plugin(Swiftヘルパ同梱)
```
