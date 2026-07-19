# TDAppleML — Apple のオンデバイスML を TouchDesigner のネイティブOP に

macOS / Apple Silicon の**オンデバイスML(Vision / Core ML / Speech / Sound Analysis /
Natural Language / ScreenCaptureKit ほか)を、TouchDesigner のカスタムオペレータ**として
使えるようにするプラグイン集です。

- **macOS 専用**。Neural Engine / GPU をそのまま使うので、外部ランタイム・Python 環境・
  クラウドAPI は不要(モデル同梱のものは追加ダウンロードも不要)
- 推論はワーカースレッドで非同期に走り、**cook をブロックしない**(TD 本体のfpsを保つ)
- **Windows+NVIDIA 専用の TD 標準OP の macOS 代替**を主眼にしたものは、チャンネル/
  テクスチャ形式を既存OPに極力合わせています

各プラグインの詳細(パラメータ・出力仕様・実測値・注意)は**サブフォルダの README** を参照。
`sample.toe` の `/project1/examples` に**全OPの最小利用例**をカテゴリ別に配置しています。

## Nvidia専用OPの macOS 代替として

| やりたいこと | TD標準(Win+NVIDIA) | このリポジトリ |
|---|---|---|
| 人物ポーズ推定 | Body Track CHOP | [VisionPose](VisionPose/) |
| 背景除去・人物マスク | Nvidia Background TOP | [VisionSegment](VisionSegment/) |
| 超解像アップスケール | Nvidia Upscaler TOP | [Upscale](Upscale/) |
| オプティカルフロー | Optical Flow TOP | [VisionFlow](VisionFlow/) |
| 顔トラッキング | Face Track CHOP | [VisionFace](VisionFace/) |

---

## 人物・顔・手のトラッキング

| プラグイン | 種類 | 内容 |
|---|---|---|
| [VisionPose](VisionPose/) | CHOP | 多人数の2Dボディポーズ(34キーポイント)。**Body Track CHOP と互換のチャンネル形式**。5人60fps |
| [VisionPose3D](VisionPose3D/) | CHOP | 単一人物の**3Dポーズ**(17関節・メートル単位+2D投影・身長推定)。約2fpsのじっくり系 |
| [VisionHand](VisionHand/) | CHOP | 手指トラッキング(21関節×最大100手・左右判定) |
| [VisionFace](VisionFace/) | CHOP | 顔検出+bbox・roll/yaw/pitch・ランドマーク(最大76点)・顔写りスコア。**Face Track CHOP 代替** |
| [VisionSegment](VisionSegment/) | TOP | 人物セグメンテーション。**Nvidia Background TOP 代替**(統合マスク/人物別R/G/B/A分離) |

## 物体・シーンの認識・読み取り

| プラグイン | 種類 | 内容 |
|---|---|---|
| [CoreMLDetect](CoreMLDetect/) | DAT | **物体検出**。YOLO等のCore MLモデルで「何が・どこに」を label/confidence/bbox で出力 |
| [VisionClassify](VisionClassify/) | DAT | **画像分類**(追加モデル不要)。上位N件の identifier/confidence |
| [VisionAnimalPose](VisionAnimalPose/) | CHOP | 犬・猫の2D姿勢推定(25関節・複数匹) |
| [VisionRect](VisionRect/) | CHOP | 矩形検出→bbox/投影四隅(Corner Pin 直結) |
| [VisionBarcode](VisionBarcode/) | DAT | QR・各種バーコード検出→payload / symbology / bbox / 四隅 |
| [VisionText](VisionText/) | DAT | **OCR / テキスト認識**(多言語・読み順ソート・Accurate/Fast) |
| [VisionTrajectory](VisionTrajectory/) | CHOP | 放物運動する小物体の軌跡検出(実測点/投影点/放物線係数) |
| [VisionHorizon](VisionHorizon/) | CHOP | 水平線・地平線の角度と補正transform |
| [VisionAesthetics](VisionAesthetics/) | CHOP | 写真の**美的スコア**(-1〜+1)。ベストショット自動選択に |
| [ImageMetadata](ImageMetadata/) | DAT | 画像ファイルの EXIF/GPS/IPTC 読み取り(GPS十進度変換つき) |

## 切り抜き・マスク

| プラグイン | 種類 | 内容 |
|---|---|---|
| [VisionSubject](VisionSubject/) | TOP | **任意被写体の切り抜き**(写真アプリ「被写体をコピー」と同じAPI)。ソフトマスク/背景透過 |
| [SAM2Segment](SAM2Segment/) | TOP | **点を指定して任意物体をマスク**(SAM 2.1)。観客が触れたものを切り抜く演出に |
| [VisionBokeh](VisionBokeh/) | TOP | マスクで被写体を保持したまま**背景を可変ぼかし** |

## 追跡・モーション・カメラワーク

| プラグイン | 種類 | 内容 |
|---|---|---|
| [VisionTrack](VisionTrack/) | CHOP | **任意オブジェクトの追跡**(初期bbox→追従)。Blob Track TOP 代替に近い |
| [VisionFlow](VisionFlow/) | TOP | **オプティカルフロー**(動きベクトル場)。**Optical Flow TOP 代替**(UV/Pixels) |
| [VisionSaliency](VisionSaliency/) | TOP | 顕著性マップ+**オートフレーミング**(注目領域のクロップ矩形を Crop TOP 直結でカメラワーク自動化) |
| [VisionSimilarity](VisionSimilarity/) | CHOP | 2つの画像の**類似度**(Feature Print)。「参照画像に似たら発火」トリガー |

## 映像加工・超解像

| プラグイン | 種類 | 内容 |
|---|---|---|
| [Upscale](Upscale/) | TOP | **リアルタイム超解像**。**Nvidia Upscaler TOP 代替**(MetalFX 2x / VT SuperRes 4x / VT LowLatency) |
| [FrameInterp](FrameInterp/) | TOP | ML **フレーム補間 / モーションブラー**(中間フレーム生成) |
| [Denoise](Denoise/) | TOP | ML テンポラルノイズ除去(対応ハードのみ。M2非対応) |
| [VisionKeystone](VisionKeystone/) | TOP | 矩形の**自動透視補正**(紙面・スクリーン・投影面を正対化) |
| [ImageAutoEnhance](ImageAutoEnhance/) | TOP | 露出・彩度・色を自動補正(Core Image) |
| [MPSAnalyze](MPSAnalyze/) | CHOP | GPU画像統計(RGBAヒストグラム・平均色・輝度分布 76ch) |

## 汎用ML推論・画像生成

| プラグイン | 種類 | 内容 |
|---|---|---|
| [CoreML](CoreML/) | TOP | **任意の Core ML モデル**を差し替えて推論(深度推定・スタイル変換・分類等)。画像/配列出力を自動判別 |
| [CoreMLCHOP](CoreMLCHOP/) | CHOP | 任意の Core ML モデルの**ベクトル出力**をCHへ(埋め込み・キーポイント等) |
| [ImageGen](ImageGen/) | TOP | **text2img / img2img**(Core ML Stable Diffusion / Image Playground) |
| [CoreImageCode](CoreImageCode/) | TOP | QR / Aztec / PDF417 / Code128 の**生成**(外部ライブラリ不要) |

## 音声・音響

| プラグイン | 種類 | 内容 |
|---|---|---|
| [SoundClass](SoundClass/) | CHOP | **音の分類**(拍手/歓声/警報音等 300種類+)。独自 Core ML 音響モデルも可 |
| [SoundFeatures](SoundFeatures/) | CHOP | 音響特徴(RMS/peak/centroid/onset/beat/BPM/16帯域) |
| [SpeechText](SpeechText/) | DAT | **ライブ文字起こし**。Apple SpeechAnalyzer(macOS26+)/ WhisperKit(macOS14+・多言語・英訳) |
| [SpeechSynth](SpeechSynth/) | CHOP | オンデバイス**音声合成**→ PCM stereo |
| [VoiceActivity](VoiceActivity/) | CHOP | **発話区間検出**(speaking/onset/offset)。文字起こしの開始・終了トリガーに |
| [Shazam](Shazam/) | DAT | **自作音源のオフライン照合**(ShazamKit)。会場音源にショー進行を同期 |
| [SystemAudio](SystemAudio/) | CHOP | macOS の**システム音声**を取得(ScreenCaptureKit・48kHz stereo) |

## 言語・テキスト

| プラグイン | 種類 | 内容 |
|---|---|---|
| [FoundationModel](FoundationModel/) | DAT | **Apple Intelligence オンデバイスLLM**(macOS26+)。**構造化出力(JSONスキーマ)**でショー制御へ直結 |
| [Translate](Translate/) | DAT | **オンデバイス翻訳**。SpeechText 直結でリアルタイム字幕翻訳 |
| [TextAnalyze](TextAnalyze/) | DAT | 感情スコア・言語判定・固有表現・意味的類似度(日本語対応)。「発話の感情/話題でビジュアル制御」 |

## 3D・画面・入力デバイス・外部連携

| プラグイン | 種類 | 内容 |
|---|---|---|
| [Photogrammetry](Photogrammetry/) | SOP | **写真フォルダ→3Dメッシュ**(RealityKit Object Capture)。テクスチャ付きOBJ出力 |
| [VisionContours](VisionContours/) | SOP | 画像の輪郭を**閉じたLineジオメトリ**へ(Sweep/Extrude/Particle 直結) |
| [ScreenCapture](ScreenCapture/) | TOP | ディスプレイ/単一ウインドウの**画面収録**(最大120fps) |
| [Multipeer In / Out](MultipeerCHOP/) | CHOP | **iPhone/iPad をワイヤレスセンサーに**(ジャイロ/加速度/タッチを低遅延受信)。**iOSアプリ同梱** |
| [Multipeer In / Out](Multipeer/) | DAT | Mac/iPhone 間の**ローカルP2Pテキスト**(自動接続・サーバー不要) |
| [GameController](GameController/) | CHOP | PS5/Xbox/MFi **ゲームパッド入力**(スティック/トリガー+モーション+ランブル) |
| [Shortcuts](Shortcuts/) | DAT | **macOSショートカット実行**(HomeKit照明・家電・通知を TD イベントから) |

---

## 使い方

### 1. プラグインをビルド

```
cd VisionPose && ./build.sh      # → VisionPose/build/VisionPoseCHOP.plugin
```

前提: Xcode(`clang++`)と TouchDesigner.app(C++ SDK ヘッダを流用)。実行は TD 2023 系以降。

### 2. TouchDesigner で使う

- **お試し**: `C++ CHOP/TOP/DAT/SOP` を置き、Plugin Path に `.plugin` を指定(再起動不要)
- **常設のカスタムOPとして**:
  `~/Library/Application Support/Derivative/TouchDesigner099/Plugins/` に `.plugin` をコピー
  → TD 再起動で OP Create Dialog に現れる

モデルを使うプラグイン(CoreML / SAM2 / ImageGen 等)は、各 README のリンク先から
Apple公式の Core ML モデルを `models/`(gitignore)へ置いてください。

## 必要環境

- macOS 12+(Apple Silicon 推奨)。一部の機能はより新しい macOS を要求(各 README に明記)
- ビルドに Xcode と TouchDesigner.app

## プラグインを自作する人へ

共通のビルド・実装パターン(非同期ワーカー、TOP のダウンロード flip、Info CHOP 診断 など)と
実際に踏んだハマりどころは [`CLAUDE.md`](CLAUDE.md) にまとめてあります。
`common/build_plugin.sh` が bundle 組み立て・署名を共通化しています。
