# Vision Similarity CHOP

Apple Vision Feature Printで2つのTOPを比較し、モデル追加なしで画像の距離と類似度を出力する。

実測（M2 / 同一640x426画像）: distance 0.0、similarity 1.0、match 1.0。

## 出力

`valid / distance / similarity / match`。`match`はdistanceがThreshold以下で1。
similarityは扱いやすい表示値として`exp(-distance/10)`へ変換する。

## パラメータ

TOP、Reference TOP、Distance Threshold、Flip（既定On）。Info CHOPは
`executes / submits / analyzes / analyze_ms`。

## 注意

距離はVision Feature Print固有の尺度であるため、素材ごとに実測してThresholdを決める。

## ビルド

```sh
./build.sh
```
