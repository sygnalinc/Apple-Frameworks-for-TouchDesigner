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
| VisionHand | CHOP | 手指21点（VNDetectHumanHandPoseRequest） | 構想 |
| VisionFace | CHOP | 顔ランドマーク（VNDetectFaceLandmarksRequest）。Face Track CHOP 代替 | 構想 |
| VisionText | DAT | OCR（VNRecognizeTextRequest） | 構想 |
| VisionSaliency | TOP | 顕著性マップ（VNGenerateAttentionBasedSaliencyImageRequest） | 構想 |
| SoundClass | CHOP | 環境音分類（SNClassifySoundRequest） | 構想 |

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
