# Vision Classify DAT

**English** | [日本語](#日本語)

## English

Classifies the whole input TOP with Apple Vision's built-in `VNClassifyImageRequest`. No extra
model required.

### Output

A `rank | identifier | confidence` table, in descending confidence, up to Top Results rows.

### Parameters

| Name | Description |
|---|---|
| TOP | Input TOP |
| Active | Inference On/Off |
| Top Results | Output limit. Default 10, internal limit 100 |
| Minimum Confidence | Minimum confidence to output. Default 0.01 |
| Flip Image Vertically | Default On |

Info CHOP: `executes / submits / analyzes / analyze_ms / results`. Inference is asynchronous, and
even a still image is re-analysed when a processing parameter changes. The identifiers are Apple's
English labels and the taxonomy depends on the OS's Vision revision.

### Build

```sh
cd VisionClassify && ./build.sh
```

## 日本語

Apple Vision内蔵の`VNClassifyImageRequest`で入力TOP全体を分類するDAT。追加モデル不要。

### 出力

`rank | identifier | confidence`のテーブル。信頼度降順で最大Top Results行。

### パラメータ

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

### ビルド

```sh
cd VisionClassify && ./build.sh
```
