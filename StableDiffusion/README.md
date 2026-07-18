# Stable Diffusion TOP — text2img / img2img（macOS / Core ML）

Apple 公式 [ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) の
Core ML パイプラインで **TD 内から画像生成**する カスタム TOP。
SD 2.x 系 / SDXL 系のモデルフォルダを自動判定（TextEncoder2.mlmodelc の有無）。

実測（M2 / SD 2.1 base split_einsum / 15 steps / CPU+ANE）:
**text2img 7.6秒・img2img 4.5秒**。モデルロード（初回のANEコンパイル）は約2分。

## 使い方

1. `Model Folder` に Core ML SD モデルのフォルダを指定
   （`TextEncoder.mlmodelc` `UnetChunk*.mlmodelc` `VAEDecoder.mlmodelc` 等が直下にある階層。
   モデルは Hugging Face の `apple/coreml-stable-diffusion-*` などから取得し
   `models/` に置く — **モデルはリポジトリに含まれない**）
2. Info DAT の status が `ready (SD)` / `ready (SDXL)` になるまで待つ
3. `Prompt` を書いて `Generate` をパルス → 完了すると出力テクスチャが差し替わる
4. **img2img**: 入力 TOP を接続し `Image to Image` をオン。`Strength` で元画像への忠実度
   （小さいほど元画像寄り）。入力はモデルのサンプルサイズ（512/1024）へ自動リサイズ

## パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| Model Folder | — | Core ML SD モデルフォルダ |
| Compute Units | CPU + Neural Engine | split_einsum は ANE 推奨。ORIGINAL 変換版は CPU+GPU |
| Prompt / Negative Prompt | — | プロンプト |
| Steps | 15 | サンプリングステップ（スケジューラは DPM-Solver++） |
| Guidance Scale | 7.5 | プロンプトへの忠実度 |
| Seed (-1 = Random) | -1 | 乱数シード。-1 で毎回ランダム（status に使用シードが出る） |
| Image to Image (Input 0) | Off | 入力 TOP を初期画像にする |
| Img2img Strength | 0.6 | ノイズ量（1.0 で実質 text2img） |
| Generate | — | 生成実行（busy 中のパルスは無視） |
| Flip Output Vertically | On | TD の bottom-up に合わせる |

Info CHOP: `busy / step / steps / gen_seconds / image_serial / executes`（進捗バー等に使える）。
Info DAT: `status`（loading model / ready / generating / done (7.6s, seed 4242) / error...）。

## 注意

- 生成は非同期で TD のフレームは止まらない。busy 中の Generate は無視される
- モデルロードは初回が特に遅い（ANE コンパイル）。ロード完了までパラメータは効くが生成不可
- Swift ヘルパ（helper/ ・SPMで ml-stable-diffusion をビルド）を `libSDHelper.dylib` として同梱

## ビルド

```
./build.sh    # helper の swift build → plugin本体 → bundle（要ネットワーク初回のみ）
```
