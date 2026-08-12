# LLM AFM DAT — Apple Intelligence on-device LLM (macOS 26+)

**English** | [日本語](#日本語)

## English

A TD custom DAT that generates text with Apple's **FoundationModels framework** (the ~3B
on-device LLM behind Apple Intelligence). **Fully on-device, no API billing, no network.**

The name follows the framework so that adding other LLM integrations later (external APIs and so
on) as separate operators will not clash.

Measured (M2): Japanese live-commentary text generated in a few seconds, streamed.

### Output table (conversation history)

```
index | role      | text
0     | user      | The crowd noise level has risen to 0.9 — commentate.
1     | assistant | The crowd erupts, the level reaching all the way to 0.9. …
```

While generating, the last assistant row **grows as it streams** (feed it into a Text TOP for a
typewriter effect).

### Parameters

| Parameter | Default | Description |
|---|---|---|
| Instructions (System) | — | System instructions (role, tone…). Changing it rebuilds the session |
| Prompt | — | Input text |
| Temperature | 0.7 | Randomness |
| Max Tokens | 512 | Maximum tokens to generate |
| Keep Context (Multi-turn) | On | Keep conversational context. Off = each exchange is independent |
| Max Rows | 50 | History rows to keep |
| Submit | — | Run generation (ignored while busy) |
| Clear Conversation | — | Reset the history and session |

Info CHOP: `executes / busy / turns`. Info DAT: `status` (ready / generating /
unavailable: Apple Intelligence not enabled, …) — Apple Intelligence must be enabled on the
device.

### Structured output

Write `name:type` lines into Output Schema (type: string|number|int|bool) and the output becomes
**schema-guaranteed JSON**, expanded as `field` rows at the top of the table.

Measured: Instructions "you are a lighting designer" + "make it bright red and strobing,
excited" + Schema `color:string / intensity:number / strobe:bool` → **color=red / intensity=100 /
strobe=1**. Pull out just the `field` rows with a Select DAT and wire them straight into show
control.

### Tool calling (TD becomes the tool runtime)

Turn on `Enable Tool Calling` and the LLM is given one **tool**. When the LLM calls it,
**TouchDesigner runs the tool and returns the result**, and the LLM answers using that result.

- Define the tool with `Tool Name` / `Tool Description` / `Tool Params` (`name:type`, one per line)
- When the LLM calls it, `pending_tool` / `pending_tool_args` (the argument JSON) rows appear in
  the output table (Info CHOP `tool_pending=1`)
- Your TD side (a Python DAT Execute, say) reads `pending_tool_args`, computes the value, writes
  the result (JSON etc.) into `Tool Result` and pulses `Return Tool Result` — generation resumes

Measured: tool `get_sensor` (`name:string`) + prompt "report the temperature sensor" → the LLM
requests `get_sensor({"name":"temperature"})` → TD returns `{"value":42,"unit":"celsius"}` → the
LLM answers **"The current temperature in the show is 42 degrees Celsius."** This is how you wire
reading and driving TD nodes to the LLM through an explicit tool schema.

Note: the on-device model is small, so a vague question ("what is the temperature?") may make it
answer "I have no sensor" instead of calling the tool. Naming the tool in the prompt makes it
call reliably. `demo.toe`'s `/project1/LLMAFM` shows both cases side by side in a chat view.

**The context window is small too.** A long `Instructions` plus a few turns with Keep Context on
is enough to produce `status: error: Exceeded model context window size` (measured with a
~40-word Instructions and three turns). Keep the instructions short and pulse
`Clear Conversation` when it happens.

### Where it fits (generation chains with other operators)

- **Live commentary**: turn Sound Class (cheering) or Vision Pose (movement) values into a
  sentence with a CHOP Execute, feed it as the Prompt, and put the commentary in a Text TOP
- **Expanding an ImageGen prompt**: have it turn a situation description into an English SD
  prompt for CoreML ImageGen's Prompt (Instructions: "return only an English Stable Diffusion
  prompt")
- For structured results, either use Output Schema above or instruct "reply in JSON only" and
  parse the DAT

### Build

```
./build.sh    # → build/LLMAFMDAT.plugin (bundles the Swift helper dylib; needs the macOS 26 SDK)
```

## 日本語

Apple の **FoundationModels framework**（Apple Intelligence の ~3B オンデバイスLLM）で
テキスト生成する TD カスタム DAT。**完全オンデバイス・API課金なし・ネットワーク不要**。

名前をフレームワーク名に合わせているのは、将来ほかのLLM統合（外部API等）を
別OPとして足すときに衝突しないようにするため。

実測（M2）: 日本語の実況テキスト生成が数秒・ストリーミングで出力。

### 出力テーブル（会話履歴）

```
index | role      | text
0     | user      | 観客の歓声レベルが0.9まで上がり…実況して。
1     | assistant | 観客の歓声が上がり、その高さはなんと0.9まで到達した。…
```

生成中は最後の assistant 行が**ストリーミングで伸びていく**（Text TOP に流せば
タイプライター演出になる）。

### パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| Instructions (System) | — | システム指示（役割・口調など。変更するとセッションが作り直される） |
| Prompt | — | 入力テキスト |
| Temperature | 0.7 | ランダム性 |
| Max Tokens | 512 | 最大生成トークン |
| Keep Context (Multi-turn) | On | 会話の文脈を保持。オフなら毎回独立した1問1答 |
| Max Rows | 50 | 保持する履歴行数 |
| Submit | — | 生成実行（busy 中は無視） |
| Clear Conversation | — | 履歴とセッションをリセット |

Info CHOP: `executes / busy / turns`。Info DAT: `status`
（ready / generating / unavailable: Apple Intelligence not enabled 等 — 端末側で
Apple Intelligence を有効にしておく必要がある）。

### 構造化出力

Output Schema に `name:type` を改行区切りで書くと(type: string|number|int|bool)、
出力が**スキーマ保証のJSON**になり、テーブル先頭に `field` 行として展開される。

実測: Instructions「照明デザイナー」+「真っ赤で激しく点滅する興奮した雰囲気にして」
+ Schema `color:string / intensity:number / strobe:bool`
→ **color=red / intensity=100 / strobe=1**。
Select DAT で `field` 行だけ抜けばそのままショー制御に接続できる。

### ツール呼び出し(Tool Calling・TDがツール実行系になる)

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

注意: オンデバイスモデルは小さいので、「今の温度は?」のような曖昧な聞き方だと**ツールを使わず**
「センサーがありません」と答えることがある。プロンプトでツール名を明示すると確実に呼ぶ。
`demo.toe` の `/project1/LLMAFM` は、この両方をチャット画面で並べて見せている。

**コンテキスト窓も小さい。** 長い `Instructions` + Keep Context で数ターン続けるだけで
`status: error: Exceeded model context window size` になる(40語程度の Instructions と
3ターンで実測)。Instructions は短くし、出たら `Clear Conversation` をパルスする。

### 使いどころ（他OPとの生成チェーン）

- **ライブ実況**: SoundClass（歓声）や VisionPose（動き量）の値を CHOP Execute で
  文章化して Prompt に流し込み → 実況コメントを Text TOP へ
- **ImageGen のプロンプト展開**: 状況説明を英語のSDプロンプトに変換させて
  CoreML ImageGen TOP の Prompt へ（Instructions に「英語のStable Diffusionプロンプトだけを返せ」）
- 構造化したい場合は上記の Output Schema を使うか、Instructions で「JSONのみで返答」と
  指示して DAT を JSON パースする

### ビルド

```
./build.sh    # → build/LLMAFMDAT.plugin（Swift ヘルパ dylib 同梱・要 macOS 26 SDK）
```
