# VisionSubject TOP

入力 TOP の映像から**被写体(人に限らない前景オブジェクト)**を切り抜く。写真アプリの
「被写体をコピー」と同じ `VNGenerateForegroundInstanceMaskRequest`(macOS 14+)。
人物限定の [VisionSegment](../VisionSegment/) の汎用版。

## 実測(M2・1280x720)

- 解析 約45ms(≈20fps 相当)。非同期実行で TD 本体は 60fps を維持
- Soft Mask / Cutout は**入力と同解像度**で出力(VisionSegment より高解像度)

## モード

| Mode | 出力 | 内容 |
|---|---|---|
| Soft Mask | Mono32Float(入力解像度) | 全被写体の統合ソフトマスク(0〜1) |
| Cutout | BGRA(入力解像度) | 被写体を切り抜いた画像。**背景は透過**(そのまま Over COMP に載せられる) |
| Instance Masks | RGBA8(低解像度) | 被写体ごとのマスクを R/G/B/A に分離(最大4個) |

## パラメータ

| 名前 | 内容 |
|---|---|
| Active | 解析の実行 On/Off |
| Mode | 上記3モード |
| Flip Image Vertically | 入力の上下反転(既定On・必須) |

## Info CHOP

`executes / submits / analyzes / instances / analyze_ms`。`instances` は検出された被写体数。

## 注意

- **macOS 14+ 必須**(それ未満では警告表示のみ)
- 被写体なしのフレームでは黒(空)マスクを出力する
- 実装メモ: `generateMaskedImageOfInstances`(Cutout)は **IOSurface 非対応の
  CVPixelBuffer(CreateWithBytes ラップ)だと失敗する**。IOSurface 対応バッファに
  コピーしてから渡している(マスク系は生バッファでも通るので気づきにくい)

## ビルド

```
cd VisionSubject && ./build.sh   # → build/VisionSubjectTOP.plugin
```
