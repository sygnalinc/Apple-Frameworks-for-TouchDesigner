# TextAnalyze DAT

入力 DAT のテキストを **NaturalLanguage フレームワーク**でオンデバイス解析する。
SpeechText(文字起こし)と直結して「**発話の感情・話題でビジュアルを制御**」できる。
[VisionSimilarity](../VisionSimilarity/)(画像の類似トリガー)のテキスト版。

## 実測(M2)

- 英文16語の解析(感情+固有表現+埋め込み類似度)で数ms〜数十ms級。
  文埋め込みの初回ロードのみ時間がかかる(非同期なのでcookは止まらない)
- 実測例: "Tim Cook visited Tokyo and met the Sony team. It was a wonderful and
  exciting day." → sentiment **+1.0**、person=**Tim Cook**、place=**Tokyo**、
  organization=**Sony**、words=16

## 出力テーブル(key / value)

| key | value |
|---|---|
| language | 判定言語(en/ja/...) |
| sentiment | 感情スコア -1〜+1(**英語等のみ。日本語は未対応で0**) |
| similarity | Reference Text との意味的類似度 0〜1(Reference Text 設定時のみ) |
| words | 語数 |
| person / place / organization | 固有表現(検出数ぶん行が続く) |

数値は Info CHOP(`sentiment / similarity / entities`)からも取れる。

## パラメータ

| 名前 | 内容 |
|---|---|
| Active | 解析 On/Off |
| Text Source | Last Row(既定・ライブ字幕向け)/ All Rows |
| Reference Text | 類似度の比較対象テキスト。「この話題に近づいたら発火」に使う |

入力DATに `text` という名前の列があればその列、無ければ最終列を読む
(SpeechText の出力テーブルにそのまま繋がる)。

## 注意

- **日本語の類似度対応**: 参照テキストとの類似度は第一候補として
  `NLContextualEmbedding`(BERT系・macOS 14+・**日本語対応**)で計算する
  (実測: 「照明システムの話」vs「舞台照明と演出技術」= 0.64)。
  初回はアセットDLの警告が出ることがある(自動DL・次回から有効)。
  非対応言語/OSでは従来のNLEmbedding文埋め込みへフォールバック

- 感情スコアは Apple の対応言語のみ(英語ほか。**日本語は常に0**)。日本語運用は
  Translate DAT で英訳してから食わせるワークアラウンドがある
- 類似度は文埋め込みのコサイン距離(0〜2)を `1 - d/2` で 0〜1 化した相対値。
  絶対的なしきい値はコンテンツで調整する(実測: 関連話題で0.33程度)
- 文埋め込みが未対応の言語では similarity 行が出ず警告表示

## ビルド

```
cd TextAnalyze && ./build.sh   # → build/TextAnalyzeDAT.plugin
```
