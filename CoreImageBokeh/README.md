# CI Bokeh TOP

入力画像とグレースケールマスクをCore ImageのMasked Variable Blurへ渡す非同期TOP。
VisionSubject/VisionSegmentのマスクから被写体を保った背景ぼかしを作れる。

実測（M2 / 640x426静止画）: 640x426 BGRA8を正立出力し、別のCore Image系TOPとの同時cookでも
エラー・警告・クラッシュなし。

## 入力・出力

入力0は画像、入力1はマスク。出力は入力0と同じ解像度のBGRA8 TOP。

## パラメータ

Blur Radius、Blur Background（白い被写体マスクを反転、既定On）、Flip（既定On）。
Info CHOPは`executes / submits / processes / process_ms / valid`。

## 注意

マスク解像度が異なる場合は入力画像へ合わせて拡大する。境界品質は前段マスクに依存する。

## ビルド

```sh
./build.sh
```
