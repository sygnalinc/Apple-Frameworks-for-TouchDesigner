# CoreAI TOP

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

### ビルド

```bash
cd CoreAI && TD_APP=/Applications/TouchDesigner.app zsh ./build.sh   # → build/CoreAITOP.plugin
```

Swift ヘルパ(`CoreAIHelper.swift`・C ABI `ai_`)は `-weak_framework CoreAI` でリンクし、
`-target arm64-apple-macos26.0`。SDK 27 が無い環境では `canImport(CoreAI)` が偽になり
「unavailable」経路だけがビルドされる。
