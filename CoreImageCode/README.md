# CoreImageCode TOP

Core Image標準generatorだけでQR/Aztec/PDF417/Code 128を生成するCPUMem TOP。外部ライブラリやモデルは不要。

## 出力・パラメータ

BGRA8画像。Text、Code Type、QR Correction Level、Output Width/Height、Quiet Zoneを指定する。整数倍率・中央配置でコードのedgeをぼかさない。Info CHOPに生成回数、時間、validを出す。

## 注意

形式ごとに文字数制限が異なる。不正なpayloadでは直前の画像を保持してWarningを出す。M2実測で既定QRを512x512 BGRA8として生成・視認し、初回Core Image初期化込み約918ms。定常値は未計測。

## ビルド

`./build.sh` → `build/CoreImageCodeTOP.plugin`
