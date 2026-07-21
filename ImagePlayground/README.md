# ImagePlayground TOP

Apple の **ImagePlayground** フレームワーク（`ImageCreator`・macOS 15.4+）で、**プロンプト＋
スタイル**から画像を生成する TOP。**外部モデル不要**（端末の Apple Intelligence が生成）。

Core ML の外部モデル（Stable Diffusion 等）を使う [CoreML ImageGen](../CoreMLImageGen/) とは
別系統。外部モデルを使わない Apple 標準の生成機能はこちらに分離してある。

## 出力

RGBA8 TOP。生成は非同期（cook はブロックしない）。Info CHOP は
`busy / gen_seconds / image_serial / executes`、Info DAT は `status`。

## パラメータ

| パラメータ | 説明 |
|---|---|
| Style | Animation / Illustration / Sketch の3種（Apple 仕様） |
| Prompt | 生成プロンプト |
| Generate | 生成をパルス |
| Flip Output Vertically | 出力の上下反転（既定On） |

## 注意（Apple 仕様の制約）

- **Apple Intelligence が有効な端末が必要**（macOS 15.4+）
- **人物はテキストのみからは生成できない**（顔ソース画像が必須のエラーになる）
- **Steps / Seed / Guidance / img2img は無し**。スタイルは上記3種のみ
- 初回は ImageCreator の準備に時間がかかることがある（Info DAT の status を確認）

## ビルド

```sh
./build.sh
```
