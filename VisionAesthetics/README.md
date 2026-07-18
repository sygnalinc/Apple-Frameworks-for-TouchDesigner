# VisionAesthetics CHOP

画像の「写真としての良さ」を推定(VNCalculateImageAestheticsScoresRequest・macOS 15+)。
複数カメラ/候補カットからの**自動ベストショット選択**、スクリーンショット等の
実用画像判定に。

## 実測(M2・1280x720)

- OilDrums.jpg → score 0.381・utility 1。解析は数十ms級・非同期

## 出力チャンネル

| チャンネル | 内容 |
|---|---|
| valid | 解析済み=1 |
| score | 美的スコア -1〜+1(高いほど「良い写真」) |
| utility | 実用画像(書類・スクショ等)=1 |

パラメータ: TOP / Active / Flip(既定On)。
Info CHOP: `executes / submits / analyzes / analyze_ms`

## ビルド

```
cd VisionAesthetics && ./build.sh   # → build/VisionAestheticsCHOP.plugin
```
