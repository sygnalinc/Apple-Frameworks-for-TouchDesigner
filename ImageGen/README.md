# Image Gen TOP — text2img / img2img（macOS / Core ML 画像生成）

Core ML の画像生成モデルで **TD 内から text2img / img2img** する カスタム TOP。
現行バックエンドは Apple 公式 [ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion)
（SD 2.x 系 / SDXL 系をモデルフォルダ内容で自動判定 — TextEncoder2.mlmodelc の有無）。
**Stable Diffusion 以外の Core ML 生成モデル**にも対応できるよう、推論はヘルパ dylib に
分離してある（バックエンド追加はヘルパ側の拡張で行う）。

実測（M2 / SD 2.1 base split_einsum / 15 steps / CPU+ANE）:
**text2img 7.6秒・img2img 4.5秒**。モデルロード（初回のANEコンパイル）は約2分。

## バックエンド

| Backend | 内容 | 実測(M2) |
|---|---|---|
| **Stable Diffusion (Core ML)** | ml-stable-diffusion。SD 2.x / SDXL / SD Turbo を Model Folder で指定(自動判定) | Turbo 1step **0.8秒** / SD2.1 15steps 7.6秒 |
| **Image Playground** | Apple の ImageCreator API(macOS 15.4+・Apple Intelligence必須)。**モデルフォルダ不要**。Style: Animation / Illustration / Sketch | 1536x1536 **2.7秒** |

Image Playground の注意:
- **人物はテキストのみから生成できない**(「顔のソース画像が必要」とエラーになる安全設計)。
  モノ・風景・動物などのプロンプト向き
- Steps / Guidance / Seed / img2img は Playground では無効(API仕様)
- 出力は安全フィルタ済み・スタイルは3種のみ

## 使い方

1. `Model Folder` に Core ML SD モデルのフォルダを指定
   （`TextEncoder.mlmodelc` `UnetChunk*.mlmodelc` `VAEDecoder.mlmodelc` 等が直下にある階層。
   モデルは Hugging Face の `apple/coreml-stable-diffusion-*` などから取得し
   `models/` に置く — **モデルはリポジトリに含まれない**）
2. Info DAT の status が `ready (SD)` / `ready (SDXL)` になるまで待つ
3. `Prompt` を書いて `Generate` をパルス → 完了すると出力テクスチャが差し替わる
4. **img2img**: 入力 TOP を接続し `Image to Image` をオン。`Strength` で元画像への忠実度
   （小さいほど元画像寄り）。入力はモデルのサンプルサイズ（512/1024）へ自動リサイズ

## SD Turbo でリアルタイム生成/変換

[SD Turbo](https://huggingface.co/apple/coreml-sd-turbo)（1〜数ステップの蒸留モデル）と
**Continuous Generate** を組み合わせると、連続生成＝リアルタイム変換になる:

1. `Model Folder` に SD Turbo の Core ML モデル（標準SD構成・自動判定で SD パイプライン）
2. **`Steps` = 1〜2、`Guidance Scale` = 1.0** ← Turbo は CFG 無効で使う。
   このパイプラインの CFG 式は `neg + g×(pos−neg)` なので **g=1.0 が「プロンプトのみ」**
   （0 にするとプロンプトが無視されるので注意）
3. `Continuous Generate` をオン → 前の生成が終わり次第、**最新の入力フレームと
   パラメータで自動再生成**し続ける（Generate パルス不要）
4. img2img でライブ映像変換する場合は `Image to Image` オン。Turbo では
   `Steps=2 × Strength=0.5`（実効1ステップ）あたりから調整

Seed は固定値にすると連続フレームの見た目が安定し、-1（ランダム）だと毎フレーム変化する。

## パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| Backend | Stable Diffusion | 生成バックエンド(上表) |
| Style (Playground) | Animation | Image Playground のスタイル |
| Model Folder | — | Core ML 画像生成モデルのフォルダ(SD バックエンドのみ) |
| Compute Units | CPU + Neural Engine | split_einsum は ANE 推奨。ORIGINAL 変換版は CPU+GPU |
| Prompt / Negative Prompt | — | プロンプト |
| Steps | 15 | サンプリングステップ（スケジューラは DPM-Solver++） |
| Guidance Scale | 7.5 | プロンプトへの忠実度 |
| Seed (-1 = Random) | -1 | 乱数シード。-1 で毎回ランダム（status に使用シードが出る） |
| Image to Image (Input 0) | Off | 入力 TOP を初期画像にする |
| Img2img Strength | 0.6 | ノイズ量（1.0 で実質 text2img） |
| Generate | — | 生成実行（busy 中のパルスは無視） |
| Continuous Generate | Off | 完了し次第つねに再生成（リアルタイム変換モード） |
| Flip Output Vertically | On | TD の bottom-up に合わせる |

Info CHOP: `busy / step / steps / gen_seconds / image_serial / executes`（進捗バー等に使える）。
Info DAT: `status`（loading model / ready / generating / done (7.6s, seed 4242) / error...）。

## 注意

- 生成は非同期で TD のフレームは止まらない。busy 中の Generate は無視される
- モデルロードは初回が特に遅い（ANE コンパイル）。ロード完了までパラメータは効くが生成不可
- Swift ヘルパ（helper/ ・SPMで ml-stable-diffusion をビルド）を `libImageGenHelper.dylib` として同梱

## ビルド

```
./build.sh    # helper の swift build → plugin本体 → bundle（要ネットワーク初回のみ）
```
