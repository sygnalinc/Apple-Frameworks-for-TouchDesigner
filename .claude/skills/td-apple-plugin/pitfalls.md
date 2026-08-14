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
- **Appleは対応チップの一覧を公開していない**。SDKヘッダも「current platform で isSupported を
  見よ」としか書いていないので、**動かすマシンで実測するしかない**。
  `tools/vtprobe.m` が一族(OpticalFlow/MotionBlur/FRC/SuperRes/TemporalNoise/LowLatency×2)を
  まとめて調べる。M2実測では**TemporalNoiseFilter だけが非対応で他6つは全部対応** —
  「Apple Silicon かどうか」「macOS 26 かどうか」の話ではない
- **非対応ハードは「エラー」ではなく「警告 + 入力の素通し」にする**。エラーにすると、
  非対応マシンで開いただけのネットワークが下流ごと止まる。`getErrorString` ではなく
  `getWarningString` を実装し、`process()` の冒頭で isSupported を見て入力をそのまま
  結果へコピーする(Metal Denoise がこの形。非対応OSの分岐も同じ扱いにする)
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
- **FoundationModels の macOS 27(AFM3世代)拡張**(全て `#available(macOS 27.0, *)` ガードで
  26互換を保てる):
  - モデル選択: `LanguageModelSession(model: some LanguageModel, ...)`。
    `PrivateCloudComputeLanguageModel()`(Appleサーバ側・quota付き)も渡せる
  - `capabilities`(vision/reasoning/toolCalling/guidedGeneration)は `LanguageModel` プロトコル
    要件。**`contextSize` は PCC モデル専用**(async throws)— LanguageModelSession には無い
  - 画像入力: `Attachment(cgImage)` を `@PromptBuilder` クロージャに置く
    (`streamResponse(options:contextOptions:) { attachment; prompt }`)。vision capability 必須
  - Reasoning: `ContextOptions(reasoningLevel: .light/.moderate/.deep)` を
    streamResponse/respond の `contextOptions:` へ
  - トークン数: `session.usage.input/output.totalTokenCount`(27)
- **Whisper(WhisperKit)は無音バッファに「[音楽]」等を幻覚する**。① RMS<0.004 のバッファは捨てる
  ② 括弧タグだけの確定行は破棄、の2段ガード必須。ストリーミング非対応なので
  「溜めて0.7秒毎に再認識 → 無音or30秒で確定行に落とす」チャンク方式
- **NLTagger は initWithTagSchemes に使う全スキームを列挙する**(TokenType入れ忘れで語数0)。
  列挙外スキームでenumerateしてもエラーにならず単に結果0件
- TextAnalyzeの感情スコアは日本語未対応(常に0)。日本語類似度は NLContextualEmbedding(BERT系・
  macOS14+)を第一候補に(平均プーリング+コサイン)。非対応言語/OSは NLEmbedding へフォールバック
- ShazamKitのカスタムカタログ照合はエンタイトルメント不要・完全ローカル。
  公式カタログ照合はエンタイトルメントが要るので手を出さない

## RealityKit / RealityRenderer(RealityKit Splat 等のオフスクリーン描画)

- **`RealityRenderer` は `@MainActor` 拘束**(init / entities / updateAndRender すべて)。だが
  **TDの custom TOP の execute() はメインスレッドではない**(TDのcookスレッド)。
  `MainActor.assumeIsolated` を execute から呼ぶと trap する。解決策: **`DispatchQueue.main.async`
  で本物のメインスレッドへ描画を回す**。TDはメインランループをpumpするので実行される。cookは
  スケジュールするだけ(非ブロック)、GPU完了(`updateAndRender` の onComplete)で
  shared MTLTexture を CPU へ readback して latest バッファへ。cookは latest をTOPへupload
- **オフスクリーン描画はヘッドレス(ウィンドウ無し)で動く**。`RealityRenderer.CameraOutput`
  の `.singleProjection(colorTexture:)` に自前の MTLTexture(`.bgra8Unorm` / `.shared` /
  usage=[.renderTarget,.shaderRead])を渡し、`getBytes` で読み戻す
- **Gaussian Splat は macOS 27 の公開API `GaussianSplatComponent` / `GaussianSplatResource` で描く**
  (26以前はオフスクリーンでは点群もsplatも描画不可だった。**27 では RealityRenderer の
  オフスクリーン描画でsplatが出る**・実測)。ファイルローダは無いので **3DGS .ply は自前パース**して
  `LowLevelBuffer` へ投入する。実測で踏んだ罠:
  - **opacity 等に NaN/Inf が1つでも混ざるとシーン全体が描画されない**
    (Consoleに `GSAsset: NaN/Inf detected in alphas buffer`)。パース時に必ず除去/置換する
  - **`LowLevelBuffer` の capacity にはアライメント要件がある**。count×12(float3ぴったり)だと
    `BufferResource` init が `invalid(bufferCapacity:)` を投げる → **256B境界へ切り上げ**、
    `bytesUsed` に実サイズを入れる
  - scale(log値)/opacity(logit)は生値のまま渡し、`scaleActivation = .exponential` /
    `opacityActivation = .sigmoid` に評価させる(自前で exp/sigmoid すると activation と二重になる)
  - ply の `rot_0..3` は **w,x,y,z** 順。RealityKit へは **x,y,z,w** で渡す(正規化も自前で)
  - SH は degree 0(f_dc_0..2 を float3)で十分きれい。degree 1〜3 の f_rest_* の
    バッファレイアウトは公開ドキュメントに無い(未検証)
  - 3DGS は Y下向き規約 → エンティティを X軸π回転で正立。フレーミングは bbox でなく
    **各軸中央値+距離70パーセンタイル**(遠方の背景splatで bbox が数百単位に巨大化するため)
- **`Entity.visualBounds` はシーンへ追加した後に取得する**。ロード直後は不定。さらに
  **`entity.scale = ...` でロード物を正規化しようとすると内部トランスフォームと複合して破綻**
  (16単位のモデルが 0.09 掛けで 150単位に肥大した実例)。**エンティティは変形せず、カメラ側で
  フレーミング**する(target=bounds中心、distance=bounds半径×倍率)。これなら被写体の絶対サイズに
  依存しない
- **PBRメッシュは IBL/ライトが無いと真っ黒**(Unlit材質は自己発光で見える)。`RealityRenderer`
  に簡易 IBL(`EnvironmentResource(equirectangular: CGImage)`・macOS 15+)+ `DirectionalLight`
  を常設する。splat/自発光系はライト非依存
- ModelIO(`MDLAsset.export`)は **`.usdz` 拡張子を書き出せない**("Unknown extension")。
  `.usdc`/`.usd` を使う。RealityKit はどれも読める

## 深度 / 画像補助データ / RAW / HDR(ImageIO・AVFoundation・Core Image)

- **iPhone写真の深度/視差/マットは ImageIO の補助データ**: `CGImageSourceCopyAuxiliaryDataInfoAtIndex`
  (type = `kCGImageAuxiliaryDataTypeDisparity/Depth/PortraitEffectsMatte/SemanticSegmentation*Matte`)。
  `kCGImageAuxiliaryDataInfoData`(CFData)+`...DataDescription`(Width/Height/BytesPerRow/PixelFormat)
- **深度の画素形式は DisparityFloat16/32・DepthFloat16/32・8bitマット**。float16→float32は Accelerate の
  `vImageConvert_Planar16FtoPlanarF`。BytesPerRow ≠ Width×bytes のことがあるので行ごとに処理
- **カメラ内部パラメータは AVDepthData**: `[AVDepthData depthDataFromDictionaryRepresentation:auxDict]`
  → `.cameraCalibrationData.intrinsicMatrix`(+`intrinsicMatrixReferenceDimensions` で解像度スケール)。
  ポートレート写真以外は nil なので FOV フォールバックを用意
- **HDRゲインマップ**: `CIImage(contentsOf:options:[kCIImageAuxiliaryHDRGainMap:@YES])` でゲインマップ、
  `[kCIImageExpandToHDR:@YES]` でHDR拡張(EDR・1.0超の値)。拡張の効きは画像のheadroomメタ依存
- **CIRAWFilter は JPEG/TIFFも開ける**が非RAWはセンサーデータ前提の現像とズレる(白飛び)。
  ノイズ除去/シャープは `*Supported` を確認してから適用
- **テスト素材の合成**: 深度HEICは `CGImageDestinationAddAuxiliaryDataInfo` に手組み辞書(CFData+
  DataDescription)で埋め込める。HDRゲインマップHEICは `CIContext.writeHEIFRepresentation` の
  option `.hdrGainMapImage`。文書画像はCoreTextで描画(`kCTFontAttributeName` 等のCFStringキー)。
  **ModelIO/ImageIO は DNG・USDZ を書き出せない**(DNGはCGImageDestination非対応、USDZは`.usdc`で代替)

## Cinematic(iPhone Cinematicモード動画)

- **実素材が必須で合成不可**: Cinematic動画は iPhone 13以降で撮影した実ファイルにのみ
  視差トラック(`cinematicDisparityTrack`)とメタデータトラックがある。**Apple公式サンプル
  "Playing and editing Cinematic mode video" はコードのみで動画非同梱**(自分の動画を開く前提)。
  ネットの拾い物.movは特殊トラックが無く検証に使えない → 実機撮影→AirDropが唯一確実
- セットアップ: `CNAssetInfo(asset:)` / `CNRenderingSession.Attributes(asset:)` /
  `CNRenderingSession(commandQueue:sessionAttributes:preferredTransform:quality:)` / `CNScript(asset:)`
- **メタデータはピクセルデコード不要**: `CNScript.frame(at:tolerance:)` → `.focusDisparity` /
  `.allDetections`(`CNDetection`: `.detectionType` / `.normalizedRect` / `.focusDisparity` /
  `.detectionID`)。`CNDetection.accessibilityLabel(for:)` で種別文字列。CHOPはこれだけで作れる
- **再レンダ**: 時刻tで video/disparity/metadata の3バッファをデコード →
  `CNRenderingSession.FrameAttributes(sampleBuffer: metaBuffer, sessionAttributes:)` に `.fNumber` /
  `.focusDisparity` を設定 → `session.encodeRender(to:cb, frameAttributes:, sourceImage:, sourceDisparity:, destinationImage:)`(Metal)
- **時刻指定デコード**: `AVAssetReader` に `timeRange` を1フレーム分だけ設定し3トラックの
  `AVAssetReaderTrackOutput` を追加(disparityは `outputSettings` で `kCVPixelFormatType_DisparityFloat16`、
  videoは `kCVPixelFormatType_64RGBAHalf`、metadataは `outputSettings: nil`)。3つを同時刻で引く
- **CHOP のシグネチャ罠**: `execute(CHOP_Output*` は**非const**(`const` を付けると override されず
  abstract class エラー)。`CHOP_GeneralInfo` のフィールドは `timeslice`(小文字s)
- 1フォルダから2バンドル(CHOP+TOP)を共有Swiftヘルパで作る場合、build.sh は共通ヘルパを使わず
  `build_one` を2回(Multipeer In/Out と同型)
- **再レンダのメタデータは `AVAssetReaderOutputMetadataAdaptor` 経由(実機で踏んだ)**:
  メタデータtrackを生の `copyNextSampleBuffer` で読むと `CNRenderingSession.FrameAttributes(sampleBuffer:)`
  も `AVTimedMetadataGroup(sampleBuffer:)` も nil を返す。`AVAssetReaderOutputMetadataAdaptor` で
  `nextTimedMetadataGroup()` を得て `FrameAttributes(timedMetadataGroup:)` に渡すと通る。
  再レンダは video(64RGBAHalf)+ disparity(IOSurface付き)+ metadata(adaptor)を同時刻デコード →
  `session.encodeRender(sourceImage:sourceDisparity:destinationImage:)`(Metal)
- **AVAssetReader の CVPixelBuffer は reader を破棄すると無効化**(実機で踏んだ)。`cancelReading()` や
  reader の deinit 後に変換すると解放済みメモリを読む(実行毎に値が変わるガベージ)。**reader と
  CMSampleBuffer を変換完了まで保持**する(`alwaysCopiesSampleData=true` だけでは不十分、reader自体を生かす)
- **Swiftの `memcpy(&array[i], &array[j], n)` は不安定**(実機で踏んだ)。`&array[要素]` は一時コピーを
  作りうるので行反転コピー等で出力が壊れる。`withUnsafeMutableBufferPointer`/`withUnsafeBufferPointer`
  でベースポインタを取り `base + offset` で memcpy する
- **Cinematic視差の無効画素は巨大なsentinel値(実測 1.566e38)**。`isFinite` は通過するので
  正規化が壊れる。`v <= 0 || v > 1e4` も無効として除外してから min-max 正規化する
- **深度抽出(CPU読み)は IOSurface無しでタイトなbytesPerRow**、再レンダ(Metal)は IOSurface付き、と
  用途で `outputSettings` を分ける
- **転送方法で深度が失われる(最重要・実機で踏んだ)**: Cinematic動画をAirDropする際に
  共有→オプション→**「すべての写真データ(All Photos Data)」をオンにしないと、通常動画に平坦化**され
  視差トラックが消える(Apple公式)。その状態のファイルは `CNAssetInfo` が
  `CNCinematicErrorCodeIncomplete`(=3)を返す。**「読めない=形式が新しい」と早合点しない**。まず
  `AVAsset` のトラック構成を見る: 正常なCinematicは video + **disparity** + metadata を持つ。
  平坦化版は video(単層hvc1)+audio+meta のみで disparity が無い。正しく転送(All Photos Data ON、
  Mac側フォルダの「IMG_E」無しMOV)すれば iPhone 13〜17 いずれも Cinematic framework で読める想定
  ※ この点は当初「iPhone 17の新形式は読めない」と誤結論した。実際は転送で深度が剥がれていただけ

## CreateML(オンデバイス学習)

- **CreateML は Swift/Combine専用** → helper dylib 経由(ObjC++不可)。学習は非同期
  `train()→MLJob<T>`。`job.result`(Combine `AnyPublisher`)を `.sink` で購読し、完了で
  `model.write(to:)`。**`AnyCancellable` と `MLJob` を state に保持**しないと購読が即解放される
- 進捗は `job.progress.fractionCompleted`(Foundation `Progress`)を poll、精度は
  `model.trainingMetrics/validationMetrics.classificationError`(accuracy = 1 - error)
- 画像分類: `MLImageClassifier.DataSource.labeledDirectories(at:)`(サブフォルダ名=クラス)、
  `ModelParameters(validation:.split(strategy:.automatic), maxIterations:, augmentation:)`。
  `ImageAugmentationOptions` は OptionSet(flip/crop/rotation/blur/exposure/noise)
- **汎用トレーナ(CreateML DAT)で複数Taskを1本のヘルパに統合**する型: フォルダ系
  (Image/HandPose/Action/HandAction/Sound)は全て `.labeledDirectories(at:)`+`MLJob` で、
  ジェネリック `wireJob<T>(job, out, metrics:, write:)`(job.progress/cancel を型消去でstate保持、
  完了sinkで書き出し+精度)に集約できる。Activity は シーケンス列 `MLDataTable`、Tabular は
  `MLDataTable` を**バックグラウンドThreadで同期学習**(`MLClassifier/MLRegressor` は `MLJob` 版が無い)
- **API名の揺れに注意**(`swiftc -typecheck` で実SDK確認してから書く): `maxIterations`(Image/Sound)
  vs `maximumIterations`(HandPose/Action/HandAction/Activity)。`MLActionClassifier.ModelParameters` は
  `(validation:batchSize:maximumIterations:predictionWindowSize:augmentationOptions:algorithm:targetFrameRate:)`。
  **Tabular の `write(to:)` は `metadata: MLModelMetadata` が必須**(他分類器は `write(to:)` だけでよい)
- 精度は分類器なら全て `trainingMetrics/validationMetrics.classificationError`(accuracy = 1 - error)、
  回帰は `rootMeanSquaredError`。UIラベルに `(Activity)` `(Tabular)` 等を明記し、Taskごとに
  使うパラメータ/列だけ意味を持たせる(TDは setupParameters 後の動的enableが無いので**全部出して文書化**)
- **出力 .mlmodel は既存 CoreML TOP/CHOP/DAT/SoundClass がそのまま推論**(推論側の追加実装ゼロ)。
  「TD内で集める→学習→推論」を1つのネットワークで閉じられる
- pulse パラメータは `pulsePressed(name)` で検出(OP_Inputs無し)→ フラグを立てて
  execute でパラメータを読んで処理する
- **動作/ジェスチャ分類 `MLActivityClassifier` はフラット表を拒否**する
  ("<col> type is not a Sequence")。収録IDでグループ化し、**各特徴を `[Double]` 配列にした
  シーケンス列テーブル(1収録=1行、`MLDataTable(dictionary:)`)**を作って渡す。
  `train(trainingData:featureColumns:labelColumn:recordingFileColumn:parameters:)`、
  `ModelParameters(validation:, maximumIterations:, predictionWindowSize:)`。`recording` 列は
  **動作1回ごとに別ID**(全フレーム同一IDだと1サンプル扱いで学習不能)
- **ライブ推論CHOP側(CoreML Motion)**: モデル記述の `inputDescriptionsByName` から特徴入力
  (MultiArray shape[window])と state 入力(名前に "state"・shape[N])を分け、`classLabels` で
  チャンネル名を作る。入力CHOPを特徴名で**名前一致**バッファ(窓ぶんの deque)し、
  各特徴 `MLMultiArray[window]` + `stateIn`(初回0・`stateOut`をフィードバック)で予測。
  窓が埋まるまで無出力(`buffered < window`)
- **TDテスト入力の落とし穴**: constant CHOP の値式は Python。`sin(...)` は NameError で
  **式が壊れるとチャンネル自体が空**になり、推論CHOPは特徴不一致で0埋め→静止クラス誤判定。
  `math.sin`/`math.cos` を使う。推論ロジックの切り分けは**単体C ABI harness**(30/30正答)で先に確定させ、
  TD側は入力の生成だけを疑う

## SOP(VisionContours / RealityKit Capture / ImageIO PointCloud)

- **SOPプラグインは `executeVBO()` も実装必須**(純粋仮想。空実装でよい。忘れると abstract class エラー)
- **SOP_PluginInfo は `setAPIVersion()` で設定**(`apiVersion=` 直接代入は private でエラー)
- **`cplusplusSOP`(汎用C++ SOP)にプラグインパスを与えて試すとき、`.plugin` バンドルフォルダ名 =
  実行バイナリ名でないと dlopen 失敗**(TDはフォルダ basename でバイナリを探す)。/tmp へ別名コピーは
  実行名と同じフォルダ名で(例 `ImageIOPointCloudSOP.plugin`)。TOP/DATでは Info.plist が使われ緩いが SOP は厳しめ
- 点群は `addPoints` → `setColors(..., startIdx)` → `addParticleSystem(n, 0)` で描画可能な点群になる
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

## オーディオフィルタCHOP(音声in→音声out・timeslice)

- **音声フィルタCHOPは `getGeneralInfo` で `timeslice=true`**。入力の現在ブロック(N samples)を
  処理してN samples出力する。cook内でDSPして良い(重い推論ではないので非ブロック扱い)
- **`getOutputInfo` で入力と異なるch数を出すなら必ず `true` を返して numChannels を明示する**。
  入力接続時に `false` を返すと**出力ch数が入力に一致**させられる(inputMatchIndex)。
  例: モノ入力→バイノーラル2ch出力のつもりで false を返すと出力は1chになり、`channels[1]` への
  書き込みが**範囲外でTDが即クラッシュ**する(実測)。`return true` + `numChannels=2` にし、
  さらに execute 冒頭で `out->numChannels < 2` を弾く防御ガードを入れる
- 空間音響の要は **AVAudioEngine の manual rendering(offline)+ AVAudioSourceNode**:
  source の renderBlock で「現在のTD入力ブロック」を供給し、`renderOffline:N toBuffer:` で
  N frames レンダしてTDのオーディオグラフに戻す。**AVAudioSourceNode は AVAudio3DMixing に準拠**
  するので position/renderingAlgorithm(HRTF等)を直接設定できる(実測: 左定位で eL/eR≈2.9)
- 多音源(SpatialMixer)で1つの共有読み取り位置を使うと**プル順で壊れる**。音源ごとに独立した
  read position(vector)を持ち、renderOffline前に全て0リセットする
- **AUSpatialMixer('3dem')の多ch生設定は manual render で不安定(実測segfault)**。
  各入力chを標準スピーカー角度の positioned mono source として AVAudioEnvironmentNode に流す方が堅牢
- **AUAudioMix('amix'・macOS26)は type=`aufc`・入力4ch First-Order Ambisonics(layoutTag 0x930004)
  専用・出力5ch**。標準ステレオ/モノは setFormat で -10868 拒否。AU自身の inputBusses[0].format を
  connect に使えば通る。パラメータは Style(0-9)/Remix Amount(0-1)。合成入力では無音で、
  意味ある分離には実際の空間音声(4ch アンビソニックス)素材が必要
- **PHASEEngine は出力バッファ取得APIが無く**(start/stopでシステム出力へ直接再生)、
  レンダ結果をCHOPに戻せない。PHASEは「TD入力→物理ベース定位→デバイス(ヘッドホン)再生」の
  モデルでのみ使える(TDのオーディオグラフには戻らない)

## Core Audio Process Tap(Process Audio CHOP)

- **フロー**: `CATapDescription`(initStereoGlobalTapButExcludeProcesses / initStereoMixdownOfProcesses)
  → `AudioHardwareCreateProcessTap(desc,&tapID)` → tap UID(`kAudioTapPropertyUID`)→
  aggregate device 辞書(`kAudioAggregateDeviceTapListKey` に `{kAudioSubTapUIDKey:tapUID,
  kAudioSubTapDriftCompensationKey:@1}`, `kAudioAggregateDeviceIsPrivateKey:@1`)→
  `AudioHardwareCreateAggregateDevice` → `AudioDeviceCreateIOProcIDWithBlock` → `AudioDeviceStart`。
  IOProcの`in`バッファがタップ音声。ヘッダは `<CoreAudio/CATapDescription.h>` と
  `<CoreAudio/AudioHardwareTapping.h>` を明示import(CoreAudio.h だけでは足りない)
- **オーディオ出力CHOPは `getOutputInfo` で `info->sampleRate=48000` を必ず設定**する。未設定だと
  タイムラインFPS(60Hz)扱いになり timeslice が1cook十数サンプルの「音でない」出力になる(実測nsamp=12)
- IOProc(リアルタイムスレッド)→ CHOP は**ロックフリーSPSCリングバッファ**。消費(cook)が遅れて
  リング容量に近づいたら read を write-n へ**追いつかせて**溢れ(データ喪失)を防ぐ。強制cookは実時間が
  進まずリングを drain できないので、検証は実フレームcook(`run(...,delayFrames=i)`)+ 連続音源で
- **`initStereoGlobalTapButExcludeProcesses:` に自プロセス(TD)を渡すと捕捉が0になる場合がある**
  (実測)。Exclude は既定Offにし、必要時のみ使う
- PID指定は `kAudioHardwarePropertyTranslatePIDToProcessObject` で PID→プロセスAudioObjectID変換
- **Terminalからのprobeは捕捉できるがTD内で0** のときは、まず sampleRate 未設定と Exclude を疑う
  (TCCではなかった。実測でTD内でも peak=0.535 捕捉)

## Network / Bonjour(NSNetServiceBrowser)

- **必ず専用スレッド+常駐ランループで回す**。TDのcookスレッド任せだとブラウズ/リゾルブの
  コールバックが発火せず結果0になる。ランループは `NSMachPort` を1つ足して生かす
  (足さないと `runMode:beforeDate:` が即returnしてビジーループ)
- **cook→browserスレッドへ `performSelector:onThread:` で状態を渡すのは危険**(実測でTDが
  EXC_BAD_ACCESSクラッシュ)。設定は `@synchronized` の**保留キューに積むだけ**にし、
  browserスレッドが自分のループ内で適用する **polled 方式**にする
- **NSNetServiceBrowser / NSNetService の生成・破棄・列挙は全て browserスレッドに一極集中**。
  cook 側は不変スナップショット(NSDictionary配列)を `@synchronized` で読むだけにする

## ImageIO / EXIF Orientation

- iPhoneの縦写真は横センサー+**Orientation=6**で保存され、未対応だと横倒し。
  `kCGImagePropertyOrientation` を読み、8種を適用する
- **手動でEXIF回転を掛けるなら、主画像(CGBitmapContext描画)と補助データ(loadAux)の縦向きを
  必ず揃える**。`CGContextTranslateCTM(0,H)+ScaleCTM(1,-1)` は bottom-up を作り、loadAux(top-down)
  と混ざると回転が鏡像/上下逆に化ける(実測)。両者を top-down に統一してから同じ applyOrientation を掛ける

## MLX / mlx-swift（ローカルLLM）

- **mlx-swift の Metal シェーダ（`default.metallib`）は `swift build`（コマンドライン）では
  ビルドできない**。mlx-swift 公式README明記: "SwiftPM (command line) cannot build the Metal
  shaders so the ultimate build has to be done via Xcode"。`swift build` の実行ファイルは
  実行時に `MLX error: Failed to load the default metallib` で落ちる（モデルのロード/生成に到達しない）
- 解決: **xcodebuild でビルドする**。`xcodebuild build -scheme <PackageName> -configuration Release
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .xcbuild -skipPackagePluginValidation
  -skipMacroValidation`。metallib は `Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/
  Resources/default.metallib` に生成される
- **`-skipPackagePluginValidation` 必須**: mlx-swift の `CudaBuild` ビルドツールプラグインが
  xcodebuild で対話承認を要求し "Validate plug-in CudaBuild" で BUILD FAILED になる。
  **`-skipMacroValidation`** も付ける（swift-syntax マクロ MLXHuggingFace の承認回避）
- xcodebuild の実行ファイルは **静的リンク**（PackageFrameworks不要）。同梱するのは実行ファイル +
  `mlx-swift_Cmlx.bundle`（metallib）+ `swift-transformers_Hub.bundle`（tokenizer）を隣に置くだけ。
  SwiftPM実行ファイルの `Bundle.module` は実行ファイルと同じディレクトリを探す
- **重いLLM推論は dylib 同梱でなく「ヘルパ実行ファイルを別プロセスで spawn」が正解**。理由:
  metallib/rpath 解決が dylib 同梱だと壊れやすい、多GBモデル+Metalをプロセス隔離できTDを
  巻き込まない、停止でメモリを確実に解放。DAT は posix_spawn + pipe + reader thread で
  JSON-lines 通信（cook非ブロック）
- mlx-swift-lm は huggingface/transformers を内製化（MLXHuggingFace + マクロ）だが、マクロは
  `HuggingFace.HubClient` / `Tokenizers.AutoTokenizer` に展開されるので、**消費側パッケージも
  swift-huggingface + swift-transformers に依存**する必要がある。API: `#huggingFaceLoadModelContainer
  (configuration: ModelConfiguration(id:)) { progress }` → `ChatSession(container)` →
  `streamResponse(to:)`（AsyncThrowingStream でトークン）

## ImagePlayground (ImageCreator)

- **人物はテキストのみからは生成不可**(`conceptsRequirePersonIdentity` = "Provide a source
  image containing a person's face")。**顔画像を `ImagePlaygroundConcept.image(CGImage)` で
  concepts に渡す**と生成できる(TOP入力0にソース画像を接続)
- **ImageCreator の生成は前面GUIアプリ内でのみ動く**。ヘッドレスCLI/バックグラウンドは
  `backgroundCreationForbidden` で拒否 → ターミナルでの生成検証は不可(TD等の前面アプリで検証する)
- 顔が小さいと `faceInImageTooSmall`、非対応画像は `unsupportedInputImage`

## Custom OP メタデータ (OP_CustomOPInfo)

- **OP Create Dialog のホバー説明はカスタムopでは出せない**(SDKに該当フィールド無し)。
  代替は `opHelpURL`(Helpボタン→URL)と `pythonDoc`(docstring)
- **`opHelpURL` は構造体で `=nullptr` 既定**。opType/opLabel/opIcon はTDが確保するが opHelpURL は
  未確保の可能性 → `if (info->customOPInfo.opHelpURL) info->customOPInfo.opHelpURL->setString(url);`
  と null ガードして安全に設定する
- codesign の署名者名は証明書のCommon Name依存。Apple Development証明書は個人名が出る。
  会社名(SYGNAL Inc.)で署名するには Developer ID(法人アカウント)証明書が必要

## Python コールバック (pythonCallbacksDAT) — Custom OP からノード自動生成

- **`customOPInfo.pythonCallbacksDAT` に stub 文字列をセット**すると、ノードの **Custom ページ**に
  「Callbacks DAT」パラメータ(par名 `callbacks`)+ `Add` ボタンが付く。**Add を押すと stub が
  事前入力された Text DAT(`<node名>_callbacks`)が自動生成・接続**される(TD 2025系実測)
- C++ 側からの発火は `myNodeInfo->context->createArgumentsTuple(N, nullptr)`(index0=op済み・
  1以降を自分で埋める)→ `callPythonCallback("関数名", args, nullptr, nullptr)`。
  args と戻り値は Py_DECREF する。**Callbacks DAT が未接続 or 関数未定義なら Py_None が返るだけ**
  (エラーにならない)。cook スレッド(メインスレッド)から呼ぶこと
- **コールバック内の Python は何でもできる**= `parent().create(infoDAT, name)` 等で
  **Custom OP が自分の隣にノードを自動生成できる**(設置時無条件フックは無いが、パラメータ変化を
  トリガにすれば実用上同等)。二重生成ガード(`if p.op(name): return`)を stub に入れる
- ビルドは **`#include <Python.h>`(TD同梱 `Frameworks/Python.framework/Versions/3.11/include/python3.11`)
  + `-undefined dynamic_lookup`**。Py_* シンボルは実行時に TD 本体から解決される(nm -u で
  _PyBool_FromLong 等が U になっていればOK)。実例: CoreWLANScan(Get SSID ON → SSID Info DAT自動生成)
- **Callbacks DAT 自体も自動生成できる**(=配置するだけで全自動): 初回 cook で
  `PyRun_String` により雛形入り textDAT を生成して `par.callbacks` に接続する。ただし
  ①**`OP_NodeInfo::opPath` は空のことがある(macOS実測)** → パスで自ノードを引かず、
  `createArgumentsTuple(0)` の args[0](自ノードの PyObject)を `PyDict_SetItemString` で
  `__main__` に渡して参照する。②**生成直後の cook はカスタムパラメータ(callbacks含む)が
  未生成**で失敗する → 成功(=callbacks 接続済み)を `__cwlan_ok` のようなグローバルで
  読み戻し、**成功するまで毎 cook リトライ**する。③`PyRun_SimpleString`/`PyRun_String` の
  `__main__` には `op`/`textDAT` が無い → `import td` して `td.op`/`td.textDAT` を使う。
  ④例外は `__cwlan_err = traceback.format_exc()` でグローバルに残すと textport から調査できる
- **自動生成した DAT は GLSL 風に「ドックチップ」にできる**(ネットワークを散らかさない)。
  生成した Python 内で `d.dock = n`(ホストノードへドック)。**チップの↑(開)/↓(閉)の実体は
  `showDocked`**(docked側opのプロパティ。実機で glsl の開pixel/閉compute を全プロパティ差分して
  特定 — expose/viewer/display は開閉と無関係で全て同値だった):
  - **`d.expose = True` + `d.viewer = True` + `d.showDocked = False`** → GLSLのcompute DATと同じ
    **「閉じた↓チップ」**(CoreWLANScan の既定)。ユーザーがチップをクリックすると開いてテキストが見える
  - `d.showDocked = True` → 開いた状態(DATがホスト下にフルノード表示)
  - `d.expose = False` → **「×」チップ**になる(TD標準の閉じ方と見た目が違う)。通常は使わない
  ドック後は nodeX/nodeY 無効(位置はホスト追従)。ドック解除は `d.dock = None`。
  注意: ホスト(通常op)の showDocked は既定 True で別意味(自分の docked を表示するか)

## Core Text(テキストレンダリング)

- **文字送りの実測(英字・34pt)**: 1文字 ≒ **15px**、行送り ≒ **42px**。
  吹き出しの幅/高さを文字数から見積もるときの目安。見積りがずれても **Auto Fit** を
  On にしておけば縮めて収まるので破綻しない(逆に大きく余ると間延びして見える)
- **`Padl/Padr/Padt/Padb` で描画位置を決められる**ので、キャンバスを出力解像度いっぱいに
  取れば **Transform TOP を挟まずに好きな位置へテキストを置ける**
  (LINE風チャットの吹き出しは CoreText 1 + Rectangle 1 + Over 1 の3ノードで組んだ)

- **システムUIフォント(SF)のグリフ「アウトライン」は TD プロセス内では信用できない**(実測)。
  `kCGTextStroke` での再描画も `CTFontCreatePathForGlyph` のパス抽出も、特定グリフ(e/k/A/B等)に
  バー/矢印状のゴミ輪郭が混入する(単体プロセスでは同コードで再現せず・Helvetica等は正常)。
  **縁取りはアウトラインに依存しない「アルファマスク膨張」方式にする**: テキストを透明BGRAに描いて
  アルファ=カバレッジを取り、`CIMorphologyMaximum`(半径=縁幅)で膨張 → `CGImageMaskCreate`
  (mask値は 255-alpha・0=塗る)でクリップして縁色を塗り、その上に本文フィルを重ねる。
  CIFilter は `@synchronized([CIFilter class])` で直列化(既知のTDクラッシュ対策)
- 属性 `kCTStrokeWidthAttributeName` で「別の属性文字列」を作って2回レイアウトするのも
  グリフ不整合の元。**フィル用の CTFrame を1つ作って全パス(フィル/グラデマスク/縁)で使い回す**
- 可変フォントのウェイトは `kCTFontVariationAttribute` に `{'wght': 100..900}` →
  `CTFontCreateCopyWithAttributes`。SF は空文字列名でなく `CTFontCreateUIFontForLanguage` で作る
- 縦書きは 文字列属性 `kCTVerticalFormsAttributeName=true` + フレーム属性
  `kCTFrameProgressionAttributeName=RightToLeft` の両方が必要(縦用約物も自動で正しくなる)
- `CGBitmapContextCreate(NULL,...)` のバッファはゼロ初期化を当てにせず、透明背景でも
  `CGContextClearRect` してから描く
- **AppKitコールバック(NSFontPanelのchangeFont:等)からTDオブジェクトに触るな**。main thread でも
  TDの「THREAD CONFLICT」ダイアログが出る(TDのスレッドガードは自前のメインループ文脈を要求)。
  `createArgumentsTuple` も par 代入も全部NG。**コールバックでは C++ グローバルに値を保存するだけ**にし、
  cook(TDコンテキスト)内で PyRun によるパラメータ書き戻しを行う(CoreText TOP のフォントパネルで実証)。
  なお cook 内からの直接 par 代入は問題ない

## 専用スレッド + ランループ(CoreMIDI / Bonjour 系)

- **`CFRunLoopGetCurrent()` は所有権を持たない参照**。専用スレッドで取って持ち回り、
  デストラクタで `CFRunLoopStop()` する設計は**スレッドが先に抜けると use-after-free**になり、
  `__CFCheckCFInfoPACSignature`(EXC_BREAKPOINT / SIGTRAP)でプロセスごと落ちる。
  **CoreMIDI In/Out で実際に TD 終了のたびにクラッシュしていた**(macOS 26 実測)。
  正しくは `CFRetain` して保持し、`join()` した後に `CFRelease` する:
  ```objc
  // スレッド側
  myLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
  // デストラクタ
  CFRunLoopRef loop = myLoop.exchange(nullptr);
  if (loop) CFRunLoopStop(loop);
  if (myThread.joinable()) myThread.join();
  if (loop) CFRelease(loop);
  ```
- **終了時クラッシュは「次回起動時に『予期しない理由で終了しました』と出る」形で報告される**。
  推測せず `~/Library/Logs/DiagnosticReports/*.ips` を読む(1行目がヘッダJSON・残りが本体JSON。
  `triggered` のスレッドのフレームに落ちた op 名がそのまま出る)。
  修正の検証は**レポート数が増えないこと**で判定できる(画面操作不要)

## ウインドウを持つ TOP(MapKit 系)

- **cook が止まったことは cook 側からは検出できない**(execute が呼ばれない = そこから投げる
  `dispatch_async` も動かない)。コンテナの allowCooking オフやバイパスでウインドウだけ
  画面に残るのを防ぐには、**cook と独立した dispatch タイマー**で最終 cook 時刻を見張る
- **「表示した」と「画面に載っている」は別**。`orderBack:` でも on-screen になるので、
  可視状態のフラグは**ウインドウ生成時にも**立てる(reconfigure だけだと畳み損ねる)
- **ウインドウの検証は `CGWindowListCopyWindowInfo` で外部プロセスから列挙する**のが速くて確実。
  名前と位置(x,y,w,h)が取れるので、表示中 / 退避中(端に1pt)/ 完全に下ろした、を数値で区別できる。
  スクリーンショットや computer-use は要らない
