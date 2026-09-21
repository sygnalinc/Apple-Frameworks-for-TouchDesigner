# models/

External model files go here. **The models themselves are not in this repository** — they are
large (tens of MB to several GB) and carry their own licenses, so only this README is tracked.

Download what you need, put it in this folder under the exact name shown, and the matching
example in `demo.toe` will run as-is.

| Put here | Used by | Download |
|---|---|---|
| `DepthAnythingV2SmallF16.mlpackage` | CoreML (TOP) — depth estimation | https://huggingface.co/apple/coreml-depth-anything-v2-small |
| `mobileclip_s0_image.mlpackage` | CoreML (CHOP) — 512-d image embedding | https://huggingface.co/apple/coreml-mobileclip |
| `mobileclip_s0_text.mlpackage` | text embeddings (optional, for the CLIP text bank) | https://huggingface.co/apple/coreml-mobileclip |
| `YOLOv3Int8LUT.mlmodel` | CoreML (DAT) — object detection | https://huggingface.co/apple/coreml-YOLOv3 |
| `coreml-sam2.1-tiny/` (3 `.mlpackage` in one folder) | CoreML SAM2 (TOP) — point-prompted masks | https://huggingface.co/apple/coreml-sam2.1-tiny |
| `coreml-stable-diffusion-2-1-base-split-einsum/` | CoreML ImageGen (TOP) — text2img | https://huggingface.co/apple/coreml-stable-diffusion-2-1-base |
| `gemma-3-4b-it-qat-4bit/` | LLM MLX (DAT) — local LLM | https://huggingface.co/mlx-community/gemma-3-4b-it-qat-4bit |
| `Qwen2-VL-2B-Instruct-4bit/` | LLM MLX (DAT) — local **vision** LLM | https://huggingface.co/mlx-community/Qwen2-VL-2B-Instruct-4bit |
| `da3-small_float32.aimodel` | CoreAI (TOP) — Depth Anything v3 depth (macOS 27+) | exported with Apple's coreai-models recipe, see below |
| `qwen3_1_7b_4bit_dynamic/` | LLM CoreAI (DAT) — Qwen3 1.7B text LLM (macOS 27+) | exported with coreai-models `models/qwen3`, see below |
| `qwen3_vl_2b/` | LLM CoreAI (DAT) — Qwen3-VL 2B **vision** LLM (macOS 27+, ~5 GB) | exported with coreai-models `models/qwen3_vl`, see below |
| `FLUX.2-klein-4B/` | CoreAI ImageGen (TOP) — FLUX.2 text2img / img2img (macOS 27+, ~5.9 GB) | exported with coreai-models `models/flux2`, see below |

Any other model works too: CoreML TOP / CHOP / DAT take any Core ML model, and LLM MLX takes
any [mlx-community](https://huggingface.co/mlx-community) repository.

## Downloading

Hugging Face folders are easiest with the CLI:

```bash
pip install -U "huggingface_hub[cli]"
hf download mlx-community/gemma-3-4b-it-qat-4bit --local-dir models/gemma-3-4b-it-qat-4bit
```

Single files can just be downloaded from the "Files" tab of the model page.

LLM MLX can also take a repository ID directly (`mlx-community/…`) instead of a local path — it
then downloads the model on first use. Pointing it at a local folder here keeps it fully offline.

## Core AI models (`.aimodel`, macOS 27+)

There are no pre-built `.aimodel` downloads; Apple's [coreai-models](https://github.com/apple/coreai-models)
repository ships **export recipes** that download the original weights from Hugging Face and convert
them on your Mac. The whole thing is three commands (needs `uv`; the first export also creates a
Python environment with PyTorch, a few minutes):

```bash
brew install uv
git clone https://github.com/apple/coreai-models.git
cd coreai-models/models/depth-anything && uv run export.py     # -> coreai-models/exports/da3-small_float32.aimodel (about 100 MB)
cp -R ../../exports/da3-small_float32.aimodel <this repo>/models/
```

Every folder under `coreai-models/models/` (edsr, yolo, sam3, clip, …) has the same `uv run export.py`;
any exported model with an image input can be dropped into the CoreAI TOP.

### LLM / VLM bundles (LLM CoreAI DAT)

Language models export as a **bundle folder** (`metadata.json` + `<name>.aimodel` + `tokenizer/`;
VLMs add `vision.aimodel` and `embed.aimodel`). Copy the whole folder and point the DAT's
*Model Bundle* at it:

```bash
cd coreai-models/models/qwen3 && uv run export.py        # -> exports/mac/qwen3_1_7b_4bit_dynamic (about 1.2 GB)
cd coreai-models/models/qwen3_vl && uv run export.py     # -> exports/vlm-fp16/qwen3_vl_2b (VLM, about 4 GB)
cp -R ../../exports/mac/qwen3_1_7b_4bit_dynamic <this repo>/models/
```

Verified on an M2: qwen3 (1.7B / 4B), gemma_3 (4B), qwen3_vl (2B). Other recipes in the repo
(mistral, phi_4, gemma_3n, gpt_oss …) use the same layout.

## Licenses

Each model has its own license, separate from this repository's MIT license. Check the model
card before redistributing or using commercially.
