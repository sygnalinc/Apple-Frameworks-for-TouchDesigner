# Image Capture DAT

`ImageCaptureCore` の `ICDeviceBrowser` で、接続中の**カメラ(テザー撮影対応DSLR等)/スキャナ**を列挙し、
名前/種別/UUID/トランスポートをテーブル出力する。テザー撮影・スキャナ制御の足場。

## 出力(テーブルDAT)

`name / type(camera|scanner) / uuid / transport`。Info CHOP: `executes / devices`

## 注意

- **テザー接続したDSLR/スキャナが必要**(未接続だと0件)。カメラ/写真へのアクセスに TCC 権限が要る場合がある
- デバイス発見は非同期(delegate)。接続/切断で行が増減する
- 撮影トリガー・画像転送は次版の拡張ポイント(ICCameraDevice のセッション制御)

## ビルド
```
cd ImageCapture && ./build.sh
```
