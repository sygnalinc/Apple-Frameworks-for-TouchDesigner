# PDFKit TOP

**PDFKit** で PDF を扱う。指定ページを BGRA8 に描画し、文書構造(メタデータ/アウトライン/
ページテキスト/注釈)は **Info DAT** で出す(旧 **PDFKit DAT** を統合)。

## Info DAT の自動生成(操作不要)

**OPを配置するだけ**で雛形入りの Callbacks DAT(`<node名>_callbacks`)が自動生成され、
GLSL TOP のシェーダDATと同じ**閉じた↓チップ**としてノードにドックされる。
**`Info DAT` トグルを ON にした瞬間、隣に Info DAT(`<node名>_info`)が自動生成**される
(既にあれば何もしない=二重生成ガード)。生成位置や名前はチップ内の `onInfoDAT` を編集して変えられる。

## 映像出力

File / Page(0始まり)/ DPI を指定して白背景にページを描画(ワーカースレッド・cook非ブロック)。
PDF座標(左下原点)はTD表示向きに行反転済み。

## Info DAT(文書構造・旧 PDFKit DAT)

`Info DAT Mode` パラメータでテーブルを切替え、Info DAT をこのノードに向けて読む:

| Info DAT Mode | 出力 |
|---|---|
| Info | key/value: pages/title/author/subject/creator/producer/encrypted/locked/page0サイズ |
| Outline | level / title / page(ブックマーク階層) |
| Text | line / text(指定ページのテキストを行ごとに) |
| Annotations | type / x / y / w / h / contents(座標はPDFポイント・左下原点) |

Text / Annotations は `Page` パラメータのページを対象にする。

## Info CHOP

`executes / width / height / pages`

## 実測(M2)

2ページのテストPDF(`Assets/sample_doc.pdf`)で:
- TOP: 612×792pt を 150DPI で **1275×1650** に描画
- Info DAT Info: `pages=2 / title=TDAppleOps Sample PDF / author=SYGNAL Inc.` 等10行
- Info DAT Text: ページ本文4行を行ごとに抽出
- Info DAT Annotations: 注釈なしPDFで `(none)`(6列ヘッダは正しく出力)

## パラメータ

File / Page(0始まり・描画とText/Annotations共用)/ DPI / Info DAT Mode

## 注意

- **TouchDesigner Non-Commercial では未検証**。無償版は解像度が 1280x1280 に制限されるため、ページ描画（実測 1275x1650）が制限に掛かる。出力解像度を下げて回避する

- 座標系はPDFポイント(左下原点)
- 旧 **PDFKit DAT** は本TOPのInfo DATに統合され廃止(2026-07-21)

## ビルド

```
cd PDFKit && ./build.sh   # → build/PDFKitTOP.plugin
```
