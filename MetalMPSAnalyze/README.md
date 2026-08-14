# Metal MPS Analyze CHOP

Metal Performance ShadersのGPU histogramと軽量な輝度統計を出力する画像解析CHOP。

実測（M2 / 640x426静止画）: mean_luma 0.4895、std_luma 0.2976、
dark 0.2589、midtone 0.5129、bright 0.2282。

## 出力

`valid`、RGBA平均、平均/標準偏差/最小/最大輝度、dark/midtone/bright比率、
RGBA各16binの正規化ヒストグラム。合計76ch・1sample。

## パラメータ

TOP、Active、Flip（既定On）。Info CHOPは
`executes / submits / analyzes / analyze_ms / pixels`。

## 注意

GPU histogram後の読戻しはワーカースレッドで待機するためcookをブロックしない。
輝度統計はRec.709係数でBGRA8入力から計算する。

## ビルド

```sh
./build.sh
```
