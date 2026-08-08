# Apple Frameworks for TouchDesigner

> Apple's on-device frameworks as native TouchDesigner operators.

**English** | [日本語](README.ja.md)

A collection of TouchDesigner custom operators (`.plugin`) that expose macOS /
Apple Silicon **on-device ML and media frameworks** — Vision, Core ML, Core Image,
VideoToolbox / MetalFX, SpeechAnalyzer, Sound Analysis, Natural Language,
FoundationModels, ScreenCaptureKit, RealityKit and more — directly inside TouchDesigner.

- **macOS only.** Runs on the Neural Engine / GPU as-is — no external runtime, no Python
  environment, no cloud API (bundled-model ops need no extra download either).
- **Never blocks cook.** Inference runs asynchronously on worker threads, so TouchDesigner
  keeps its frame rate.
- **A macOS alternative to Windows+NVIDIA-only stock OPs.** Where a plugin replaces a stock
  OP, its channel / texture format matches the original as closely as possible.

Each plugin has its own `README` with parameters, output specs, measured performance and
caveats. `demo.toe` contains a **minimal usage example for every OP**, one container each.

## Table of contents

- [As a macOS alternative to NVIDIA-only OPs](#as-a-macos-alternative-to-nvidia-only-ops)
- [Plugin catalog](#plugin-catalog)
- [Getting started](#getting-started)
- [Versioning](#versioning)
- [Requirements](#requirements)
- [Writing your own plugin](#writing-your-own-plugin)
- [License](#license)

## As a macOS alternative to NVIDIA-only OPs

| Goal | Stock OP (Win+NVIDIA) | This repo |
|---|---|---|
| Body pose estimation | Body Track CHOP | [Vision Pose](VisionPose/) |
| Super-resolution upscaling | Nvidia Upscaler TOP | [Metal Upscale](MetalUpscale/) |
| Optical flow | Optical Flow TOP | [Vision Flow](VisionFlow/) |
| Face tracking | Face Track CHOP | [Vision Face](VisionFace/) |

## Plugin catalog

### People, face & hand tracking

| Plugin | Family | What it does |
|---|---|---|
| [Vision Pose](VisionPose/) | CHOP | Multi-person 2D body pose (34 keypoints). **Channel format compatible with Body Track CHOP.** 5 people @ 60fps |
| [Vision Pose3D](VisionPose3D/) | CHOP | Single-person **3D pose** (17 joints in meters + 2D projection + height estimate). ~2fps, slow/deliberate |
| [Vision Hand](VisionHand/) | CHOP | Hand tracking (21 joints × up to 100 hands, left/right) |
| [Vision Face](VisionFace/) | CHOP | Face detection + bbox, roll/yaw/pitch, landmarks (up to 76), capture-quality score. **Face Track CHOP alternative** |

### Object & scene recognition

| Plugin | Family | What it does |
|---|---|---|
| [CoreML](CoreMLDAT/) | DAT | **Object detection.** YOLO-style Core ML models → label / confidence / bbox ("what & where") |
| [Vision Classify](VisionClassify/) | DAT | **Image classification** (no extra model). Top-N identifier / confidence |
| [Vision AnimalPose](VisionAnimalPose/) | CHOP | Dog / cat 2D pose (25 joints, multiple animals) |
| [Vision Rect](VisionRect/) | CHOP | Rectangle detection → bbox / projected corners (wire straight into Corner Pin) |
| [Vision Barcode](VisionBarcode/) | DAT | QR / various barcodes → payload / symbology / bbox / corners |
| [Vision Text](VisionText/) | DAT | **OCR / text recognition** (multilingual, reading-order sort, Accurate/Fast) |
| [Vision Document](VisionDocument/) | DAT | **Document structure** (macOS 26+): paragraphs / tables / rows / cells / lists, not just OCR |
| [Vision Trajectory](VisionTrajectory/) | CHOP | Trajectory of small projectile objects (measured / projected points, parabola coefficients) |
| [Vision Horizon](VisionHorizon/) | CHOP | Horizon angle + correction transform |
| [ImageIO Metadata](ImageIOMetadata/) | DAT | Read EXIF / GPS / IPTC from image files (GPS decimal-degree conversion) |

### Cutout & masking

| Plugin | Family | What it does |
|---|---|---|
| [Vision Subject](VisionSubject/) | TOP | **Cut out any subject** (same API as Photos' "Copy Subject"). Soft mask / transparent background |
| [CoreML SAM2](CoreMLSAM2/) | TOP | **Point-prompted segmentation of any object** (SAM 2.1). Cut out whatever the audience touches |

### Tracking, motion & camera work

| Plugin | Family | What it does |
|---|---|---|
| [Vision Flow](VisionFlow/) | TOP | **Optical flow** (motion vector field). **Optical Flow TOP alternative** (UV/Pixels) |
| [Vision Saliency](VisionSaliency/) | TOP | Saliency map + **auto-framing** (crop rect of the region of interest → Crop TOP for automatic camera work) |

### Image processing & super-resolution

| Plugin | Family | What it does |
|---|---|---|
| [Metal Upscale](MetalUpscale/) | TOP | **Real-time super-resolution.** **Nvidia Upscaler TOP alternative** (MetalFX 2x / VT SuperRes 4x / VT LowLatency) |
| [Metal Denoise](MetalDenoise/) | TOP | ML temporal noise reduction (supported hardware only; not on M2) |
| [CoreImage RAW](CoreImageRAW/) | TOP | **Develop DNG / ProRAW** in real time (exposure / WB / noise / sharpness) via CIRAWFilter |
| [CoreImage HDR](CoreImageHDR/) | TOP | **HDR gain map** extraction + SDR/HDR (EDR) conversion from HEIC |
| [ImageIO File In](ImageIOFileIn/) | TOP | **Read any image file (incl. HEIF/HEIC that TD can't show)** → Color, plus embedded **depth / disparity / Portrait Matte / semantic mattes**. Applies EXIF orientation |

### General ML inference & image generation

| Plugin | Family | What it does |
|---|---|---|
| [CoreML](CoreML/) | TOP | Run **any Core ML model** by swapping it in (depth, style transfer, classification…). Auto-detects image / array output |
| [CoreML](CoreMLCHOP/) | CHOP | **Vector output** of any Core ML model into channels (embeddings, keypoints…) |
| [CoreML ImageGen](CoreMLImageGen/) | TOP | **text2img / img2img** with an **external Core ML model** (Stable Diffusion / SDXL / SD Turbo) |
| [ImagePlayground](ImagePlayground/) | TOP | **text→image via Apple Image Playground** (`ImageCreator`, macOS 15.4+). No external model; Animation / Illustration / Sketch. Wire a face image into input 0 to generate people |
| [CoreImage Code](CoreImageCode/) | TOP | **Generate** QR / Aztec / PDF417 / Code128 (no external library) |
| [CreateML](CreateML/) | DAT | **Unified on-device trainer** — one `Task` menu for Image / Hand Pose / Action (body) / Hand Action / Sound / Activity (CHOP series) / Tabular classifier & regressor → `.mlmodel`. Output models are read by CoreML TOP / CoreML Motion CHOP / SoundClass etc. |
| [CreateML Training Recorder](CreateMLTrainingRecorder/) | CHOP | **Record a CHOP time-series → CreateML dataset CSV** (recording / label / feature columns). Capture VisionPose/Hand takes in TD, label them, feed straight to CreateML (Activity) |
| [CoreML Motion](CoreMLMotion/) | CHOP | **Live gesture inference** — buffer an input CHOP (VisionPose etc.) over the prediction window and classify motion in real time (per-class prob + confidence). Pairs with CreateML's Activity task |

### Audio & sound

| Plugin | Family | What it does |
|---|---|---|
| [Sound Class](SoundClass/) | CHOP | **Sound classification** (applause / cheering / alarms… 300+ classes). Custom Core ML acoustic models too |
| [Sound Features](SoundFeatures/) | CHOP | Audio features (RMS / peak / centroid / onset / beat / BPM / 16 bands) |
| [Speech Text](SpeechText/) | DAT | **Live transcription.** Apple SpeechAnalyzer (macOS 26+) / WhisperKit (macOS 14+, multilingual, translate) |
| [Speech Synth](SpeechSynth/) | CHOP | On-device **speech synthesis** → PCM stereo |
| [Speech Activity](SpeechActivity/) | CHOP | **Voice activity detection** (speaking / onset / offset). Start/stop trigger for transcription |

### Language & text

| Plugin | Family | What it does |
|---|---|---|
| [LLM AFM](LLMAFM/) | DAT | **Apple Intelligence on-device LLM** (macOS 26+). **Structured output (JSON schema)** + **Tool Calling** (the LLM calls a tool, TouchDesigner executes it and returns the result) straight into show control |
| [LLM MLX](LLMMLX/) | DAT | **Local LLM via Apple MLX** (mlx-swift-lm). Runs any mlx-community model (Gemma 4 / Qwen / Llama) fully on-device with token streaming. No API key; model auto-downloads from Hugging Face on first use |
| [Translate](Translate/) | DAT | **On-device translation.** Wire to Speech Text for real-time subtitle translation |
| [Text Analyze](TextAnalyze/) | DAT | Sentiment / language ID / named entities / semantic similarity (JA supported) + **tokens (token / POS / lemma)** and **embedding vectors** (numeric). "Drive visuals from speech mood/topic" |

### 3D, screen, input devices & connectivity

| Plugin | Family | What it does |
|---|---|---|
| [RealityKit Capture](RealityKitCapture/) | SOP | **Photo folder → 3D mesh** (RealityKit Object Capture). Textured OBJ output |
| [ImageIO PointCloud](ImageIOPointCloud/) | SOP | **Photo depth → 3D point cloud** (unproject via camera calibration / FOV). Colors sampled from RGB |
| [Cinematic Video](Cinematic/) | TOP | **iPhone Cinematic video** (macOS 26+): depth (disparity) map or **re-render with adjustable focus / aperture**; metadata (focus depth, subjects) on its **Info CHOP** |
| [Vision Contours](VisionContours/) | SOP | Image contours → **closed Line geometry** (wire into Sweep / Extrude / Particle) |
| [Screen Capture](ScreenCapture/) | TOP | **Screen recording** of a display or **a single window picked by name from a dropdown** (up to 120fps) |
| [CA Process Tap](CoreAudioProcessTap/) | CHOP | **Tap a single app's audio** (Core Audio Process Tap, macOS 14.4+) or all system audio → 48kHz stereo. Finer-grained than Screen Capture |
| [Spotlight](Spotlight/) | DAT | **OS-wide local file search** (Spotlight / NSMetadataQuery) — name / content / raw kMDItem predicate |
| [Multipeer In / Out](MultipeerCHOP/) | CHOP | **Turn an iPhone/iPad into a wireless sensor** (low-latency gyro / accel / touch). **iOS app included** |
| [Multipeer In / Out](MultipeerDAT/) | DAT | **Local P2P text** between Mac / iPhone (auto-connect, no server) |
| [Game Controller](GameController/) | CHOP | PS5 / Xbox / MFi **gamepad input** (sticks / triggers + motion + rumble) |
| [Shortcuts](Shortcuts/) | DAT | **Run macOS Shortcuts** (HomeKit lights / appliances / notifications from TD events) |
| [AppleScript](AppleScript/) | DAT | **Run AppleScript / JavaScript (JXA) from TD** (osascript). Control other apps (Music/Finder/…), get system info, automate workflows — **returns the result text too**. App control needs Automation permission |
| [CoreText](CoreText/) | TOP | **Apple text rendering** — SF/variable-font weight, color emoji, Japanese vertical text, gradient / outline / shadow; freer & prettier than the stock Text TOP |
| [PDFKit](PDFKit/) | TOP | **PDFKit** — render a page to a texture; structure (metadata / outline / text / annotations) on its **Info DAT** |
| [CoreWLAN](CoreWLAN/) | CHOP | **Live Wi-Fi metrics** (CoreWLAN) — RSSI / noise / SNR / TX rate / channel |
| [CoreWLAN Scan](CoreWLANScan/) | CHOP | **Scan nearby Wi-Fi → per-channel congestion / AP count / max RSSI** and the least-congested channel (2.4/5GHz). Optional **SSID names via a bundled Location-authorized helper app** (Info DAT) |
| [Network Discovery](NetworkDiscovery/) | DAT | **Discover all LAN devices**: Bonjour services + **active IPv4 scan** (ARP sweep → MAC / hostname of every host, even non-Bonjour); merged IP / MAC / **vendor (OUI)** / DNS name / mDNS name / **SMB name & domain (NetBIOS)** / port / TXT (LanScan Pro-like) |

## Getting started

### 1. Build a plugin

```sh
cd VisionPose && ./build.sh      # → VisionPose/build/VisionPoseCHOP.plugin
```

Requires Xcode (`clang++`) and TouchDesigner.app (its C++ SDK headers are reused). Runs on
TouchDesigner 2023 or later.

### 2. Use it in TouchDesigner

- **Quick try:** drop a `C++ CHOP/TOP/DAT/SOP` and point Plugin Path at the `.plugin` (no restart).
- **As a permanent custom OP:** copy the `.plugin` into
  `~/Library/Application Support/Derivative/TouchDesigner099/Plugins/`
  → it appears in the OP Create Dialog after a TouchDesigner restart.

Model-based plugins (CoreML / CoreML SAM2 / CoreML ImageGen / LLM MLX…) need a model file
placed in `models/`. The models are **not** in this repository — [`models/README.md`](models/README.md)
lists every file the examples expect and where to download it. Each example in `demo.toe`
repeats the download link in its own note.

## Versioning

Current release: **0.9.1** (see [`VERSION`](VERSION))

| Layer | Value | Rule |
|---|---|---|
| Repository (git tag) | `v0.9.1` | Adding operators / features bumps **minor**, fixes bump **patch**. Renaming or removing an `opType` is a **breaking** change and is called out in the release notes. |
| Bundle (`Info.plist`) | `CFBundleShortVersionString` = repo version, `CFBundleVersion` = git commit count | Stamped automatically by `common/version.sh` at build time. |
| Operator (`customOPInfo`) | `majorVersion = 0`, `minorVersion = 9` | **Per operator.** TouchDesigner compares these with the values saved in a `.toe`. Bump `majorVersion` **only** for that one operator when a change is not backwards compatible (parameter removed / semantics changed). |

**Release builds** are Developer ID signed (SYGNAL INC.), hardened-runtime, timestamped and
**notarized by Apple** — they open on any Mac without Gatekeeper warnings. Local development
builds (`./build.sh`) remain ad-hoc signed. The release pipeline is
[`tools/release.sh`](tools/release.sh) (`sign` → `verify` → `dmg` → `notarize`).

**Why 0.x:** operator names (`opType`) are the public API here, and several were renamed,
merged or removed during early development — each of which breaks `.toe` files that
referenced them. The API is not frozen yet.

**Road to 1.0.0**

1. Freeze operator naming (`opType` / `opLabel`)
2. Verify the remaining hardware / material dependent operators on real data
   (Image Capture, CoreLocation Beacon, AudioToolbox Mix with 4-ch FOA …)
3. ~~Ship a **Developer ID signed + notarized** release archive~~ — done (`tools/release.sh`)
4. Keep `demo.toe` usage examples working against the frozen names

## Requirements

- macOS 12+ (Apple Silicon recommended). Some features need a newer macOS — noted in each README.
- Xcode and TouchDesigner.app to build.

## Writing your own plugin

The shared build / implementation patterns (async worker, TOP download flip, Info CHOP
diagnostics, …) and every pitfall actually hit during development are collected in
[`CLAUDE.md`](CLAUDE.md), with a distilled agent skill under
[`.claude/skills/td-apple-plugin/`](.claude/skills/td-apple-plugin/).
`common/build_plugin.sh` factors out bundle assembly and signing.

## License

This project's own code is released under the **[MIT License](LICENSE)** — use it freely,
including commercially.

It contains **only original code**: no Apple source, no TouchDesigner SDK, and no model
weights are redistributed here. Apple frameworks are used through their public APIs (governed
by Apple's SDK agreement, which does not restrict your code), the TouchDesigner C++ SDK is
supplied by your own install, and models are downloaded separately under their own licenses.
Build-time dependencies (`apple/ml-stable-diffusion`, `argmaxinc/WhisperKit`) are MIT and
fetched via SPM, not vendored. Details in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### Sample media

The demo clips in `Assets/sample_*.mp4` were **generated with Adobe Firefly (Google Veo 3.1 Fast)**
for this repository, so they carry no third-party model release or location permit. They exist
purely to exercise the operators (`demo.toe`) and are covered by the
same MIT license as the rest of the repository. People appearing in them are synthetic and do
not depict real individuals. Firefly's generative models are trained on licensed and public
domain content and its output is intended for commercial use; if you redistribute these clips
outside this project, check Adobe's current generative AI terms for your own account tier.
