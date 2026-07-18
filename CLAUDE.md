# CLAUDE.md — TDAppleML 開発ガイド(AIエージェント向け)

このリポジトリで作業するAI/開発者が守るべきルールと、実装済みプラグインで得た知見の集約。
**ここに書かれたハマりどころは全て実際に踏んだもの**。同じ穴に落ちないこと。

> **作業引き継ぎルール(必読・毎回)**: 作業のたびに末尾の「作業ログ」に**何を・なぜ・
> 検証結果・次にやること**を追記する。新しく踏んだハマりどころは該当セクションにも反映する。
> 次のセッション/担当がこのファイルだけで作業を継続できる状態を保つこと。

## リポジトリの目的と方針

- Apple のオンデバイスML(Vision / SoundAnalysis / Speech / Translation / FoundationModels /
  Core ML)を **TouchDesigner のネイティブカスタムOP(.plugin)** として提供する。macOS専用
- **Windows+NVIDIA専用のTD標準OP(Body Track CHOP / Nvidia Background TOP等)のmacOS代替**を
  主眼とし、チャンネル形式は可能な限り既存標準OPと**完全互換**にする
  (VisionPose は実機 bclip サンプルと1chの狂いもなく一致させた)
- **ツールは汎用設計**。特定プロジェクト(ブース人数等)に縛らない。検出枠の定数は
  kMax=100・スライダー表示は10まで・既定値は控えめ、が家族の型
- モデルバイナリはコミットしない(`models/` は gitignore)。README に入手先を書く

## ディレクトリ構成と命名

```
<PluginName>/            例: VisionPose, ImageGen, SpeechText
  <PluginName><Family>.mm   ObjC++ 本体(CHOP/TOP/DAT)
  build.sh                  ビルドスクリプト(→ build/<Name>.plugin)
  README.md                 仕様・実測・注意(下記「ドキュメント規約」)
  helper/                   Swift専用APIを使う場合のみ(後述)
common/build_plugin.sh   単純なObjC++単体プラグイン用の共通ビルド
```

- opType: **先頭大文字1字+以降は小文字と数字のみ**(例 `Visionpose3d`)。
- **opIcon は英字のみ3文字**。数字を入れると**TD起動時の名前検証で弾かれ起動エラー**になる
  (実例: "VP3"→NG, "VPD"→OK)
- パラメータ名も先頭大文字+小文字数字(例 `Maxbodies`)。**UIラベル・メニューラベルは
  英語のみ**(日本語はTDのUIで文字化けする)。ソースコメント・READMEの日本語はOK

## ビルド

- 前提: Xcode(clang++/swiftc)+ TouchDesigner.app(C++ SDKヘッダを流用)
- SDKヘッダの場所: `/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/`
  配下の `CHOP/` `CPUMemoryTOP/`(TOP用) `DAT/`。common/build_plugin.sh は `TD_SDK` 環境変数で切替
- 各プラグインは `./build.sh` 一発。ad-hoc署名(`codesign -s -`)まで行う
- 配布/常用は `~/Library/Application Support/Derivative/TouchDesigner099/Plugins/` へコピー
  → TD再起動でカスタムOPとして登録される

### Swift専用APIのラップ(ヘルパdylib方式)

SpeechAnalyzer / FoundationModels / Translation / ml-stable-diffusion / ImageCreator は
Swift専用API。**ObjC++から直接呼べないので、helper/ の Swift を dylib 化して C ABI で繋ぐ**:

- C関数プレフィックスをプラグインごとに分ける: `sd_`/`pg_`(ImageGen) `fm_`(FoundationModel)
  `tr_`(Translate) `sp_`(SpeechText)
- ヘルパは `@_cdecl` でエクスポート、ハンドルは `Unmanaged.passRetained().toOpaque()`
- 状態の受け渡しは **poll方式のJSON**(status/busy/…)+必要ならバイト列コピー関数
- 依存が単純なら swiftc 直(-emit-library)、SPMパッケージ依存(ml-stable-diffusion)なら
  helper/ を Swift Package にして `swift build -c release`
- dylib は `.plugin/Contents/Frameworks/` に同梱し `-rpath @loader_path/../Frameworks`
- 古いOS向けには `@available` ガード+status文字列で理由を返す(クラッシュさせない)

## 実装の型(全プラグイン共通アーキテクチャ)

1. **推論はワーカースレッドで非同期**。cook(execute)は絶対にブロックしない。
   結果は1〜2フレーム遅れで最新値を出力する
2. TOP入力は `inputs->getParTOP()/getInputTOP()` → `downloadTexture()`。
   `getData()` はブロックするので**ワーカー側で呼ぶ**。busyフラグで多重投入を防ぐ
3. **TOPダウンロードは BGRA8Fixed + `verticalFlip=true` 必須**
   (TDのテクスチャはGL系bottom-up。フリップしないとVisionが検出0になる)。
   `Flip` トグル(既定On)として必ず露出する
4. TOP出力(CPUMem)は Vision系出力(top-down)を**行反転してアップロード**
5. 診断用に Info CHOP チャンネル(`executes / submits / analyzes` 等)を必ず出す。
   `analyzes` が `executes` に追従していればフレーム落ちなし、という読み方
6. `cookEveryFrameIfAsked = true`。**出力をどこかで使っていないとcookされない**
   (音声/翻訳系は特に「音が流れない」「翻訳が進まない」に見える)。
   テスト時は chopexecuteDAT / datexecuteDAT で監視して毎フレームcookさせる
7. 複数検出のスロット出力は `body{i}/`・`hand{i}/`・`face{i}/`(1始まり)+`:valid`。
   並びは左→右ソート(VisionPoseのみ最近傍マッチの永続trackingid)

## ハマりどころ集(必読)

### TD本体の挙動
- **TDは同一パスの .plugin バイナリと依存dylibをプロセス内でキャッシュする**。
  リビルドしてもreloadで古いコードが動き続ける。開発反復は:
  ① dylib名をビルド毎に変える(build.shが `lib*_<epoch>.dylib` で自動化済みのものあり)
  ② .plugin をバージョン付きパス(/tmp等)にコピーしてロード
  ③ 確実なのはTD再起動
- cplusplus系ノードは **plugin設定直後にカスタムパラメータが未生成**のことがある
  → `reinitpulse` をパルスするか1フレーム待つ
- TDタイムライン停止(`root.time.play=False`)で frame系コールバックは全停止する
- Info DATの1行目は自作プラグインでは(ヘッダではなく)データ行にもできる。行数指定に注意

### Vision / 画像系
- **VNTrackObjectRequest は Revision1 を明示せよ**。既定の Revision2 は macOS 26 実測で
  "Internal error: unexpected tracked object bounding box size" を返して一切追跡しない
  (bboxサイズを変えても無駄)。Revision1 なら動く。無地単色の被写体はテンプレート型の
  限界で bbox が膨張しながら漂流する(実写テクスチャなら誤差 0.002uv 級で追従)
- **generateMaskedImageOfInstances(VisionSubject の Cutout)は IOSurface 非対応の
  CVPixelBuffer(CreateWithBytes ラップ)だと nil を返す**。CVPixelBufferCreate
  (kCVPixelBufferIOSurfacePropertiesKey 付き)+行コピーで渡す。マスク系リクエストは
  生ラップでも通るため気づきにくい
- 静止画入力では totalCooks が変わらず再解析されない。**処理系パラメータ(Mode等)の
  変更検知で myLastCookSeen=-1 にして再投入**する型を全TOPに入れてある
- Vision の座標は **0〜1・左下原点**。TDのuv系と同じなので無変換で整合
- Body Track CHOP互換仕様の出典: 実機出力の bclip(`assets/`があるなら参照)と
  TD の `libCHOP.dylib` の strings(34キーポイント名の正順)。互換を名乗るなら
  **チャンネル名と順序の完全一致をテーブル比較で検証**すること
- VNGeneratePersonInstanceMask は **API上限4人**。VNDetectHumanBodyPose3D は**1人固定**・
  初回モデルロード約17秒・定常0.5秒(リアルタイム不可、と明記して出す)
- 顔・手は被写体が小さいと検出不安定(引きの全身5人はほぼ無理)。寄り画角かCropで拡大

### 生成系(ImageGen)
- ml-stable-diffusion の CFG式は `neg + g×(pos−neg)`。**Turbo系のCFG無効は Guidance=1.0**
  (0にするとプロンプト無視になる)。Turboは Steps=1〜2
- **ANE初回コンパイルは長い**(SD2.1 約2分・SDXL 10分超)。複数モデルの同時ロードは
  ANECompilerService で直列化してさらに遅くなる。status="loading model" は故障ではない。
  2回目以降はキャッシュで速い
- Image Playground(ImageCreator)は**人物をテキストのみから生成できない**
  (顔ソース画像必須のエラーになる)。Steps/Seed/img2img等も無効。スタイル3種のみ

### VideoToolbox / MetalFX(FrameInterp・Upscale)
- **VTFrameProcessor 系の対応ピクセル形式は 64RGBAHalf('RGhA')のみ**(FRC/MotionBlur/
  SuperRes 全て・実測)。TD の RGBA16Float ダウンロード/アップロードと直結すれば無変換
- ピクセルバッファは config の source/destinationPixelBufferAttributes から
  CVPixelBufferPool を作って確保する(自前 Create だと属性不一致で失敗しうる)
- **VTSuperResolutionScaler の対応倍率はハード依存で固定**(M2 実測 4x のみ)。
  supportedScaleFactors にない倍率で init すると nil。モデルは
  configurationModelStatus=0 なら downloadConfigurationModelWithCompletionHandler で取得
  (OS が既に持っていることもある)。入力は Video タイプで縦1080まで
- MetalFX Spatial は Shared ストレージのテクスチャで OK(Apple Silicon)。
  outputTexture の usage は scaler.outputTextureUsage を必ず含める

### 音声・言語系
- **旧SFSpeechRecognizerは使うな**: TouchDesigner の Info.plist に
  NSSpeechRecognitionUsageDescription が無く TCC で詰む。
  新 **SpeechAnalyzer/SpeechTranscriber(macOS 26+)** はTCC不要・完全オンデバイス
- **TranslationSession は SwiftUI専用**(公開init無し)。ほぼ不可視の
  **2x2px・alpha 0.01・画面内**のウインドウ+NSHostingView+translationTaskクロージャ内で
  キュー常駐、が動くワークアラウンド。**完全画面外や alpha 0.0 だと task が発火しない**
- 言語モデルの初回ダウンロードは数分かかる(ja→en実測約5分)。statusで見せる
- FoundationModels は端末で **Apple Intelligence が有効**でないと unavailable。
  `SystemLanguageModel.default.availability` で理由を分岐して status に出す

### Git / リポジトリ
- 巨大ファイル厳禁: `models/`(数GB)・`*.pt`・ビルド産物は gitignore 済み。
  **gitignoreの行内コメントは無効**(パターンが壊れる)。コメントは前の行に
- 5GB級を誤ってgit addするとハングする。中断後は `.git/objects/pack/tmp_pack_*` を掃除
- コミットメッセージは日本語で「何を・なぜ」。実測値があれば入れる

## 検証の作法

- TouchDesigner MCP(execute_python_script / get_td_node_errors / **get_top_image**)で
  実データ検証まで行う。TOPは get_top_image で**視認**、CHOPは値をevalして妥当性
  (例: 頭y≈0.85・足y≈0.24)、DATはテーブル内容を読む
- 実測値(fps・生成秒数・解像度)は必ずREADMEに書く。M2での値を基準とする
- カメラ不要の映像テストは `dummy_camera.mp4`(5人・5ゾーン分散)級の素材をループ再生。
  音声テストは `say -v Kyoko` で生成、音楽はTD同梱サンプル

## ドキュメント規約

- 各プラグインの README.md: 概要(何の代替/何ができる)→ 実測値 → 出力仕様(チャンネル/
  テーブルの表)→ パラメータ表 → 注意(制約・ハマりどころ)→ ビルド
- ルート README.md のプラグイン一覧表を必ず更新(1行サマリ+実測+状態)
- APIの制約で挙動が直感に反する箇所(Turbo Guidance=1.0 等)は**太字で明記**

## 命名の先例

| OP | opType | 由来 |
|---|---|---|
| Vision Pose / Pose3D / Hand / Face / Segment / Saliency / Text | Visionpose 等 | Visionフレームワーク+機能 |
| Sound Class | Soundclass | SoundAnalysis |
| Speech Text | Speechtext | SpeechAnalyzer |
| Foundation Model | Foundationmodel | **フレームワーク名**(他LLM統合と衝突させないため汎用名"LLM"は避けた) |
| Translate | Translate | Translation |
| Image Gen | Imagegen | **汎用名**(SD以外のバックエンド追加前提。Backendメニューで切替) |

## 作業引き継ぎログ

### 2026-07-19 TouchDesigner MCP疎通確認

- TouchDesigner MCP経由でTD内Pythonを実行し、双方向通信が正常であることを確認
- TDバージョン: `099`
- 開いているプロジェクトのフォルダ: `/Users/murata/Claude/Projects/TDAppleML`
- タイムライン: 再生中
- `/project1` のOP一覧取得にも成功（`Foundationmodel1`、`Upscale1`、`td_mcp_server` 等）
- リポジトリやTDプロジェクトへの変更は行っていない（このログ追記のみ）

### 2026-07-19 次期プラグイン候補の調査

- ルートREADMEと既存18プラグインを棚卸しし、Apple公式Vision APIの現行ドキュメントを確認
- 推奨優先順位: 1. VisionContours SOP、2. VisionAnimalPose CHOP、3. VisionClassify DAT、
  4. VisionBarcode DAT、5. VisionTrajectory CHOP、6. CoreML CHOP、7. VisionRect CHOP
- 最優先の理由: VisionContoursは既存群にないSOP出力で、映像の輪郭をTDジオメトリとして
  直接扱えるため用途の広がりが最大。`VNDetectContoursRequest`はObjC++から直接利用可能
- VisionTrajectoryは放物運動する小物体向けのAPIであり、一般的な任意物体追跡としては
  VisionTrackの代替にならない点に注意
- 今回は調査とこのログ追記のみ。実装は未着手

### 2026-07-19 VisionContours SOP実装

- `VNDetectContoursRequest`を使う非同期SOPを新規実装
- 輪郭ごとに閉じたLine primitiveを出力し、`contourid / parentid / depth / closed`属性を付与
- 点数下限・輪郭数上限・輪郭ごとの点数上限・RDP簡略化・Vision内部解析解像度をパラメータ化
- `VisionContours/build.sh`でビルド成功。SOP SDKヘッダ由来の`offsetof`警告18件のみ
- TouchDesigner MCP実測: 1252x736動画入力、Maxcontours=10、Maxpoints=128で
  10 primitive / 約300〜400 pointsを継続出力。エラー・警告なし
- テスト用TDノードは検証後に削除。次はVisionAnimalPose CHOP

### 2026-07-19 VisionAnimalPose CHOP実装

- macOS 14+の`VNDetectAnimalBodyPoseRequest`を使う非同期CHOPを新規実装
- Apple定義の25関節を固定順で`animal{i}/{joint}:u,v,confidence`出力
- 信頼度を満たす関節からbboxを算出し、複数匹を左→右ソート。最大100スロット
- ビルド成功。TouchDesigner MCPでMaxanimals=4時の320ch、全チャンネル名、1sample、
  エラー・警告なしを確認。テスト映像に犬猫がいないため検出値の実測は未実施
- テスト用TDノードは削除。次はVisionClassify DAT

### 2026-07-19 VisionClassify DAT実装

- `VNClassifyImageRequest`を使うモデル不要の非同期画像分類DATを新規実装
- `rank / identifier / confidence`を信頼度順で出力。Top Results最大100、最低信頼度対応
- ビルド成功。TouchDesigner MCP実測で1252x736テスト動画から10分類を出力
  （上位: people 0.572、adult 0.570、material 0.460）。エラー・警告なし
- テスト用TDノードは削除。次はVisionBarcode DAT

### 2026-07-19 VisionBarcode DAT実装

- `VNDetectBarcodesRequest`を使う非同期DATを新規実装
- symbology/payload/confidence/bbox/四隅16列を左→右順で出力。最大100コード
- ビルド成功。Core Imageで生成した420x420 QRをTDへ入力して実測検証
- `VNBarcodeSymbologyQR`、payload=`TDAppleML VisionBarcode test`、confidence=1.0、
  bboxと四隅を正しく取得。エラー・警告なし
- 生成した一時PNGとTDテストノードは削除。次はVisionTrajectory CHOP

### 2026-07-19 VisionTrajectory CHOP実装

- `VNDetectTrajectoriesRequest` + `VNSequenceRequestHandler`のstateful非同期CHOPを新規実装
- CVPixelBufferからtimestamp付きCMSampleBufferを作り、連続フレームとしてVisionへ投入
- 実測点/投影点、`y=a*x^2+b*x+c`、平均半径、最大100軌跡、Resetに対応
- ビルド成功。TouchDesigner MCPで既定104ch（4軌跡×26ch）、連続動画cook、
  エラー・警告なしを確認。テスト動画は放物体素材ではないためvalid実測は未実施
- テスト用TDノードは削除。次はCoreML CHOP

### 2026-07-19 CoreML CHOP実装

- 既存CoreML TOPのモデルコンパイルキャッシュ・計算ユニット・Vision画像入力を流用し、
  `MLMultiArray`を`valid/count/value0...`へフラット化する汎用CHOPを新規実装
- Output Feature Name、元shape/feature/全要素数のInfo DAT、最大65536値に対応
- ビルド成功。TDでDepth Anything V2をロードし、18ch（Maxvalues=16）を維持したまま
  画像出力モデルを`valid=0`+Warningとして扱うことを確認。エラーなし
- リポジトリ内に画像入力→MultiArray出力モデルがないため、実値の推論検証は未実施
- TD同一パスキャッシュ回避用の一時pluginとテストノードは削除。次はVisionRect CHOP

### 2026-07-19 VisionRect CHOP実装

- `VNDetectRectanglesRequest` Revision1を使う非同期CHOPを新規実装
- 最大100矩形のvalid/confidence/bbox/四隅14chを左→右順で出力
- aspect比、最小サイズ、信頼度、直角許容角をパラメータ化
- ビルド成功。TouchDesigner MCP実測で1252x736動画からconfidence=1.0の矩形を検出し、
  bbox=`0.1650, 0.3463, 0.0501, 0.2311`と四隅を出力。エラー・警告なし
- テスト用TDノードは削除。指定された7プラグインの個別実装が完了

### 2026-07-19 新規7プラグイン最終検証

- VisionContours / VisionAnimalPose / VisionClassify / VisionBarcode / VisionTrajectory /
  CoreMLCHOP / VisionRectを全て再ビルドし、ad-hoc署名を含め成功
- コンパイラ出力はTD SDKヘッダ由来の`offsetof`警告のみ。新規ソース固有の警告・エラーなし
- `git diff --check`成功。opTypeは先頭大文字+以降小文字、opIconは英字3文字を全件確認
- ルートREADME一覧、各README、CoreML TOPからCoreML CHOPへの導線を更新
- TouchDesigner `/project1` に検証用`_codex_*`ノードが残っていないことをMCPで確認
- 未完の実データ検証: VisionAnimalPose（犬猫素材なし）、VisionTrajectory（放物体素材なし）、
  CoreMLCHOP（画像入力→MultiArray出力モデルなし）。ビルド・ロード・出力構造は検証済み

### 2026-07-19 全作業ツリーのGit公開

- ユーザー指示により、今回の新規プラグインに限らず、作業ツリーに存在する全変更
  （削除済みファイル・未追跡ファイルを含む）を1コミットとしてpushする方針
- `Assets/test_video_2.mp4`（約183MB）はGitHub通常Gitの100MB制限を超えるため、
  ユーザーの「LFSは使わない」指示に従い、ローカルに残して今回のコミット対象から除外
- `codex/publish-all-changes`でコミット・push完了（最終commit: `b811ade`）。除外動画のみ
  未追跡でローカルに残る

### 2026-07-19 次期プラグイン候補の調査

- Core Imageの汎用色補正・ブラー・エッジ処理はTouchDesigner標準TOPと重なりやすいため、
  Vision出力と組み合わせて自動化できる機能を優先候補とした
- 最優先は`VisionKeystone TOP`。既存`VisionRect CHOP`の四隅を
  `CIPerspectiveCorrection`または`CIKeystoneCorrectionCombined`へ渡し、紙面・
  スクリーン・投影面を自動で正対補正する。`TOP -> VisionRect -> TOP`の一貫した
  ワークフローになり、既存群との相乗効果が最も大きい
- 次点は、Vision Feature Printによる`VisionSimilarity CHOP`、水平角検出による
  `VisionHorizon CHOP`、マスク入力で背景だけを可変ぼかしする`VisionBokeh TOP`、
  QR/Code128等を生成する`CoreImageCode TOP`。画像美的スコア出力も候補だが、
  演出用途の汎用性では上記より後順位

### 2026-07-19 音声・サウンド系の次期候補調査

- 既存`SoundClass CHOP`はSoundAnalysis組込み分類（300種類以上）と独自Core ML音響モデルを
  すでに扱うため、分類器の重複実装は優先しない
- 最優先候補は`SoundFeatures CHOP`。Audio CHOPからRMS/peak、周波数帯エネルギー、
  spectral centroid/flux、onset/beat、推定tempoを一貫した低遅延CHOPとして出す
- 次点は新Speech APIの`SpeechDetector`をSwift helperで包む`VoiceActivity CHOP`。
  `speaking / onset / offset / confidence`を出し、SpeechTextの文字起こし開始・終了、
  映像切替、照明制御に直接使える
- 音源分離・自動ミックスはApple標準のオンデバイスAPIだけでは汎用実装の基盤が弱いため、
  現時点では優先外。空間音響はAVAudioEngineで可能だが、TouchDesigner標準の音声経路との
  接続・出力デバイス所有が複雑なため後順位

### 2026-07-19 Appleフレームワーク横断の候補カタログ調査

- macOS版TouchDesignerのネイティブpluginとして有効な範囲を、Vision/Core Image/
  AVFoundation/ScreenCaptureKit/Metal Performance Shaders/Accelerate/Speech/
  NaturalLanguage/WeatherKit/MapKit/Core Location/MultipeerConnectivityまで横断調査
- 最優先候補は`VisionKeystone TOP`、`SoundFeatures CHOP`、`ScreenCapture TOP`。
  既存pluginと相乗効果があり、TD標準OPとの差別化も明確
- `ScreenCapture TOP`はScreenCaptureKitでディスプレイ・アプリ・任意ウインドウと同時に
  システム音声を取得できる。画面収録権限と選択UIを要する
- `MPSAnalyze TOP/CHOP`（histogram/平均色/統計）、`ImageAutoEnhance TOP`、
  `VisionSimilarity CHOP`、`VisionHorizon CHOP`、`VisionBokeh TOP`、
  `CoreImageCode TOP`を映像系の有望候補として整理
- 文章・データ入力向けには`TextAnalyze DAT`（言語判定・固有表現・品詞・埋め込み）、
  外部演出データには`Weather CHOP/DAT`、`MapSnapshot TOP`、`Location CHOP`、
  `Multipeer DAT/CHOP`を候補化。ただしそれぞれ権限・Developer Program・利用規約・
  ローカルネットワーク設定を伴うため優先度は下げる
- iOS/visionOS中心でmacOS版TouchDesignerに直接載せにくいARKit、RoomPlan、
  Nearby Interaction、HealthKit、Core Hapticsは今回の実装候補から除外

### 2026-07-19 VisionKeystone TOP実装

- `CIPerspectiveCorrection`を使う非同期CPUMem TOPを新規実装
- 既存VisionRect CHOPの`rect{i}/tl:u`等8chを直接参照でき、手動四隅にも対応
- 自動解像度または固定出力解像度、Flip既定On、Info CHOP診断を実装
- Core Image / Core Graphicsをリンクし、ad-hoc署名までビルド成功

### 2026-07-19 SoundFeatures CHOP実装

- Accelerate/vDSPのHann窓+FFTをワーカースレッドで実行する非同期CHOPを新規実装
- RMS/peak/dB/ZCR/centroid/rolloff/spectral flux/onset/beat/BPM、bass/mid/high、
  対数16帯域を固定29ch・1sampleで出力
- FFTサイズとonset閾値、Info CHOP診断を実装し、ad-hoc署名までビルド成功

### 2026-07-19 ScreenCapture TOP実装

- ScreenCaptureKitでdisplay/windowを選択してBGRA8 TOPへ非同期出力するpluginを新規実装
- source index、ネイティブ/固定解像度、1〜120fps、カーソル表示、Restartに対応
- callback受信フレームを最新値保持し、画面収録権限/APIエラーをWarningへ出力
- ScreenCaptureKit/CoreMedia/CoreVideoをリンクし、ad-hoc署名までビルド成功

### 2026-07-19 VisionSimilarity CHOP実装

- `VNGenerateImageFeaturePrintRequest`で2つのTOPを非同期比較するCHOPを新規実装
- `valid / distance / similarity / match`を出力し、distance閾値をパラメータ化
- similarityは演出制御用に`exp(-distance/10)`へ変換、Vision固有distanceもそのまま保持
- Vision/CoreVideoをリンクし、ad-hoc署名までビルド成功

### 2026-07-19 VoiceActivity CHOP実装

- macOS 26のSwift専用`SpeechDetector`をhelper dylib+C ABIで包むCHOPを新規実装
- `speaking / onset / offset / start / end / duration`を出力し、感度3段階に対応
- Audio CHOPの任意sample rateをSpeechAnalyzer推奨形式へ変換してAsyncStreamへ投入
- macOS 14 targetの`@available`ガード、Info DAT status、同梱dylibのrpathを実装し、
  Swift 6のNSLock async-context警告（現言語モードではwarning）を除きビルド・署名成功

### 2026-07-19 VisionBokeh TOP実装

- Core Image `CIMaskedVariableBlur`を使う2入力非同期CPUMem TOPを新規実装
- 入力0=画像、入力1=マスク。VisionSubject等の白い被写体マスクを想定し、背景ぼかし用の
  mask反転を既定Onに設定。異解像度マスクの自動スケールにも対応
- radius 0〜100、Flip既定On、Info CHOP診断を実装し、ビルド・署名成功

### 2026-07-19 Core Image同時実行クラッシュ修正

- TD実測でVisionKeystoneとVisionBokehを別pluginパスから同時初期化した際、
  `CIFilter setValue:forKey:`内部のKVC競合でEXC_BAD_ACCESSを確認
- 両pluginのCore Image処理区間を`@synchronized([CIFilter class])`でプロセス横断直列化
- Core Image出力の行反転を追加し、TD上で正立画像を`get_top_image`相当のsnapshot確認
- TD再起動後に両TOPを同時40cookし、640x426出力・エラー/警告なし・再クラッシュなしを確認

### 2026-07-19 MPSAnalyze CHOP実装

- `MPSImageHistogram`でRGBA 256binをGPU集計し、16bin×4chへ正規化するCHOPを新規実装
- RGBA平均、Rec.709輝度の平均/標準偏差/最小/最大、dark/midtone/bright比率を加え、
  合計76ch・1sampleで出力。GPU完了待ちはワーカースレッドで行いcookは非ブロッキング
- M2実測で640x426画像からmean_luma=0.4895、std_luma=0.2976、
  dark/midtone/bright=0.2589/0.5129/0.2282。ビルド・署名成功

### 2026-07-19 新規7プラグイン最終検証

- VisionKeystone / SoundFeatures / ScreenCapture / VisionSimilarity / VoiceActivity /
  VisionBokeh / MPSAnalyzeを全件再ビルドし、ad-hoc署名と`codesign --verify --deep --strict`成功
- TD MCP実測: Keystone/Bokehは640x426正立出力、Similarityは同一画像distance=0・
  similarity=1、MPSAnalyzeはvalid=1・76ch、ScreenCaptureは1710x1112を取得
- SoundFeaturesは44.1kHz・440Hz正弦波でRMS=0.707、centroid=440.0Hzを確認
- VoiceActivityは6chロードと非音声入力speaking=0を確認。実発話によるonset/offsetは未検証
- ScreenCaptureは再起動前にTCC拒否Warning、再起動後は権限が反映され実画面取得成功
- 静止画の処理パラメータ変更で再投入するsignature検知をKeystone/Bokeh/Similarity/MPSへ追加
- `git diff --check`、opType規約、英字3文字opIcon、全READMEとルート一覧更新を確認
- TD `/project1` の`_codex_*`検証ノードを全て削除
