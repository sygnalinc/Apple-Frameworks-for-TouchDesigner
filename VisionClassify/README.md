# Vision Classify DAT

Apple Vision内蔵の`VNClassifyImageRequest`で入力TOP全体を分類するDAT。追加モデル不要。

## 出力

`rank | identifier | confidence`のテーブル。信頼度降順で最大Top Results行。

## パラメータ

| 名前 | 内容 |
|---|---|
| TOP | 入力TOP |
| Active | 推論On/Off |
| Top Results | 出力上限。既定10、内部上限100 |
| Minimum Confidence | 出力する最低信頼度。既定0.01 |
| Flip Image Vertically | 既定On |

Info CHOPは`executes / submits / analyzes / analyze_ms / results`。推論は非同期で、
静止画でも処理パラメータ変更時に再解析する。識別子はApple定義の英語ラベルで、
カテゴリ体系はOSのVision revisionに依存する。

## ビルド

```sh
cd VisionClassify && ./build.sh
```
