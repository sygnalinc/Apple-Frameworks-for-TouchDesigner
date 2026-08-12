# LLM MLX DAT

**English** | [日本語](#日本語)

## English

Runs quantised LLMs — Gemma, Qwen, Llama and so on — **fully locally, on-device**, with Apple's
**MLX** framework ([mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)). No API billing,
works offline (the model is downloaded from Hugging Face once, on the first run).

### Compared with LLM AFM

| | LLM AFM DAT | LLM MLX DAT |
|---|---|---|
| Backend | Apple Intelligence (FoundationModels) | Apple MLX (mlx-swift-lm) |
| Model | The fixed ~3B that ships with the OS | Any mlx-community model you choose (Gemma 4 etc.) |
| Enabling | Apple Intelligence must be on in settings | Nothing (Apple Silicon only) |
| Download | Managed by the OS | Fetched from HF once (`~/.cache/huggingface` etc.) |

### Architecture

The heavy inference (Metal, multi-GB models) runs in the bundled **helper executable
`mlxllm-helper` as a separate process**, talking over a JSON-lines protocol. Why:

- MLX's Metal resource bundle (`mlx-swift_Cmlx.bundle`) resolution and rpath are fragile when
  bundled as a dylib
- Isolating a multi-GB model plus Metal in its own process keeps a crash or OOM from taking TD
  down
- Model memory is reliably released when it stops

Cook never blocks: the helper's stdout is read on a worker thread and the latest state is output.

### Output

A conversation history table `index | role | text`, alternating user / assistant, with the last
assistant row growing token by token while generating. Info CHOP:
`executes / busy / ready / progress / turns`; Info DAT: `status`.

### Parameters

| Parameter | Description |
|---|---|
| Model | An mlx-community repo ID, **or the absolute path of a local directory** (default `mlx-community/gemma-4-e2b-it-4bit`) |
| System Instructions | System prompt |
| Prompt | Input |
| Temperature | 0–2 (default 0.7) |
| Max Tokens | Generation limit (default 512) |
| Keep Context | On for multi-turn (keeps conversational context) |
| Max Rows | Maximum history rows to output |
| **Use Image Input** (Vision page) | On to attach an image (**requires a VLM model**) |
| **Image TOP** (Vision page) | The TOP supplying the image |
| Load Model | Load the model (downloads on the first run) |
| Submit | Generate |
| Reset Conversation | Reset the conversational context |

### Multimodal (image input, VLM)

MLX also supports VLMs (vision-language models). The helper links both `MLXLLM` and `MLXVLM` and
**detects the model type automatically** (image input becomes effective with a VLM model).

- **Images need a VLM-capable model.** Verified working:
  **`mlx-community/Qwen2-VL-2B-Instruct-4bit`** (recommended, light),
  `Qwen2.5-VL-3B-Instruct-4bit`, `SmolVLM-Instruct-4bit`, and for Gemma
  **`mlx-community/gemma-3-4b-it-qat-4bit`** (verified, strong OCR; 12b/27b also exist),
  `paligemma-3b-mix-448-8bit`
- **⚠ Gemma 4 (`gemma-4-e2b-it-4bit` / `gemma-4-e4b-it-4bit`) currently loads as text-only**
  (that repo's quantised weights do not match mlx-swift-lm 3.31.4's Gemma4 VLM implementation —
  `keyNotFound(language_model...)`. It falls back to the text LLM automatically and the image is
  ignored). **For images with Gemma, use Gemma 3 (`gemma-3-4b-it-qat-4bit`)**
- Usage: set Model to a VLM model (e.g. the local path `models/Qwen2-VL-2B-Instruct-4bit`) → turn
  on **Use Image Input** on the Vision page → set **Image TOP** → ask something in the Prompt
  ("What is in this image?") → Submit. The TOP's frame at Submit time is written to a temporary
  PNG and handed to the VLM (`UserInput.Image.url`)
- A DAT cannot take a TOP as a wired input (DAT inputs are DATs), so **the TOP is referenced by
  parameter**
- Text-only models ignore the image
- **Measured (M2)**: Qwen2-VL-2B recognised a crowd photo and **OCR'd** the signage in the
  background ("WELCOME, TRAINERS!" / "May 29 - June 1, TOKYO"), describing the event

### Usage

1. Put an mlx-community model ID in Model (the default is the small Gemma 4 E2B 4bit)
2. Pulse **Load Model** — on the first run the Info DAT status goes to `downloading model` and the
   Info CHOP `progress` runs 0→100, ending at `ready`
3. Write a Prompt and **Submit** — the assistant row grows as it streams
4. With Keep Context on, submitting again continues the conversation. Reset clears the context

### Measured (M2)

- Model: `mlx-community/gemma-4-e2b-it-4bit` (E2B 4bit, ~3.3 GB download)
- Loaded inside TD (already cached) → `ready`; Submit **streams tokens** into the conversation
  table. A two-sentence answer (about 35 tokens) takes **about 1 second** — interactive speed
- Multi-turn (Keep Context) confirmed to keep context ("Red" → "another colour" → "Blue")

### Running fully offline from a local folder

Give Model the **absolute path** of a local directory and it loads straight from that folder
without touching Hugging Face at all (`ModelConfiguration(directory:)` bypasses the downloader).

1. Put the model in `models/gemma-4-e2b-it-4bit/` (`config.json` / `tokenizer.json` /
   `model.safetensors` / `*.index.json` …). For example:
   ```sh
   # download straight into models/ with the HF CLI (or copy from the HF cache)
   hf download mlx-community/gemma-4-e2b-it-4bit \
     --local-dir models/gemma-4-e2b-it-4bit
   ```
   `models/` is gitignored (models are never committed)
2. Set Model to that folder's absolute path (the example in `demo.toe` uses the expression
   `project.folder + '/models/gemma-4-e2b-it-4bit'` so it follows the `.toe`'s location)
3. Load Model — loads **with no network** (verified offline after deleting the HF cache)

### Notes

- **Apple Silicon only** (MLX uses Metal)
- With a HF repo ID, the first download takes a while (depending on your connection); later runs
  start fast from the cache. A local path is always offline
- Speed and quality depend on the model's quantisation and size. Larger models need more memory
- **If Model is in expression mode, a bare repo ID is evaluated as Python** and errors with
  `SyntaxError: invalid decimal literal`. Either quote it or switch the parameter back to constant

### Build

```sh
./build.sh
```

The first build takes several to tens of minutes compiling mlx-swift (Metal) and swift-syntax
(macros).

## 日本語

Apple の **MLX** フレームワーク（[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)）で
Gemma / Qwen / Llama 等の量子化LLMを **完全ローカル・オンデバイス**で走らせる DAT。
API課金なし・オフライン動作（モデルは初回のみ Hugging Face から自動ダウンロード）。

### LLM AFM との違い

| | LLM AFM DAT | LLM MLX DAT |
|---|---|---|
| バックエンド | Apple Intelligence（FoundationModels） | Apple MLX（mlx-swift-lm） |
| モデル | 端末付属の固定 ~3B | 任意の mlx-community モデル（Gemma 4 等）を選択 |
| 有効化 | 設定でApple Intelligenceが必要 | 不要（Apple Siliconのみ） |
| ダウンロード | OSが管理 | 初回のみHFから取得（`~/.cache/huggingface` 等） |

### アーキテクチャ

重い推論（Metal・多GBモデル）は同梱の**ヘルパ実行ファイル `mlxllm-helper` を別プロセス**
として起動し、JSON-lines プロトコルで通信する。理由:

- MLX の Metal リソースバンドル（`mlx-swift_Cmlx.bundle`）解決や rpath が dylib 同梱だと壊れやすい
- 多GBモデル + Metal をプロセス隔離し、クラッシュ/OOMでTDを巻き込まない
- 停止時にモデルのメモリを確実に解放できる

cook は絶対にブロックしない: ヘルパの stdout はワーカースレッドで読み、最新状態を出力する。

### 出力

会話履歴テーブル `index | role | text`。user / assistant が交互に並び、生成中は最後の
assistant 行がトークンで伸びる。Info CHOP は `executes / busy / ready / progress / turns`、
Info DAT は `status`。

### パラメータ

| パラメータ | 説明 |
|---|---|
| Model | mlx-community のリポジトリID、**またはローカルディレクトリの絶対パス**（既定 `mlx-community/gemma-4-e2b-it-4bit`） |
| System Instructions | システムプロンプト |
| Prompt | 入力 |
| Temperature | 0〜2（既定 0.7） |
| Max Tokens | 生成上限（既定 512） |
| Keep Context | オンでマルチターン（会話文脈を保持） |
| Max Rows | 出力する会話履歴の最大行数 |
| **Use Image Input**（Visionページ） | オンで画像を添付（**VLMモデル必須**） |
| **Image TOP**（Visionページ） | 画像を渡す TOP を指定 |
| Load Model | モデルをロード（初回はダウンロード） |
| Submit | 生成 |
| Reset Conversation | 会話文脈をリセット |

### マルチモーダル（画像入力・VLM）

MLX は VLM（Vision-Language Model）にも対応。ヘルパは `MLXLLM` と `MLXVLM` を両方リンクしており
**モデルの種類を自動判別**する（VLM対応モデルなら画像入力が有効）。

- **画像には VLM 対応モデルが必要**。実測で動作:
  **`mlx-community/Qwen2-VL-2B-Instruct-4bit`**（推奨・軽量）、`Qwen2.5-VL-3B-Instruct-4bit`、
  `SmolVLM-Instruct-4bit`、**Gemma系なら `mlx-community/gemma-3-4b-it-qat-4bit`**（実測OK・
  高精度OCR。12b/27b版もあり）、`paligemma-3b-mix-448-8bit` 等
- **⚠ Gemma 4（`gemma-4-e2b-it-4bit` / `gemma-4-e4b-it-4bit`）は現状テキスト専用としてロードされる**
  （この repo の量子化重みが mlx-swift-lm 3.31.4 の Gemma4 VLM 実装とキー不一致 =
  `keyNotFound(language_model...)`。自動でテキストLLMにフォールバックし画像は無視される）。
  **Gemma で画像を使うなら Gemma 3（`gemma-3-4b-it-qat-4bit`）を使う**
- 使い方: Model に VLM対応モデル（例 `models/Qwen2-VL-2B-Instruct-4bit` のローカルパス）→
  **Vision ページの Use Image Input をオン** → **Image TOP** に画像TOPを指定 →
  Prompt に質問（例「What is in this image?」）→ Submit。Submit時のTOPフレームを一時PNGに
  書き出して VLM に渡す（`UserInput.Image.url`）
- DAT は TOP をワイヤ入力できない（DATの入力はDAT）ため、**TOPはパラメータで参照**する
- テキストのみのモデルでは画像は無視される
- **実測（M2）**: Qwen2-VL-2B が群衆写真を認識し、背景の看板を **OCR**（"WELCOME, TRAINERS!" /
  "May 29 - June 1, TOKYO"）してイベント内容まで説明

### 使い方

1. Model に mlx-community のモデルIDを入れる（既定は最小の Gemma 4 E2B 4bit）
2. **Load Model** をパルス → 初回は Info DAT の status が `downloading model` になり、
   Info CHOP `progress` が 0→100 へ。完了で `ready`
3. Prompt を書いて **Submit** → assistant 行がストリーミングで伸びる
4. Keep Context オンなら続けて Submit で会話が続く。Reset で文脈クリア

### 実測（M2）

- モデル: `mlx-community/gemma-4-e2b-it-4bit`（E2B・4bit、DL約3.3GB）
- TD内でロード（キャッシュ済み）→ `ready`、Submit で**トークンをストリーミング**しながら
  会話テーブルへ。2文の回答（約35トークン）が**約1秒**＝インタラクティブ速度
- マルチターン（Keep Context）で文脈保持を確認（「Red」→「別の色」→「Blue」）

### ローカル（完全オフライン）実行

Model にローカルディレクトリの**絶対パス**を渡すと、Hugging Face へ一切アクセスせず
そのフォルダから直接ロードする（`ModelConfiguration(directory:)` = ダウンローダ非経由）。

1. モデルを `models/gemma-4-e2b-it-4bit/`（`config.json` / `tokenizer.json` /
   `model.safetensors` / `*.index.json` 等）に置く。取得例:
   ```sh
   # HF CLI で models/ へ直接DL（もしくはHFキャッシュからコピー）
   hf download mlx-community/gemma-4-e2b-it-4bit \
     --local-dir models/gemma-4-e2b-it-4bit
   ```
   `models/` は gitignore 対象（モデルはコミットしない）
2. Model にそのフォルダの絶対パスを設定（`demo.toe` の例は
   `project.folder + '/models/gemma-4-e2b-it-4bit'` のエクスペッションで .toe の場所に追従）
3. Load Model → **ネットワーク不要**でロード（HFキャッシュを消してもオフラインで起動する
   ことを実測確認）

### 注意

- **Apple Silicon 専用**（MLX は Metal を使う）
- HF リポジトリID指定時、初回ダウンロードに時間がかかる（回線次第）。2回目以降はキャッシュから高速起動。
  ローカルパス指定なら常にオフライン
- モデルの量子化・サイズで速度と品質が変わる。大きいモデルはメモリを要する
- **Model が式モードのままリポジトリIDを裸で書くと Python 式として評価され**、
  `SyntaxError: invalid decimal literal` になる。クォートで囲むか定数モードに戻すこと

### ビルド

```sh
./build.sh
```

初回は mlx-swift（Metal）+ swift-syntax（マクロ）のコンパイルで数分〜十数分かかる。
