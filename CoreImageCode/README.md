# CI Code TOP

**English** | [日本語](#日本語)

## English

Generates QR / Aztec / PDF417 / Code 128 barcodes with nothing but the stock Core Image
generators. No external library or model required.

### Output and parameters

BGRA8 image. Set Text, Code Type, QR Correction Level, Output Width/Height and Quiet Zone.
Scaling is integer and the code is centred, so its edges never get blurred. The Info CHOP
reports the generation count, the time taken and `valid`.

### Notes

Each symbology has its own payload length limit. On an invalid payload the previous image is
kept and a warning is raised. Measured on M2: the default QR is produced as 512x512 BGRA8 and
confirmed visually; about 918 ms including the first-time Core Image initialisation. The
steady-state figure has not been measured.

### Build

`./build.sh` → `build/CoreImageCodeTOP.plugin`

## 日本語

Core Image標準generatorだけでQR/Aztec/PDF417/Code 128を生成するCPUMem TOP。外部ライブラリやモデルは不要。

### 出力・パラメータ

BGRA8画像。Text、Code Type、QR Correction Level、Output Width/Height、Quiet Zoneを指定する。整数倍率・中央配置でコードのedgeをぼかさない。Info CHOPに生成回数、時間、validを出す。

### 注意

形式ごとに文字数制限が異なる。不正なpayloadでは直前の画像を保持してWarningを出す。M2実測で既定QRを512x512 BGRA8として生成・視認し、初回Core Image初期化込み約918ms。定常値は未計測。

### ビルド

`./build.sh` → `build/CoreImageCodeTOP.plugin`
