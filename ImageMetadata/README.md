# ImageMetadata DAT

画像ファイルの**メタデータ(EXIF・GPS・TIFF・IPTC・PNG)**を key/value テーブルで出力
(ImageIO)。撮影日時・GPS座標・カメラ機種・露出などを演出パラメータとして使える。

**TOPパイプラインを通るとメタデータは失われる**ため、ファイルパス指定で直接読む。

## 出力

- 基本情報: `pixelwidth / pixelheight / dpiwidth / colormodel / depth`
- GPSがあれば十進度に変換した `gps:latitude_deg / gps:longitude_deg` を先頭に
- 以降 `exif:FNumber` `tiff:Model` 形式でフラットに列挙(辞書はネスト展開)

## パラメータ

| 名前 | 内容 |
|---|---|
| Active | On/Off |
| Image File | 画像ファイル。**更新時刻の変化で自動再読込** |

Info CHOP: `executes / reads / keys`

## 注意

- EXIFの無い画像(書き出しでストリップ済み等)は基本情報のみになる
- 対応形式は ImageIO 準拠(JPEG/HEIC/PNG/TIFF/RAW各種)

## ビルド

```
cd ImageMetadata && ./build.sh   # → build/ImageMetadataDAT.plugin
```
