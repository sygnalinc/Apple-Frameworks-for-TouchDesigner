# CoreAI TOP / CoreAI LLM DAT

**English** | [日本語](#日本語)

## English

Run any **Core AI** model (`.aimodel`, macOS 27+) on a TOP. The Core AI counterpart of the CoreML TOP:
load a model, feed the input TOP to its image input, pick an output, get it back as a
Mono32Float / RGBA32Float texture. The model's inputs and outputs are self-describing
(shape / dtype), so nothing is hard-coded per model — depth estimation, super-resolution,
segmentation and similar single-function image models work as-is.

> **Status: experimental (macOS 27+).** Not included in the DMG (`PLUGINS.tsv` is the single source
> of truth). Verified with Depth Anything v3, EDSR x2 and YOLOS on an M2 / macOS 27.0, but Core AI
> itself is new in macOS 27 and the op has not had wider testing.

- Input 0 = image. It is resized to the model's input size, normalized and packed as NCHW / NHWC,
  float32 or float16 — whatever the descriptor says. Batch / view dims (`[1,V,3,H,W]`) get the
  same image in every slot.
- Output = the selected output tensor as an image: `[H,W]` → Mono, `[C,H,W]` / `[H,W,C]` with
  C = 1..4 → Mono / RGBA (C = 2 fills R and G). `Channel` picks one channel as Mono.
  Outputs that are not image-shaped (logits, boxes, matrices) give a warning — that is what a
  future CoreAI CHOP is for.
- Loading and inference are asynchronous (never block cook); the result arrives 1–2 frames later,
  and a new frame is only submitted when the previous one has finished.
- **On macOS 26 the op loads but does nothing** (status `unavailable: Core AI requires macOS 27+`).
  The framework is weak-linked so the bundle itself never fails to load.

### Getting a model

Core AI models are exported, not downloaded: Apple's
[coreai-models](https://github.com/apple/coreai-models) repository has a recipe per model that
fetches the original weights from Hugging Face and converts them on your Mac. For the example in
`demo.toe` (Depth Anything v3 small, about 100 MB):

```bash
brew install uv
git clone https://github.com/apple/coreai-models.git
cd coreai-models/models/depth-anything && uv run export.py
cp -R ../../exports/da3-small_float32.aimodel <this repo>/models/
```

The first `uv run` creates a Python environment with PyTorch (a few minutes). Every folder under
`coreai-models/models/` has the same `uv run export.py` — `edsr` (2x super-resolution),
`yolo`, `sam3`, `clip`, … Anything with an image input can be loaded here; the Info DAT shows the
model's actual inputs and outputs so you can see what you got.

### Measured (M2, macOS 27.0)

| Model | Input | Output | Preprocess | Inference | Load |
|---|---|---|---|---|---|
| da3-small (Depth Anything v3) | float32 `[1,2,3,224,224]` | depth `[1,2,224,224]` | 2–10 ms | **60–100 ms** (auto / Neural Engine), 220 ms (CPU) | 0.3 s (cached) – 2.5 s |
| edsr_r16f64_x2 | float32 `[1,3,16,16]` | `[1,3,32,32]` | 6 ms | 6 ms (first run 2 s) | 0.2 s |
| yolos-base | float16 `[1,3,800,800]` | logits `[1,100,92]`, boxes | 8 ms | ~3 s | 2.8 s |

Inference time is `run_ms` in the Info CHOP; `pre_ms` / `post_ms` are the op's own conversion
cost. The first inference after a load includes on-device compilation and is slower.

### Parameters

| Name | Description |
|---|---|
| Active | On/Off |
| Model (.aimodel) | Path to a `.aimodel` / `.aimodelc` package (folder picker — `.aimodel` is a directory) |
| Function | Function name inside the model (`main` for everything exported by coreai-models) |
| Compute Units | Auto / CPU Only / Prefer GPU / Prefer Neural Engine (`SpecializationOptions`) |
| Reload Model | Pulse: reload the model |
| Input Normalize | 0 to 1 / -1 to 1 / ImageNet Mean-Std / 0 to 255 — must match what the model was trained with |
| Output | Which output to show (menu fills in after the model has loaded; `auto` = first output) |
| Channel (0=All) | 0 = all channels as Mono/RGBA, N = channel N-1 as Mono |
| Output Range | Auto (per-frame min-max) / Raw (values as they are) / Manual (Range Min–Max) |
| Invert | 1 − value (e.g. turn depth into near-is-bright) |
| Flip Vertically | On by default (model output is top-down; TD textures are bottom-up) |

### Info CHOP / Info DAT

Info CHOP: `executes submits results busy loaded loading inference_ms load_ms width height channels
serial pre_ms run_ms post_ms`. `results` following `submits` means no dropped frames.

Info DAT: `status`, `stage`, model path, function list, compute units, device architecture
(`h14g` on M2), the model's description / author / license from the asset metadata, and one row
per input and output with `kind / dtype / shape`.

### Notes

- Dynamic-shape inputs (`--dynamic` exports) are not supported yet; use a static export.
- Image (`CVPixelBuffer`) inputs are not supported yet; the exports in coreai-models all use
  NDArray inputs.
- Grayscale inputs (`C = 1`) are converted with BT.601 weights.
- The op keeps the Core AI compilation cache the OS provides (`AIModelCache`); the second load of
  the same model is much faster than the first.

## CoreAI LLM DAT

The same folder also builds **CoreAI LLM DAT** (opType `Coreaillm`): a chat DAT that runs the
LLM / VLM bundles exported by Apple's [coreai-models](https://github.com/apple/coreai-models)
(Qwen3, Gemma 3, Mistral, Phi-4, Qwen3-VL …) fully on-device through Core AI. It is the Core AI
counterpart of LLM MLX: the model runs in a **spawned helper process** (`coreai-llm-helper`,
built from the coreai-models Swift package), tokens stream into the conversation table, and the
multi-GB model plus its Metal state never live inside the TouchDesigner process.

- Output table: `index / role / text` (+ `think` column when *Show Thinking Column* is on)
- **Model Bundle** is the `exports/<name>` **folder** (contains `metadata.json`, the `.aimodel`
  and `tokenizer/`), not the `.aimodel` itself
- **Image input** (Vision page): with *Use Image Input* on, the *Image TOP* is captured at Submit
  and sent to the model. Needs a VLM bundle (`kind = vlm` in the Info DAT); text-only models
  report an error. Only the **latest** image is kept in the conversation; each VLM turn re-encodes
  the image and replays the whole conversation (the engine's KV cache cannot be reused across
  image turns), so multi-turn VLM chat gets slower as the history grows
- **Enable Thinking**: reasoning models (Qwen3) emit `<think>…</think>`; off (default) appends
  `/no_think` and the visible answer starts immediately. Thinking text goes to the `think` column
- Info CHOP: `executes busy ready progress turns tokens_per_sec ttft_sec last_tokens context_length`.
  Info DAT: `status / model / kind / context_length`

### Getting an LLM / VLM bundle

Same tool as the TOP models — clone coreai-models and run its exporter; the bundle lands in
`exports/<name>/`:

```bash
cd coreai-models/models/qwen3 && uv run export.py            # → exports/mac/qwen3_1_7b_4bit_dynamic
cd coreai-models/models/qwen3_vl && uv run export.py         # → exports/vlm-fp16/qwen3_vl_2b
```

Point *Model Bundle* at that folder (an expression like
`project.folder + '/models/qwen3_1_7b_4bit_dynamic'` keeps it relative to the .toe).

### Measured (M2 24 GB, macOS 27.0, helper standalone unless noted)

Every LLM / VLM export in a local coreai-models checkout was run through the helper
(`Name one primary color in one short sentence.`, greedy, thinking off):

| Bundle | Load (first / cached) | Generation | Result |
|---|---|---|---|
| qwen3_1_7b_4bit | 36 s / 3 s | 34 tok/s standalone, **4–10 tok/s inside TD** | OK, multi-turn |
| qwen3_4b_4bit | — / 7 s | 7.8 tok/s | OK (`/no_think` honored) |
| qwen3_8b_4bit | — | 4.2 tok/s | OK |
| gemma_3_4b_it_4bit | 67 s / 7–11 s | 7.4 tok/s | OK after the stop-token fix below |
| gemma_3n_e2b_it_4bit | — | 3.0 tok/s | OK |
| mistral_7b_instruct_v0_3_4bit | — | 0.7 tok/s | OK but swapping (4 GB model + TD resident) |
| gpt_oss_20b | — | 1.8 tok/s | OK, 10 GB swap; Harmony `<|channel|>analysis` is not parsed as thinking |
| phi_4_mini_instruct_4bit | 15 s | 1.0 tok/s | **broken export** — degenerate repetition; llm-runner gives the same and logs `RoPE freqs shape [48] must match half_embed [64]` |
| qwen3_vl_2b (fp16, VLM) | 140 s / 19 s | 5–8 tok/s, image encode ≈ 4 s | OK inside TD: correct object list from a 1280×720 frame |
| community gemma-4-E2B | — | — | **unsupported**: model takes 4 inputs (`ple_table`, `ple_scale`) the standard engine does not feed |
| community gemma-4-12B (mm) | — | — | **unsupported**: Core AI's compiler aborts (`LLVM ERROR: cannot unwrap empty odiec_module_t`) — bundle built with a different toolchain; the helper dies and the DAT reports `helper exited` |

Generation inside TD is slower than the standalone helper by a large factor (4–10 vs 34 tok/s
for the same 1.7B model). Not explained yet — probably GPU contention with TD's own rendering.
Rates above 4B parameters are dominated by memory pressure on a 24 GB machine with TD resident.

### Notes

- **Context is small and there is no truncation**: when the prompt exceeds `context_length` the
  op reports an error; use *Reset Conversation*
- Loading a new bundle resets `ready` / `progress` / `kind`; the helper reports progress while
  Core AI compiles the model (first load of a 7B model can take minutes)
- **Stop tokens**: coreai-models' exporter strips `added_tokens_decoder` from `tokenizer_config.json`,
  so the library's `additionalStopTokenIds` finds nothing and Gemma keeps emitting `<end_of_turn>`
  forever (llm-runner has the same problem with these exports). The helper therefore looks up the
  well-known turn-end tokens (`<end_of_turn>`, `<|im_end|>`, `<|eot_id|>`, `<|end|>`, …) in the vocab
  directly; the IDs it found are in the `ready` event (`stops`)
- Diffusion bundles (FLUX) are out of scope for this DAT

## 日本語

任意の **Core AI** モデル(`.aimodel`・macOS 27+)を TOP で回す。CoreML TOP の Core AI 版で、
モデルをロードし、入力 TOP をモデルの画像入力に流し込み、選んだ出力を Mono32Float / RGBA32Float の
テクスチャで受け取る。入出力はモデルの関数ディスクリプタが自己記述(shape / dtype)しているので、
モデルごとの特別扱いは無い。深度推定・超解像・セグメンテーション等の単機能画像モデルがそのまま通る。

> **状態: 実験中(macOS 27+)。** DMG には含まれません(`PLUGINS.tsv` が唯一の正)。
> Depth Anything v3 / EDSR x2 / YOLOS を M2・macOS 27.0 で確認済みですが、Core AI 自体が
> macOS 27 の新フレームワークで、広い検証はまだです。

- 入力0 = 画像。モデルの入力サイズへリサイズし、正規化して NCHW / NHWC・float32 / float16 の
  うちディスクリプタどおりに詰める。バッチ / ビュー次元(`[1,V,3,H,W]`)には同じ画像を複製
- 出力 = 選んだ出力テンソルを画像として解釈: `[H,W]` → Mono、`[C,H,W]` / `[H,W,C]` の
  C = 1..4 → Mono / RGBA(C = 2 は R と G)。`Channel` で1チャンネルだけを Mono に取り出せる。
  画像の形でない出力(logits・box・行列)は警告になる(将来の CoreAI CHOP の担当)
- ロードも推論も非同期(cook をブロックしない)。結果は1〜2フレーム遅れ。前の推論が終わるまで
  次のフレームは投入しない
- **macOS 26 ではロードはできるが何もしない**(status `unavailable: Core AI requires macOS 27+`)。
  フレームワークは weak リンクなのでバンドル自体のロードは失敗しない

### モデルの入手

Core AI のモデルは「ダウンロード」ではなく「書き出し」で手に入れる。Apple の
[coreai-models](https://github.com/apple/coreai-models) にモデルごとのレシピがあり、元の重みを
Hugging Face から取ってきて手元の Mac で変換する。`demo.toe` の利用例(Depth Anything v3 small・約100MB)なら:

```bash
brew install uv
git clone https://github.com/apple/coreai-models.git
cd coreai-models/models/depth-anything && uv run export.py
cp -R ../../exports/da3-small_float32.aimodel <このリポジトリ>/models/
```

最初の `uv run` は PyTorch 入りの Python 環境を作るので数分かかる。`coreai-models/models/` の
各フォルダに同じ `uv run export.py` がある(`edsr` = 2倍超解像、`yolo`、`sam3`、`clip` …)。
画像入力を持つものなら何でも読める。Info DAT に実際の入出力が出るので、何が来たかはそこで分かる。

### 実測(M2・macOS 27.0)

| モデル | 入力 | 出力 | 前処理 | 推論 | ロード |
|---|---|---|---|---|---|
| da3-small(Depth Anything v3) | float32 `[1,2,3,224,224]` | depth `[1,2,224,224]` | 2〜10 ms | **60〜100 ms**(auto / Neural Engine)・220 ms(CPU) | 0.3秒(キャッシュ後)〜2.5秒 |
| edsr_r16f64_x2 | float32 `[1,3,16,16]` | `[1,3,32,32]` | 6 ms | 6 ms(初回 2秒) | 0.2秒 |
| yolos-base | float16 `[1,3,800,800]` | logits `[1,100,92]`・boxes | 8 ms | 約3秒 | 2.8秒 |

推論時間は Info CHOP の `run_ms`。`pre_ms` / `post_ms` はこの op 自身の変換コスト。
ロード直後の初回推論はオンデバイスのコンパイルを含むので遅い。

### パラメータ

| 名前 | 説明 |
|---|---|
| Active | On/Off |
| Model (.aimodel) | `.aimodel` / `.aimodelc` パッケージのパス(フォルダ選択。`.aimodel` はディレクトリ) |
| Function | モデル内の関数名(coreai-models の書き出しは全部 `main`) |
| Compute Units | Auto / CPU Only / Prefer GPU / Prefer Neural Engine(`SpecializationOptions`) |
| Reload Model | パルス: モデルを読み直す |
| Input Normalize | 0 to 1 / -1 to 1 / ImageNet Mean-Std / 0 to 255 — モデルの学習時の前処理に合わせる |
| Output | 表示する出力(メニューはロード完了後に埋まる。`auto` = 最初の出力) |
| Channel (0=All) | 0 = 全チャンネルを Mono/RGBA で、N = N-1 番のチャンネルを Mono で |
| Output Range | Auto(フレームごとの min-max)/ Raw(そのまま)/ Manual(Range Min〜Max) |
| Invert | 1 − 値(深度を「近い = 明るい」にする等) |
| Flip Vertically | 既定 On(モデル出力は top-down・TD は bottom-up) |

### Info CHOP / Info DAT

Info CHOP: `executes submits results busy loaded loading inference_ms load_ms width height channels
serial pre_ms run_ms post_ms`。`results` が `submits` に追従していればフレーム落ちなし。

Info DAT: `status`・`stage`・モデルパス・関数一覧・計算ユニット・デバイス世代(M2 は `h14g`)・
アセットメタデータの description / author / license、入出力ごとに `kind / dtype / shape` の行。

### 注意

- 動的 shape の入力(`--dynamic` 書き出し)は未対応。static で書き出す
- 画像(`CVPixelBuffer`)型の入力は未対応。coreai-models の書き出しは全部 NDArray 入力
- グレー入力(`C = 1`)は BT.601 の重みで変換
- コンパイル結果は OS の `AIModelCache` に残るので、同じモデルの2回目以降のロードは速い

## CoreAI LLM DAT

同じフォルダから **CoreAI LLM DAT**(opType `Coreaillm`)もビルドされる。Apple の
[coreai-models](https://github.com/apple/coreai-models) が書き出す LLM / VLM バンドル
(Qwen3・Gemma 3・Mistral・Phi-4・Qwen3-VL …)を Core AI で完全オンデバイス実行するチャット DAT。
LLM MLX の Core AI 版で、モデルは**別プロセスのヘルパ**(`coreai-llm-helper`・coreai-models の
Swift パッケージから生成)で動き、トークンは会話テーブルへストリーミングされる。数 GB のモデルと
Metal の状態を TouchDesigner のプロセスに抱え込まない

- 出力テーブル: `index / role / text`(*Show Thinking Column* オンで `think` 列が付く)
- **Model Bundle** は `exports/<name>` の**フォルダ**(`metadata.json`・`.aimodel`・`tokenizer/`
  が入っている)。`.aimodel` そのものではない
- **画像入力**(Vision ページ): *Use Image Input* オンで、Submit 時に *Image TOP* を取り込んで
  モデルへ渡す。VLM バンドル(Info DAT の `kind = vlm`)が必要で、テキスト専用モデルではエラーになる。
  会話に残る画像は**最新の1枚**だけ。VLM のターンは毎回画像を再エンコードして会話全体を頭から
  流し直す(画像ターンをまたいで KV キャッシュを使い回せない)ので、履歴が伸びるほど遅くなる
- **Enable Thinking**: 推論モデル(Qwen3)は `<think>…</think>` を出す。オフ(既定)なら `/no_think`
  を付けて回答から始まる。思考テキストは `think` 列へ
- Info CHOP: `executes busy ready progress turns tokens_per_sec ttft_sec last_tokens context_length`。
  Info DAT: `status / model / kind / context_length`

### LLM / VLM バンドルの入手

TOP のモデルと同じ手順。coreai-models を clone してエクスポータを走らせると `exports/<name>/` に
バンドルができる:

```bash
cd coreai-models/models/qwen3 && uv run export.py            # → exports/mac/qwen3_1_7b_4bit_dynamic
cd coreai-models/models/qwen3_vl && uv run export.py         # → exports/vlm-fp16/qwen3_vl_2b
```

*Model Bundle* にそのフォルダを指定する(`project.folder + '/models/qwen3_1_7b_4bit_dynamic'`
のような式にすると .toe の位置に追従する)

### 実測(M2 24GB・macOS 27.0・断りが無ければヘルパ単体)

ローカルの coreai-models checkout にある LLM / VLM の書き出しを全部ヘルパに通した
(`Name one primary color in one short sentence.`・greedy・思考オフ):

| バンドル | ロード(初回 / キャッシュ後) | 生成 | 結果 |
|---|---|---|---|
| qwen3_1_7b_4bit | 36 s / 3 s | 単体 34 tok/s・**TD 内 4〜10 tok/s** | OK・マルチターン |
| qwen3_4b_4bit | — / 7 s | 7.8 tok/s | OK(`/no_think` が効く) |
| qwen3_8b_4bit | — | 4.2 tok/s | OK |
| gemma_3_4b_it_4bit | 67 s / 7〜11 s | 7.4 tok/s | 下記の停止トークン修正後 OK |
| gemma_3n_e2b_it_4bit | — | 3.0 tok/s | OK |
| mistral_7b_instruct_v0_3_4bit | — | 0.7 tok/s | OK だがスワップ(4GB のモデル + TD 常駐) |
| gpt_oss_20b | — | 1.8 tok/s | OK・スワップ 10GB。Harmony 形式の `<|channel|>analysis` は思考として分離されない |
| phi_4_mini_instruct_4bit | 15 s | 1.0 tok/s | **書き出しが壊れている** — 同じ語の繰り返し。llm-runner でも同じで、コンパイル時に `RoPE freqs shape [48] must match half_embed [64]` |
| qwen3_vl_2b(fp16・VLM) | 140 s / 19 s | 5〜8 tok/s・画像エンコード約 4 s | TD 内で 1280×720 のフレームから物体一覧を正答 |
| community gemma-4-E2B | — | — | **非対応**: 入力が4つ(`ple_table`・`ple_scale`)で標準エンジンが渡せない |
| community gemma-4-12B(mm) | — | — | **非対応**: Core AI のコンパイラが落ちる(`LLVM ERROR: cannot unwrap empty odiec_module_t`)。別ツールチェーン製のバンドル。ヘルパごと落ち、DAT は `helper exited` を出す |

TD 内の生成はヘルパ単体より大きく遅い(同じ 1.7B で 4〜10 対 34 tok/s)。原因は未特定
(TD 自身の描画との GPU 競合が有力)。4B 超のレートは 24GB 機で TD が常駐した状態のメモリ圧で決まっている

### 注意

- **コンテキストは小さく、切り詰めはしない**。プロンプトが `context_length` を超えるとエラーになる。
  *Reset Conversation* で消す
- 別バンドルをロードすると `ready` / `progress` / `kind` はリセットされる。Core AI がモデルを
  コンパイルする間ヘルパが progress を報告する(7B の初回は数分)
- **停止トークン**: coreai-models のエクスポータは `tokenizer_config.json` から `added_tokens_decoder` を
  落とすので、ライブラリの `additionalStopTokenIds` は何も拾えず、Gemma が `<end_of_turn>` を延々と
  吐き続ける(llm-runner でもこの書き出しでは同じ)。ヘルパは既知のターン終端トークン
  (`<end_of_turn>`・`<|im_end|>`・`<|eot_id|>`・`<|end|>` …)を語彙から直接引く。見つけた ID は
  `ready` イベントの `stops` に入る
- 拡散モデル(FLUX)のバンドルはこの DAT の対象外

### ビルド

```bash
cd CoreAI && TD_APP=/Applications/TouchDesigner.app zsh ./build.sh   # → build/CoreAITOP.plugin + build/CoreAILLMDAT.plugin
```

Swift ヘルパ(`CoreAIHelper.swift`・C ABI `ai_`)は `-weak_framework CoreAI` でリンクし、
`-target arm64-apple-macos26.0`。SDK 27 が無い環境では `canImport(CoreAI)` が偽になり
「unavailable」経路だけがビルドされる。

LLM DAT のヘルパ(`helper/`・SwiftPM・coreai-models と swift-transformers に依存)は SDK 27 以上の
ときだけビルドされ、`Contents/Helpers/coreai-llm-helper` と依存バンドル(`*.bundle`)が同梱される。
SDK 26 では `CoreAILLMDAT.plugin` はスキップされる。
