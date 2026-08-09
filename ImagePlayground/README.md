# ImagePlayground TOP

**English** | [日本語](#日本語)

## English

Generates images from a **prompt plus a style** with Apple's **ImagePlayground** framework
(`ImageCreator`, macOS 15.4+). **No external model** — the device's Apple Intelligence does the
generating.

This is a separate line from [CoreML ImageGen](../CoreMLImageGen/), which uses external Core ML
models (Stable Diffusion etc.). Apple's built-in generation, which needs no external model, lives
here.

### Input and output

- **Input 0 (optional) = a source (face) image TOP**. **Generating a person requires a face
  image** (Apple's design). Connect a TOP containing a face to input 0 and it is passed as
  `ImagePlaygroundConcept.image`, generating from that person. Non-people (objects, scenery, …)
  need no input — the prompt alone is enough
- Output = an RGBA8 TOP. Generation is asynchronous (cook does not block). Info CHOP:
  `busy / gen_seconds / image_serial / executes`; Info DAT: `status`

### Generating a person

Trying to produce a person from a prompt alone gives
`generate error: Provide a source image containing a person's face...` (Apple's safety design).
**Connect a face image TOP to input 0** and Generate works:

1. Put an image TOP containing a face (Movie File In / ImageIO File In / Video Device In …) on
   **input 0**
2. Put the treatment in Prompt (e.g. "in a colorful fantasy illustration") and pick a Style
3. Pulse Generate

If the face is too small you get `faceInImageTooSmall`; an unsupported image gives
`unsupportedInputImage`. Use a close-up of the face.

### Parameters

| Parameter | Description |
|---|---|
| Style | Animation / Illustration / Sketch (Apple's three) |
| Prompt | Generation prompt |
| Generate | Pulse to generate |
| Flip Output Vertically | Flip the output vertically (default On) |

### Notes (Apple's constraints)

- **Requires a device with Apple Intelligence enabled** (macOS 15.4+)
- **A person cannot be generated from text alone — connect a face image to input 0** (see above)
- **No Steps / Seed / Guidance / img2img.** Only the three styles above
- The first run can take a while as ImageCreator prepares (watch the Info DAT status)
- **Generation only works inside a foreground GUI app (TouchDesigner).** Apple forbids headless /
  background execution (`backgroundCreationForbidden`)

### Build

```sh
./build.sh
```

## 日本語

Apple の **ImagePlayground** フレームワーク（`ImageCreator`・macOS 15.4+）で、**プロンプト＋
スタイル**から画像を生成する TOP。**外部モデル不要**（端末の Apple Intelligence が生成）。

Core ML の外部モデル（Stable Diffusion 等）を使う [CoreML ImageGen](../CoreMLImageGen/) とは
別系統。外部モデルを使わない Apple 標準の生成機能はこちらに分離してある。

### 入出力

- **入力0（任意）= ソース画像（顔）TOP**。**人物を生成するには顔画像が必須**（Apple 仕様）。
  顔を含む TOP を入力0に接続すると `ImagePlaygroundConcept.image` として渡され、その人物を
  もとに生成する。人物以外（モノ・風景等）は入力なしでプロンプトだけでよい
- 出力 = RGBA8 TOP。生成は非同期（cook はブロックしない）。Info CHOP は
  `busy / gen_seconds / image_serial / executes`、Info DAT は `status`

### 人物を生成する

プロンプトだけで人物を出そうとすると
`generate error: Provide a source image containing a person's face...` になる（Apple の安全設計）。
**入力0に顔画像 TOP を接続**して Generate すれば人物を生成できる:

1. 顔を含む画像 TOP（Movie File In / ImageIO File In / Video Device In 等）を**入力0**へ
2. Prompt に演出（例「in a colorful fantasy illustration」）、Style を選ぶ
3. Generate をパルス

顔が小さすぎると `faceInImageTooSmall`、非対応画像は `unsupportedInputImage` になる。
寄りの顔画像を使う。

### パラメータ

| パラメータ | 説明 |
|---|---|
| Style | Animation / Illustration / Sketch の3種（Apple 仕様） |
| Prompt | 生成プロンプト |
| Generate | 生成をパルス |
| Flip Output Vertically | 出力の上下反転（既定On） |

### 注意（Apple 仕様の制約）

- **Apple Intelligence が有効な端末が必要**（macOS 15.4+）
- **人物はテキストのみからは生成できない → 入力0に顔画像を接続する**（上記「人物を生成する」）
- **Steps / Seed / Guidance / img2img は無し**。スタイルは上記3種のみ
- 初回は ImageCreator の準備に時間がかかることがある（Info DAT の status を確認）
- **生成は前面のGUIアプリ（TouchDesigner）内でのみ動く**。ヘッドレス/バックグラウンド実行は
  Apple が禁止（`backgroundCreationForbidden`）

### ビルド

```sh
./build.sh
```
