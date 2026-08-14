# Text Analyze DAT

**English** | [日本語](#日本語)

## English

Analyses the text of an input DAT on-device with the **NaturalLanguage framework**. Wire it
straight to Speech Transcribe and you can **drive visuals from the sentiment or topic of
what is being said**.

### Measured (M2)

- Analysing a 16-word English sentence (sentiment + named entities + embedding similarity) takes
  from a few to a few tens of milliseconds. Only the first load of the sentence embedding is slow
  (asynchronous, so cook never stalls)
- Example: "Tim Cook visited Tokyo and met the Sony team. It was a wonderful and exciting day." →
  sentiment **+1.0**, person = **Tim Cook**, place = **Tokyo**, organization = **Sony**, words = 16

### Output table (key / value)

| key | value |
|---|---|
| language | Detected language (en/ja/…) |
| sentiment | Sentiment score -1 to +1 (**English and similar only; Japanese is unsupported and returns 0**) |
| similarity | Semantic similarity to Reference Text, 0–1 (only when Reference Text is set) |
| words | Word count |
| person / place / organization | Named entities (one row per detection) |

The numbers are also on the Info CHOP
(`sentiment / similarity / entities / token_count / embedding_dim`).

### Output modes (tokens / embedding)

The `Output` menu switches what the table contains:

- **summary** (default): the key/value above
- **tokens**: `index / token / pos (part of speech) / lemma / start / length`.
  Measured: "visited" → pos = Verb, lemma = **visit** (lemmatisation works). `Max Tokens` caps it
- **embedding**: the sentence embedding vector as an `index / value` numeric list (NLEmbedding's
  sentence embedding, falling back to NLContextualEmbedding for languages it cannot handle).
  Measured: a **512-dimension** real vector for English. This is the text counterpart of image
  vectorisation

### Parameters

| Name | Description |
|---|---|
| Active | Analysis On/Off |
| Text Source | Last Row (default, for live subtitles) / All Rows |
| Reference Text | The text to compare against for similarity. Use it for "fire when the topic gets close to this" |
| Output | Summary / Tokens (token/POS/lemma) / Embedding Vector |
| Max Tokens | Maximum tokens in tokens mode |

If the input DAT has a column named `text` that column is read; otherwise the last column is
(so Speech Transcribe's output table connects directly).

### Notes

- **Japanese similarity**: similarity against the reference text is computed first with
  `NLContextualEmbedding` (BERT-family, macOS 14+, **Japanese supported**) — measured: "a talk
  about lighting systems" vs "stage lighting and production technique" = 0.64. The first run may
  warn about an asset download (it downloads automatically and works from then on). Unsupported
  languages/OS versions fall back to the older NLEmbedding sentence embedding

- Sentiment scores exist only for Apple's supported languages (English and others; **Japanese is
  always 0**). For Japanese, one workaround is to translate to English with the Translate DAT first
- Similarity is the cosine distance of the sentence embeddings (0–2) mapped to 0–1 as `1 - d/2`,
  so it is relative. Tune the absolute threshold to your content (measured: about 0.33 for related
  topics)
- For languages with no sentence embedding, the similarity row is omitted and a warning is shown

### Build

```
cd TextAnalyze && ./build.sh   # → build/TextAnalyzeDAT.plugin
```

## 日本語

入力 DAT のテキストを **NaturalLanguage フレームワーク**でオンデバイス解析する。
Speech Transcribe(文字起こし)と直結して「**発話の感情・話題でビジュアルを制御**」できる。

### 実測(M2)

- 英文16語の解析(感情+固有表現+埋め込み類似度)で数ms〜数十ms級。
  文埋め込みの初回ロードのみ時間がかかる(非同期なのでcookは止まらない)
- 実測例: "Tim Cook visited Tokyo and met the Sony team. It was a wonderful and
  exciting day." → sentiment **+1.0**、person=**Tim Cook**、place=**Tokyo**、
  organization=**Sony**、words=16

### 出力テーブル(key / value)

| key | value |
|---|---|
| language | 判定言語(en/ja/...) |
| sentiment | 感情スコア -1〜+1(**英語等のみ。日本語は未対応で0**) |
| similarity | Reference Text との意味的類似度 0〜1(Reference Text 設定時のみ) |
| words | 語数 |
| person / place / organization | 固有表現(検出数ぶん行が続く) |

数値は Info CHOP(`sentiment / similarity / entities / token_count / embedding_dim`)からも取れる。

### Output モード(tokens / embedding)

`Output` メニューでテーブルの内容を切り替える:

- **summary**(既定): 上記 key/value
- **tokens**: `index / token / pos(品詞) / lemma(見出し語) / start / length`。
  実測: "visited" → pos=Verb・lemma=**visit**(見出し語化が機能)。`Max Tokens` で上限
- **embedding**: 文埋め込みベクトルを `index / value` の数値列で出力(NLEmbedding の
  sentence embedding。使えない言語は NLContextualEmbedding へフォールバック)。
  実測: 英文で **512次元**の実数ベクトルを取得。画像のベクトル化に対応する
  「テキストのベクトル化」に使える

### パラメータ

| 名前 | 内容 |
|---|---|
| Active | 解析 On/Off |
| Text Source | Last Row(既定・ライブ字幕向け)/ All Rows |
| Reference Text | 類似度の比較対象テキスト。「この話題に近づいたら発火」に使う |
| Output | Summary / Tokens(token/POS/lemma)/ Embedding Vector |
| Max Tokens | tokens モードの最大トークン数 |

入力DATに `text` という名前の列があればその列、無ければ最終列を読む
(Speech Transcribe の出力テーブルにそのまま繋がる)。

### 注意

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

### ビルド

```
cd TextAnalyze && ./build.sh   # → build/TextAnalyzeDAT.plugin
```
