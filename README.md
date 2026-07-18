# TDAppleML — Apple ML フレームワーク × TouchDesigner カスタムOP群

Apple のオンデバイスML フレームワーク（Vision / Sound Analysis / Speech など）を
TouchDesigner のネイティブカスタムオペレータ（C++/Obj-C++ の `.plugin`）として使えるようにする
プラグイン集。**macOS 専用**。追加のモデルダウンロード・外部ランタイム・Python 環境は不要で、
Apple Silicon の Neural Engine / GPU をそのまま使う。

Windows+NVIDIA 専用の TD 標準オペレータ（Body Track CHOP 等）の macOS 代替を主眼に、
チャンネル形式は可能な限り**既存の標準OPと互換**にする方針。

## プラグイン一覧

| プラグイン | 種類 | 内容 | 状態 |
|---|---|---|---|
| [VisionPose](VisionPose/) | CHOP | 多人数ボディポーズ推定（34kp）。**Body Track CHOP（2D複数人）と完全互換のチャンネル形式**（body{i}:valid / bbox / trackingid / {kp}:u,v,confidence）。M2 実測 5人 60fps | ✅ 実装済み |
| [VisionSegment](VisionSegment/) | TOP | 人物セグメンテーション。**Nvidia Background TOP 代替**。統合マスク（VNGeneratePersonSegmentation）と人物別マスク R/G/B/A 分離（VNGeneratePersonInstanceMask・最大4人）| ✅ 実装済み |
| [VisionPose3D](VisionPose3D/) | CHOP | **単一人物の3Dポーズ推定**（VNDetectHumanBodyPose3D・macOS 14+）。17関節をメートル単位の3D座標+2D投影で出力、身長推定つき。約2fps（じっくり系） | ✅ 実装済み |
| [SoundClass](SoundClass/) | CHOP | **音の分類**（SNClassifySoundRequest・300種類以上: 拍手/歓声/笑い声/警報音等）。選択クラスの信頼度をチャンネル出力、ランキングは Info DAT。**独自 Core ML 音響モデル対応** | ✅ 実装済み |
| [ImageGen](ImageGen/) | TOP | **text2img / img2img**。バックエンド2種: Core ML Stable Diffusion（SD2.x/SDXL/Turbo・Turbo 1step 0.8秒でリアルタイム変換）/ **Image Playground**（ImageCreator API・モデル不要・2.7秒） | ✅ 実装済み |
| [FoundationModel](FoundationModel/) | DAT | **Apple Intelligence オンデバイスLLM**（FoundationModels・macOS 26+）。Instructions+Promptでテキスト生成、ストリーミング・マルチターン対応。API課金なし | ✅ 実装済み |
| [Translate](Translate/) | DAT | **オンデバイス翻訳**（Translation framework・macOS 15+）。DATのtext列を同形で翻訳出力。SpeechText直結でリアルタイム字幕翻訳 | ✅ 実装済み |
| [SpeechText](SpeechText/) | DAT | **ライブ文字起こし**（新 SpeechAnalyzer/SpeechTranscriber・macOS 26+・完全オンデバイス・TCC不要）。確定/途中テキストをテーブル出力。Swift ヘルパ dylib 同梱 | ✅ 実装済み |
| [VisionHand](VisionHand/) | CHOP | **手指トラッキング**（21関節×最大100手・左右判定つき）。u,v,confidence をチャンネル出力 | ✅ 実装済み |
| [VisionFace](VisionFace/) | CHOP | **顔検出+ランドマーク**（最大100顔）。bbox・roll/yaw/pitch・目/鼻/口、オプションで全76点。Face Track CHOP 代替 | ✅ 実装済み |
| [VisionText](VisionText/) | DAT | **OCR / テキスト認識**（日英ほか多言語・Accurate/Fast切替）。テキスト領域ごとに text/confidence/bbox をテーブル出力（読み順ソート） | ✅ 実装済み |
| [VisionSaliency](VisionSaliency/) | TOP | **顕著性マップ+オートフレーミング**（Attention/Objectness 切替）。ヒートマップに加え、注目領域bbox・視線重心・スムージング済みクロップ矩形をチャンネル出力 — Crop TOP 直結でカメラワーク自動化 | ✅ 実装済み |
| [CoreML](CoreML/) | TOP | **汎用 Core ML 推論**。任意の .mlpackage/.mlmodel を差し替えて深度推定・スタイル変換・分類等（Depth Anything V2 で実証: 518x392 約20fps・推論33ms）。出力は自動判別（Image/MultiArray→テクスチャ、分類→Info DAT） | ✅ 実装済み |
| [VisionFlow](VisionFlow/) | TOP | **オプティカルフロー**（VNGenerateOpticalFlowRequest）。**Optical Flow TOP（Nvidia専用）代替**。RG32Floatで動きベクトル場を出力（UV/Pixels切替）。720p 約15fps | ✅ 実装済み |
| [VisionSubject](VisionSubject/) | TOP | **任意被写体の切り抜き**（Subject Lifting・macOS 14+）。写真アプリ「被写体をコピー」と同じAPI。ソフトマスク/背景透過カットアウト/インスタンス分離。720p 約45ms | ✅ 実装済み |
| [VisionTrack](VisionTrack/) | CHOP | **任意オブジェクト追跡**（VNTrackObjectRequest）。初期bbox指定→追従、valid/u/v/w/h/confidence出力。3〜5ms/frame。Blob Track TOP 代替に近い | ✅ 実装済み |
| [FrameInterp](FrameInterp/) | TOP | **MLフレーム補間/モーションブラー**（VTFrameProcessor・macOS 15.4+）。前後フレームの中間生成（Phase指定）とML動きブラー。720p 約15fps | ✅ 実装済み |
| [Upscale](Upscale/) | TOP | **リアルタイム超解像**。**Nvidia Upscaler TOP 代替**。MetalFX Spatial（任意倍率・2x 16ms）/ VT Super Resolution（macOS 26+・4x固定・1.9s・ML高品質） | ✅ 実装済み |
| [VisionContours](VisionContours/) | SOP | **画像輪郭を閉じたLine primitiveへ変換**。親子階層属性と点数制御に対応し、Sweep/Extrude/Particleへ直結 | ✅ 実装済み |
| [VisionAnimalPose](VisionAnimalPose/) | CHOP | **犬・猫の2D姿勢推定**（25関節・複数匹）。bboxとu/v/confidenceを左→右スロット出力 | ✅ 実装済み |
| [VisionClassify](VisionClassify/) | DAT | **Apple標準モデルによる画像分類**。追加モデル不要でrank/identifier/confidenceを上位100件まで出力 | ✅ 実装済み |
| [VisionBarcode](VisionBarcode/) | DAT | **QR・各種バーコード検出**。payload、symbology、bbox、投影四隅をテーブル出力 | ✅ 実装済み |
| [VisionTrajectory](VisionTrajectory/) | CHOP | **放物運動する小物体の軌跡検出**。実測点/投影点、放物線係数、平均半径を出力 | ✅ 実装済み |
| [CoreMLCHOP](CoreMLCHOP/) | CHOP | **汎用Core MLベクトル推論**。画像入力モデルのMultiArrayを最大65536chへフラット化し、feature/shapeをInfo DAT出力 | ✅ 実装済み |
| [VisionRect](VisionRect/) | CHOP | **複数矩形検出**。confidence、bbox、投影四隅を最大100スロットへ出力しCorner Pinへ直結 | ✅ 実装済み |

## 必要環境

- macOS 12+（Apple Silicon 推奨）
- ビルドには Xcode（`clang++`）と TouchDesigner.app（C++ SDK ヘッダを流用）
- 実行は TD 2023 系以降（C++ CHOP API 対応ビルド）

## ビルドと使い方

```
cd VisionPose && ./build.sh      # → VisionPose/build/VisionPoseCHOP.plugin
```

- **手軽**: CPlusPlus CHOP の Plugin Path に `.plugin` を指定（再起動不要）
- **カスタムOPとして常設**: `~/Library/Application Support/Derivative/TouchDesigner099/Plugins/`
  に `.plugin` をコピー → TD 再起動で OP Create Dialog に現れる

各プラグインの詳細（パラメータ・チャンネル仕様・実装メモ）はサブフォルダの README を参照。

## 共通の実装パターン（新プラグインを足すときの型）

- `common/build_plugin.sh` — bundle 組み立て・署名の共通処理。各プラグインの build.sh は
  ソースとフレームワークを列挙するだけ
- TOP 入力は `downloadTexture`（BGRA8・**verticalFlip=true 必須**。TD のダウンロードは
  bottom-up で、そのまま Vision に渡すと検出しない）
- 推論はワーカースレッドで非同期に行い、cook をブロックしない（`getData()` は
  ワーカー側で呼ぶ。結果は1〜2フレーム遅れ）
- 動作診断用に Info CHOP チャンネル（executes / analyzes 等）を出す
