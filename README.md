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
| [SpeechText](SpeechText/) | DAT | **ライブ文字起こし**。バックエンド2種: SpeechAnalyzer（macOS 26+・低遅延ストリーミング）/ **WhisperKit（macOS 14+・多言語・英訳対応**・tiny〜large-v3、日英で実測）。TCC不要 | ✅ 実装済み |
| [VisionHand](VisionHand/) | CHOP | **手指トラッキング**（21関節×最大100手・左右判定つき）。u,v,confidence をチャンネル出力 | ✅ 実装済み |
| [VisionFace](VisionFace/) | CHOP | **顔検出+ランドマーク**（最大100顔）。bbox・roll/yaw/pitch・目/鼻/口、オプションで全76点。Face Track CHOP 代替 | ✅ 実装済み |
| [VisionText](VisionText/) | DAT | **OCR / テキスト認識**（日英ほか多言語・Accurate/Fast切替）。テキスト領域ごとに text/confidence/bbox をテーブル出力（読み順ソート） | ✅ 実装済み |
| [VisionSaliency](VisionSaliency/) | TOP | **顕著性マップ+オートフレーミング**（Attention/Objectness 切替）。ヒートマップに加え、注目領域bbox・視線重心・スムージング済みクロップ矩形をチャンネル出力 — Crop TOP 直結でカメラワーク自動化 | ✅ 実装済み |
| [CoreML](CoreML/) | TOP | **汎用 Core ML 推論**。任意の .mlpackage/.mlmodel を差し替えて深度推定・スタイル変換・分類等（Depth Anything V2 で実証: 518x392 約20fps・推論33ms）。出力は自動判別（Image/MultiArray→テクスチャ、分類→Info DAT） | ✅ 実装済み |
| [VisionFlow](VisionFlow/) | TOP | **オプティカルフロー**（VNGenerateOpticalFlowRequest）。**Optical Flow TOP（Nvidia専用）代替**。RG32Floatで動きベクトル場を出力（UV/Pixels切替）。720p 約15fps | ✅ 実装済み |
| [VisionSubject](VisionSubject/) | TOP | **任意被写体の切り抜き**（Subject Lifting・macOS 14+）。写真アプリ「被写体をコピー」と同じAPI。ソフトマスク/背景透過カットアウト/インスタンス分離。720p 約45ms | ✅ 実装済み |
| [VisionTrack](VisionTrack/) | CHOP | **任意オブジェクト追跡**（VNTrackObjectRequest）。初期bbox指定→追従、valid/u/v/w/h/confidence出力。3〜5ms/frame。Blob Track TOP 代替に近い | ✅ 実装済み |
| [FrameInterp](FrameInterp/) | TOP | **MLフレーム補間/モーションブラー**（VTFrameProcessor・macOS 15.4+）。前後フレームの中間生成（Phase指定）とML動きブラー。720p 約15fps | ✅ 実装済み |
| [Upscale](Upscale/) | TOP | **リアルタイム超解像**。**Nvidia Upscaler TOP 代替**。バックエンド3種: MetalFX Spatial（任意倍率・2x 16ms）/ VT Super Resolution（4x固定・1.9s・高品質）/ **VT Low Latency ML（2x・21ms・入力96〜960px）** | ✅ 実装済み |
| [CoreMLDetect](CoreMLDetect/) | DAT | **汎用物体検出**。YOLOv3等の検出Core MLモデルで「何が・どこに」をテーブル出力（label/confidence/bbox）。M2実測 YOLOv3 38ms≈26fps・banana 0.994 | ✅ 実装済み |
| [TextAnalyze](TextAnalyze/) | DAT | **テキスト解析**（NaturalLanguage）。感情スコア・言語判定・固有表現（人名/地名/組織）・参照テキストとの意味的類似度。SpeechText直結で「発話の感情/話題でビジュアル制御」 | ✅ 実装済み |
| [Denoise](Denoise/) | TOP | **MLテンポラルノイズ除去**（VTTemporalNoiseFilter・macOS 26+）。**M2は非対応**（isSupported=false・エラー表示のみ）。対応ハード向け実装 | ⚠ M2非対応 |
| [SAM2Segment](SAM2Segment/) | TOP | **点指定で任意物体マスク**（SAM 2.1・Apple公式Core ML）。エンコード390ms+デコード40ms — 静止画は点を動かすだけで25fps級のインタラクティブ選択。観客が触れたものを切り抜く演出に | ✅ 実装済み |
| [Shazam](Shazam/) | DAT | **自作音源のオフライン照合**（ShazamKit カスタムカタログ）。どの曲の何秒目かを判定（実測 offset 29.06s特定）— 会場音源にショー進行を同期 | ✅ 実装済み |
| [Photogrammetry](Photogrammetry/) | SOP | **写真→3Dメッシュ**（RealityKit Object Capture）。写真フォルダからUSDZ/OBJ生成しSOPジオメトリ出力（templeRing 47枚→1416点/2835三角形・約1分で実証） | ✅ 実装済み |
| [VisionAesthetics](VisionAesthetics/) | CHOP | **写真の美的スコア**（macOS 15+・-1〜+1とutility判定）。ベストショット自動選択に | ✅ 実装済み |
| [ImageMetadata](ImageMetadata/) | DAT | **EXIF/GPS/IPTC読み取り**（ImageIO・ファイル直読み）。GPS十進度変換つき。撮影情報を演出パラメータに | ✅ 実装済み |
| [Shortcuts](Shortcuts/) | DAT | **macOSショートカット実行ブリッジ**（shortcuts CLI）。HomeKit照明・家電・通知をTDイベントから。一覧取得・入出力受け渡し対応 | ✅ 実装済み |
| [Multipeer](Multipeer/) | DAT | **Mac/iPhone間ローカルP2P**（MultipeerConnectivity）。自動発見・自動接続でテキスト送受信（2ノード相互接続・送受信を実測）。サーバー不要 | ✅ 実装済み |
| [GameController](GameController/) | CHOP | **ゲームパッド入力**（PS5/Xbox/MFi）。アナログトリガー・モーション・ランブル対応。Joystick CHOPのモダン代替 | ⚠ 実機パッド未検証 |
| [VisionContours](VisionContours/) | SOP | **画像輪郭を閉じたLine primitiveへ変換**。親子階層属性と点数制御に対応し、Sweep/Extrude/Particleへ直結 | ✅ 実装済み |
| [VisionAnimalPose](VisionAnimalPose/) | CHOP | **犬・猫の2D姿勢推定**（25関節・複数匹）。bboxとu/v/confidenceを左→右スロット出力 | ✅ 実装済み |
| [VisionClassify](VisionClassify/) | DAT | **Apple標準モデルによる画像分類**。追加モデル不要でrank/identifier/confidenceを上位100件まで出力 | ✅ 実装済み |
| [VisionBarcode](VisionBarcode/) | DAT | **QR・各種バーコード検出**。payload、symbology、bbox、投影四隅をテーブル出力 | ✅ 実装済み |
| [VisionTrajectory](VisionTrajectory/) | CHOP | **放物運動する小物体の軌跡検出**。実測点/投影点、放物線係数、平均半径を出力 | ✅ 実装済み |
| [CoreMLCHOP](CoreMLCHOP/) | CHOP | **汎用Core MLベクトル推論**。画像入力モデルのMultiArrayを最大65536chへフラット化し、feature/shapeをInfo DAT出力 | ✅ 実装済み |
| [VisionRect](VisionRect/) | CHOP | **複数矩形検出**。confidence、bbox、投影四隅を最大100スロットへ出力しCorner Pinへ直結 | ✅ 実装済み |
| [VisionKeystone](VisionKeystone/) | TOP | **矩形の自動透視補正**。VisionRect CHOPの四隅または手動四隅から紙面・スクリーン・投影面を正対化。Core Image使用 | ✅ 実装済み |
| [SoundFeatures](SoundFeatures/) | CHOP | **音響特徴量解析**。RMS/Peak/FFT帯域/centroid/flux/onset/beat/BPMと16帯域をAccelerate/vDSPで非同期出力 | ✅ 実装済み |
| [ScreenCapture](ScreenCapture/) | TOP | **macOS画面キャプチャ**。ScreenCaptureKitでディスプレイまたは単一ウインドウを指定解像度・最大120fpsで取得 | ✅ 実装済み |
| [VisionSimilarity](VisionSimilarity/) | CHOP | **画像類似度**。Vision Feature Printで2つのTOPのdistance/similarity/matchをモデル追加なしで出力 | ✅ 実装済み |
| [VoiceActivity](VoiceActivity/) | CHOP | **発話区間検出**（SpeechDetector・macOS 26+）。speaking/onset/offsetと区間時刻を完全オンデバイス出力 | ✅ 実装済み |
| [VisionBokeh](VisionBokeh/) | TOP | **マスク可変ぼかし**。VisionSubject等のマスクから被写体を保持した背景ボケをCore Imageで生成 | ✅ 実装済み |
| [MPSAnalyze](MPSAnalyze/) | CHOP | **GPU画像統計**。Metal Performance ShadersのRGBAヒストグラムと平均・輝度分布を76chで出力 | ✅ 実装済み |
| [SystemAudio](SystemAudio/) | CHOP | **macOSシステム音声キャプチャ**。ScreenCaptureKitから48kHz stereoを取得し、ScreenCapture TOPと併用可能 | ✅ 実装済み |
| [VisionHorizon](VisionHorizon/) | CHOP | **水平線・地平線検出**。angle、補正transform、confidenceを出力。640x360初回約38ms | ✅ 実装済み |
| [CoreImageCode](CoreImageCode/) | TOP | **QR/Aztec/PDF417/Code 128生成**。Core Image標準generator、外部ライブラリ不要。512x512出力を実機確認 | ✅ 実装済み |
| [ImageAutoEnhance](ImageAutoEnhance/) | TOP | **画像の自動補正**。Core Imageが露出・彩度・色補正filterを自動選択。640x360約32ms | ✅ 実装済み |
| [SpeechSynth](SpeechSynth/) | CHOP | **オンデバイス音声合成**。AVSpeechSynthesizerのSystem VoiceをPCM stereo CHOPへ出力 | ✅ 実装済み |
| [MusicCompose](MusicCompose/) | DAT | **アルゴリズム／Foundation Models作曲**。コード・ベース・メロディ・ドラムを共通MIDI event JSONへ生成 | ✅ 実装済み |
| [MusicSequence](MusicSequence/) | CHOP | **SoundFont/内蔵シンセ楽曲レンダリング**。4つのApple Samplerへpad/bass/lead/drumsを分離し44.1kHz stereo化 | ✅ 実装済み |
| [MusicMIDI](MusicMIDI/) | CHOP | **外部DAWリアルタイム再生**。Core MIDI仮想ポートへ4トラックのNote/Clock/Transportを送信 | ✅ 実装済み |
| [MusicEvents](MusicEvents/) | DAT | **作曲MIDIイベント確認表**。小節・拍・パート・チャンネル・ノート名・長さ・ベロシティを一覧化 | ✅ 実装済み |

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
