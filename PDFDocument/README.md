# PDF Document DAT / TOP

**PDFKit** で PDF を扱う。**DAT** は構造(メタデータ/アウトライン/ページテキスト/注釈)をテーブル出力、
**TOP** は指定ページを BGRA8 に描画する。1フォルダから2バンドル(DAT/TOP、共に opType `Pdfdocument`)。

## 実測(M2)

- 2ページのテストPDF: DAT Info=`pages=2`ほか10行、Text=「Page One: TDAppleML PDF test...」を抽出、
  TOP=612×792pt を 100DPI で 850×1100 に描画

## DAT

| Mode | 出力 |
|---|---|
| Info | pages/title/author/subject/creator/producer/encrypted/locked/page0サイズ |
| Outline | level / title / page(ブックマーク階層) |
| Text | 指定ページのテキスト(Text DAT) |
| Annotations | type / x / y / w / h / contents(座標はPDFポイント・左下原点) |

パラメータ: File / Mode / Page(Text・Annotations用・0始まり)

## TOP

パラメータ: File / Page(0始まり) / DPI。白背景に指定ページを描画。Info CHOP: `executes / width / height`

## 注意
- 座標系はPDFポイント(左下原点)。TOPは白背景で描画
- DATのTextモードは Text DAT、他はTable DAT

## ビルド
```
cd PDFDocument && ./build.sh   # → PDFDocumentDAT.plugin + PDFDocumentTOP.plugin
```
