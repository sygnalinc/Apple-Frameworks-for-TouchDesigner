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
- **Gaussian Splat 専用のロードAPIは存在しない**(SDKに "splat"/"gaussian" シンボル無し)。
  splat は USD/USDZ に含めて `Entity(contentsOf:)` で読み込み、RealityKit が内部描画する。
  つまり「splat専用TOP」ではなく「RealityKitが読めるUSDシーンを描くTOP」になる(macOS 26+ で splat 対応)
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
