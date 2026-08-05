# LLM AFM DAT — Apple Intelligence LLM（macOS 26+ / AFM3対応 macOS 27+）

Apple の **FoundationModels framework**（Apple Intelligence のオンデバイスLLM）で
テキスト生成する TD カスタム DAT。**完全オンデバイス・API課金なし・ネットワーク不要**
（Private Cloud Compute 選択時のみネットワーク使用）。

名前をフレームワーク名に合わせているのは、将来ほかのLLM統合（外部API等）を
別OPとして足すときに衝突しないようにするため。

実測（M2）: 日本語の実況テキスト生成が数秒・ストリーミングで出力。

## macOS 27(AFM3世代)の新機能

macOS 27 では FoundationModels が新世代モデル(AFM3)と拡張APIになり、本OPは以下に対応:

| 機能 | 内容 |
|---|---|
| **Model メニュー** | `On-Device (AFM)` / `Private Cloud Compute`(Appleサーバ側の大型モデル・`PrivateCloudComputeLanguageModel`) |
| **画像入力(Vision)** | Vision ページの `Image TOP` + `Use Image`。TOPの画像をプロンプトに添付(AFM3 は `capabilities.vision` 対応) |
| **Reasoning** | `Off / Light / Moderate / Deep`(`ContextOptions.ReasoningLevel`)。推論を深くする |
| **診断** | Info DAT に `model` / `capabilities`(vision reasoning toolCalling guidedGeneration)、Info CHOP に `context_size / input_tokens / output_tokens` |

**macOS 26 互換は維持**: 27専用APIは全て `#available(macOS 27.0, *)` ガード付きで、
26 では従来どおりのテキスト生成・構造化出力・Tool Calling が動く。27専用機能
(PCC / 画像 / Reasoning)を26で選ぶと status にエラーメッセージが出るだけでクラッシュしない。
画像は Submit 時に BGRA8(top-down)でダウンロードして `Attachment(CGImage)` として添付する。

## 出力テーブル（会話履歴）

```
index | role      | text
0     | user      | 観客の歓声レベルが0.9まで上がり…実況して。
1     | assistant | 観客の歓声が上がり、その高さはなんと0.9まで到達した。…
```

生成中は最後の assistant 行が**ストリーミングで伸びていく**（Text TOP に流せば
タイプライター演出になる）。

## パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| Instructions (System) | — | システム指示（役割・口調など。変更するとセッションが作り直される） |
| Prompt | — | 入力テキスト |
| Temperature | 0.7 | ランダム性 |
| Max Tokens | 512 | 最大生成トークン |
| Keep Context (Multi-turn) | On | 会話の文脈を保持。オフなら毎回独立した1問1答 |
| Model | ondevice | 生成モデル(macOS 27): On-Device (AFM) / Private Cloud Compute |
| Reasoning | off | 推論レベル(macOS 27): Off / Light / Moderate / Deep |
| Image TOP (Visionページ) | — | プロンプトに添付する画像TOP(macOS 27・vision対応モデル) |
| Use Image (Visionページ) | Off | Onで Submit 時に Image TOP を添付(Tool Calling とは併用不可) |
| Max Rows | 50 | 保持する履歴行数 |
| Submit | — | 生成実行（busy 中は無視） |
| Clear Conversation | — | 履歴とセッションをリセット |

Info CHOP: `executes / busy / turns / tool_pending / context_size / input_tokens /
output_tokens`。Info DAT: `status / model / capabilities`
（ready / generating / unavailable: Apple Intelligence not enabled 等 — 端末側で
Apple Intelligence を有効にしておく必要がある。PCC は加えてネットワークと
対象デバイスであることが必要で、不可なら `device not eligible (PCC)` 等が出る）。

## 構造化出力

Output Schema に `name:type` を改行区切りで書くと(type: string|number|int|bool)、
出力が**スキーマ保証のJSON**になり、テーブル先頭に `field` 行として展開される。

実測: Instructions「照明デザイナー」+「真っ赤で激しく点滅する興奮した雰囲気にして」
+ Schema `color:string / intensity:number / strobe:bool`
→ **color=red / intensity=100 / strobe=1**。
Select DAT で `field` 行だけ抜けばそのままショー制御に接続できる。

## ツール呼び出し(Tool Calling・TDがツール実行系になる)

`Enable Tool Calling` をオンにすると、LLM に**ツール**を1つ渡せる。LLM がそのツールを
呼ぶと **TouchDesigner 側がツールを実行して結果を返し**、LLM がその結果を使って回答する。

- `Tool Name` / `Tool Description` / `Tool Params`(`name:type` 改行区切り)でツールを定義
- LLM がツールを呼ぶと、出力テーブルに `pending_tool` / `pending_tool_args`(引数JSON)行が出る
  (Info CHOP `tool_pending=1`)
- TD 側(Python の DAT Execute 等)が `pending_tool_args` を見て値を算出し、
  `Tool Result` に結果(JSON等)を書いて `Return Tool Result` をパルス → 生成が再開する

実測: ツール `get_sensor`(`name:string`)+ Prompt「temperature センサーの値を報告して」
→ LLM が `get_sensor({"name":"temperature"})` を要求 → TD が `{"value":42,"unit":"celsius"}`
を返す → LLM が **"The current temperature in the show is 42 degrees Celsius."** と回答。
これで LLM から TD ノードの読取/操作を明示的な tool schema で接続できる。

## 使いどころ（他OPとの生成チェーン）

- **ライブ実況**: SoundClass（歓声）や VisionPose（動き量）の値を CHOP Execute で
  文章化して Prompt に流し込み → 実況コメントを Text TOP へ
- **ImageGen のプロンプト展開**: 状況説明を英語のSDプロンプトに変換させて
  ImageGen TOP の Prompt へ（Instructions に「英語のStable Diffusionプロンプトだけを返せ」）
- 構造化したい場合は Instructions で「JSONのみで返答」と指示して DAT を JSON パース

## ビルド

```
./build.sh    # → build/FoundationModelDAT.plugin（Swift ヘルパ dylib 同梱・要 macOS 26 SDK）
```
