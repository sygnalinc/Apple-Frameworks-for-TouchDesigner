# ハマりどころ集(フレームワーク別)

**全て実機で踏んだもの。** API制約で挙動が直感に反する箇所は太字。

## TD本体の挙動

- **同一パスの .plugin と依存dylibをプロセス内でキャッシュする**。リビルドしても reload で古い
  コードが動く。確実な反映はTD再起動。dylibは epoch 名でキャッシュ回避([build.md](build.md))
- cplusplus系は plugin設定直後にカスタムパラメータが未生成のことがある →
  `reinitpulse` パルス or 1フレーム待ち
- タイムライン停止(`root.time.play=False`)で frame系コールバックは全停止
- **CHOPは0ch出力を嫌う**。未確定時は1chダミー(`connected`等)を出す
- opTypeは family 間で重複可(Multipeer DAT と Multipeer CHOP が同名"Multipeer"で共存できる)
- Info DATの1行目はデータ行にもできる(ヘッダ固定ではない)。行数指定に注意

## Vision / 画像系

- **VNTrackObjectRequest は Revision1 を明示せよ**。既定のRevision2は macOS 26 で
  "unexpected tracked object bounding box size" を返して一切追跡しない(bboxサイズ変更は無駄)。
  無地単色被写体はテンプレート型の限界でbboxが膨張漂流(実写テクスチャなら誤差0.002uv級で追従)
- **generateMaskedImageOfInstances(VisionSubjectのCutout)は IOSurface非対応の
  CVPixelBuffer(CreateWithBytesラップ)だと nil を返す**。`CVPixelBufferCreate`
  (`kCVPixelBufferIOSurfacePropertiesKey`付き)+ 行コピーで渡す。マスク系は生ラップでも通るため
  気づきにくい
- **VNGeneratePersonInstanceMask は API上限4人**。VNDetectHumanBodyPose3D は**1人固定**・
  初回モデルロード約17秒・定常0.5秒(リアルタイム不可と明記)
- **SAM2(Apple Core ML版)のプロンプト座標は1024×1024ピクセル空間**。TD uv →
  `x=u*1024, y=(1-v)*1024`(正規化のまま渡すと常に左上が選ばれる)
- 顔・手は被写体が小さいと検出不安定(引きの全身は無理)。寄り画角かCropで拡大
- Vision座標は **0〜1・左下原点**。TDのuv系と同じなので無変換で整合
- 静止画入力では totalCooks が変わらず再解析されない → パラメータ変更検知で再投入
- Body Track CHOP互換を名乗るなら**チャンネル名と順序の完全一致をテーブル比較で検証**する
  (出典: 実機bclip + `libCHOP.dylib` の strings の34キーポイント名)

## 生成系(Core ML Stable Diffusion / Image Playground)

- ml-stable-diffusion の CFG式は `neg + g×(pos−neg)`。**Turbo系のCFG無効は Guidance=1.0**
  (0にするとプロンプト無視)。Turboは Steps=1〜2
- **ANE初回コンパイルは長い**(SD2.1 約2分・SDXL 10分超)。複数モデル同時ロードは
  ANECompilerServiceで直列化しさらに遅い。status="loading model" は故障ではない。2回目以降はキャッシュで速い
- Image Playground(ImageCreator)は**人物をテキストのみから生成できない**(顔ソース画像必須)。
  Steps/Seed/img2img等も無効。スタイル3種のみ

## VideoToolbox / MetalFX(Metal FrameInterp / Metal Upscale / Metal Denoise)

- **VTFrameProcessor系の対応ピクセル形式は 64RGBAHalf('RGhA')のみ**(FRC/MotionBlur/SuperRes 全て)。
  TDのRGBA16Floatダウンロード/アップロードと直結すれば無変換
- ピクセルバッファは config の source/destinationPixelBufferAttributes から `CVPixelBufferPool` で確保
  (自前Createは属性不一致で失敗しうる)
- **VTSuperResolutionScaler の対応倍率はハード依存で固定**(M2実測 4xのみ)。
  supportedScaleFactors にない倍率で init すると nil。入力はVideoタイプ・縦1080まで
- **VTLowLatencySuperResolutionScaler の対応形式は 420v(YCbCr)のみ**(他VT系の64RGBAHalfと違う)。
  vImage(ITU-R 601 videoRange)でBGRA↔420v変換。2x固定・入力96〜960px
- **VTTemporalNoiseFilter(Metal Denoise)は M2非対応**(isSupported=false・maximumDimensions=0x0)。
  VT系は必ず isSupported と supportedScaleFactors/maximumDimensions をプローブしてから設計する
- MetalFX Spatial は SharedストレージのテクスチャでOK(Apple Silicon)。outputTextureの usage は
  `scaler.outputTextureUsage` を必ず含める
- **ANE系プラグインの同時実行は競合で数倍遅くなる**(実測: YOLO 38→262ms、LLSR 4→324ms)。
  重いML系を複数常時走らせる設計は避け、READMEに明記

## Core Image(CoreImage Bokeh / Keystone / Enhance / Code)

- **別pluginパスからCIFilterを同時初期化すると `setValue:forKey:` 内部のKVC競合でEXC_BAD_ACCESS**。
  Core Image処理区間を `@synchronized([CIFilter class])` でプロセス横断直列化する
- Core Image出力は行反転してアップロード(top-down → TD)

## 音声・言語系

- **旧SFSpeechRecognizerは使うな**: TDのInfo.plistに NSSpeechRecognitionUsageDescription が無く
  TCCで詰む。新 **SpeechAnalyzer/SpeechTranscriber(macOS 26+)** はTCC不要・完全オンデバイス
- **TranslationSession は SwiftUI専用**(公開init無し)。ほぼ不可視の **2x2px・alpha 0.01・画面内**の
  ウインドウ+NSHostingView+translationTaskクロージャ内でキュー常駐、が動くワークアラウンド。
  **完全画面外や alpha 0.0 だと task が発火しない**
- 言語モデルの初回DLは数分(ja→en実測約5分)。statusで見せる
- FoundationModels は **Apple Intelligence有効**でないと unavailable。
  `SystemLanguageModel.default.availability` で理由分岐して status に出す
- FoundationModels構造化出力は DynamicGenerationSchema で "name:type" スキーマ → スキーマ保証JSON
- **Whisper(WhisperKit)は無音バッファに「[音楽]」等を幻覚する**。① RMS<0.004 のバッファは捨てる
  ② 括弧タグだけの確定行は破棄、の2段ガード必須。ストリーミング非対応なので
  「溜めて0.7秒毎に再認識 → 無音or30秒で確定行に落とす」チャンク方式
- **NLTagger は initWithTagSchemes に使う全スキームを列挙する**(TokenType入れ忘れで語数0)。
  列挙外スキームでenumerateしてもエラーにならず単に結果0件
- TextAnalyzeの感情スコアは日本語未対応(常に0)。日本語類似度は NLContextualEmbedding(BERT系・
  macOS14+)を第一候補に(平均プーリング+コサイン)。非対応言語/OSは NLEmbedding へフォールバック
- ShazamKitのカスタムカタログ照合はエンタイトルメント不要・完全ローカル。
  公式カタログ照合はエンタイトルメントが要るので手を出さない

## SOP(VisionContours / RealityKit Capture)

- **SOPプラグインは `executeVBO()` も実装必須**(純粋仮想。空実装でよい。忘れると abstract class エラー)
- **一括 `setTexCoords()` は先頭UVが全点に入る**(TD 2023系)。per-point の `setTexCoord()` を使う
- **PhotogrammetrySession の modelFile出力は USDZ のみ**(.obj指定は invalidOutput)。
  一時USDZ → ModelIO(MDLAsset.export)でOBJ変換。出力先に既存ファイルがあると invalidOutput なので
  開始前に削除
- USDZは実体zip。焼き込みテクスチャは `/usr/bin/unzip` で抽出し `.mtl` の `map_Kd` を書き換え

## 権限・環境が要るもの(READMEに明記)

- ScreenCaptureKit(Screen Capture / System Audio): 画面収録権限。初回はTCC拒否 → 許可後TD再起動で反映
- MultipeerConnectivity: ローカルネットワーク許可 + Bonjour サービスタイプ
- GameController / CoreHaptics: 実機パッド接続
- Shortcuts: `shortcuts` CLI 経由(ユーザー環境のショートカット)
