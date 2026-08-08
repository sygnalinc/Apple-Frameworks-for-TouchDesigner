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

## Licenses

Each model has its own license, separate from this repository's MIT license. Check the model
card before redistributing or using commercially.
