# ImagePlayground TOP

Apple の **ImagePlayground** フレームワーク（`ImageCreator`・macOS 15.4+）で、**プロンプト＋
スタイル**から画像を生成する TOP。**外部モデル不要**（端末の Apple Intelligence が生成）。

Core ML の外部モデル（Stable Diffusion 等）を使う [CoreML ImageGen](../CoreMLImageGen/) とは
別系統。外部モデルを使わない Apple 標準の生成機能はこちらに分離してある。

## 入出力

- **入力0（任意）= ソース画像（顔）TOP**。**人物を生成するには顔画像が必須**（Apple 仕様）。
  顔を含む TOP を入力0に接続すると `ImagePlaygroundConcept.image` として渡され、その人物を
  もとに生成する。人物以外（モノ・風景等）は入力なしでプロンプトだけでよい
- 出力 = RGBA8 TOP。生成は非同期（cook はブロックしない）。Info CHOP は
  `busy / gen_seconds / image_serial / executes`、Info DAT は `status`

## 人物を生成する

プロンプトだけで人物を出そうとすると
`generate error: Provide a source image containing a person's face...` になる（Apple の安全設計）。
**入力0に顔画像 TOP を接続**して Generate すれば人物を生成できる:

1. 顔を含む画像 TOP（Movie File In / ImageIO File In / Video Device In 等）を**入力0**へ
2. Prompt に演出（例「in a colorful fantasy illustration」）、Style を選ぶ
3. Generate をパルス

顔が小さすぎると `faceInImageTooSmall`、非対応画像は `unsupportedInputImage` になる。
寄りの顔画像を使う。

## パラメータ

| パラメータ | 説明 |
|---|---|
| Style | Animation / Illustration / Sketch の3種（Apple 仕様） |
| Prompt | 生成プロンプト |
| Generate | 生成をパルス |
| Flip Output Vertically | 出力の上下反転（既定On） |

## 注意（Apple 仕様の制約）

- **Apple Intelligence が有効な端末が必要**（macOS 15.4+）
- **人物はテキストのみからは生成できない → 入力0に顔画像を接続する**（上記「人物を生成する」）
- **Steps / Seed / Guidance / img2img は無し**。スタイルは上記3種のみ
- 初回は ImageCreator の準備に時間がかかることがある（Info DAT の status を確認）
- **生成は前面のGUIアプリ（TouchDesigner）内でのみ動く**。ヘッドレス/バックグラウンド実行は
  Apple が禁止（`backgroundCreationForbidden`）

## ビルド

```sh
./build.sh
```
