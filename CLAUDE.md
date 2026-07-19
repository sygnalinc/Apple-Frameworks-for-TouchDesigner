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
3. **TOPダウンロードは BGRA8Fixed + `verticalFlip=true` 必須 — ただし Vision/ML 意味処理系のみ**
   (TDのテクスチャはGL系bottom-up。フリップしないとVisionが検出0になる)。
   `Flip` トグル(既定On)として露出する。**向きに依存しない処理(Upscale/FrameInterp の
   幾何変換・補間系)は flip 自体を持たない**(verticalFlip=false 固定・出力もそのまま。
   片側だけ flip すると出力が上下逆になる事故の元)
4. TOP出力(CPUMem)は Vision系出力(top-down)を**行反転してアップロード**
   (ダウンロード flip と出力再反転は必ず対で行う)
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

### 2026-07-19 新規7プラグインのGit公開

- 今回の7プラグイン、各README、ルートREADME、引き継ぎ記録を
  `codex/publish-all-changes`へコミットしてoriginへpush
- LFSは使用せず、183MBの`Assets/test_video_2.mp4`は引き続きローカルのみ
- TDクラッシュ由来の`CrashAutoSave.sample.toe`と更新された`sample.toe`、既存の
  `sample.py`削除は混在差分としてコミット対象外に保持

### 2026-07-19 次期プラグイン候補（7件実装後）

- 最優先は`SystemAudio CHOP`。ScreenCaptureKitのaudio streamをAudio CHOPとして出し、
  新規ScreenCapture TOPと組み合わせてアプリ/画面映像とシステム音を同時利用できるようにする
- 次点は`VisionHorizon CHOP`、`CoreImageCode TOP`、`ImageAutoEnhance TOP`。
  小〜中規模でApple標準APIの価値が明確かつ、既存Vision/Core Image群と接続しやすい
- その後は`SpeechSynth CHOP`、`TextAnalyze DAT`、`VisionAesthetics CHOP`、
  `ImageMetadata DAT`を推奨。オンデバイス音声合成、NLP、画像選別、EXIF/GPSを補完する
- 外部入力系の`GameController CHOP`、`CoreMIDI2 CHOP`、外部データ系の
  `Weather CHOP/DAT`、`MapSnapshot TOP`は有用だが、TD標準OPとの重複や権限・利用条件が
  増えるため後順位

### 2026-07-19 次期5プラグイン実装

- `SystemAudio CHOP`をScreenCaptureKitのaudio streamで実装。display index、48 kHz stereo、
  block size、TouchDesigner自身の音声除外、Restart、Info CHOP診断に対応
- `VisionHorizon CHOP`を`VNDetectHorizonRequest`で実装。valid/angle/angledeg、
  affine transformのa〜d、confidenceを非同期出力
- `CoreImageCode TOP`をCore Image generatorで実装。QR/Aztec/PDF417/Code 128、
  整数拡大、中央配置、quiet zone、QR error correctionに対応
- `ImageAutoEnhance TOP`を`autoAdjustmentFiltersWithOptions`で実装。red-eye/crop/levelを
  選択でき、実際に適用したfilter名をInfo DATへ出力
- `SpeechSynth CHOP`を`AVSpeechSynthesizer.writeUtterance`で実装。Text/Voice/Rate/Pitch/
  Volume、Speak/Stop、文字変更trigger、PCM stereo出力に対応
- 5件ともcookをブロックしないcallback/worker構成、Info CHOP診断、個別README、
  ルートREADME一覧を追加。build bundleのad-hoc署名検証に成功
- TD実測: 5件すべてロード・パラメータ生成・エラーなし。CoreImageCodeは512x512 QRを視認、
  ImageAutoEnhanceは640x360正立・2 filters・約32.1ms、VisionHorizonは水平構造のない
  gradientで解析約37.7ms・valid=0、SpeechSynthは英語1 utteranceを22.05 kHz・181 buffers生成
- SystemAudioは48 kHz stereo 1024 samplesとstream running=1まで確認。テスト音再生中の
  callback/peak捕捉は未完了のため、実音声の最終確認が残る
- TD検証ノード削除時にMCP接続断を確認。SpeechSynthのbuffer callbackがinstance破棄後に
  ownerへ触れないようshared atomic生存tokenを追加。修正版は再ビルド・署名済みだが、
  TouchDesigner再起動が必要なため破棄テストの再確認は未実施

### 2026-07-19 次期5プラグインをCustom OPへ登録

- SystemAudioCHOP / VisionHorizonCHOP / CoreImageCodeTOP / ImageAutoEnhanceTOP /
  SpeechSynthCHOPの完成bundleを`~/Library/Application Support/Derivative/
  TouchDesigner099/Plugins/`へ配置
- 配置先に既存の同名bundleがないことを確認して新規登録し、全5件で実行binaryの存在と
  `codesign --verify --deep --strict`成功を確認
- TouchDesignerは起動時に常設Custom OPを走査するため、登録反映にはTD再起動が必要

### 2026-07-19 音楽生成ライブラリ調査

- Apple標準Frameworkにはtext-to-music専用の公開生成APIはない。AVAudioEngine /
  AVAudioSequencer / AVAudioUnitSamplerで合成・MIDI再生はできるが、作曲モデルは別途必要
- 完成音声生成候補はMeta AudioCraftのMusicGen/JASCO、Stability AIのStable Audio系、
  ライブ生成候補はMagenta RealTime。MusicGen weightはCC-BY-NC 4.0のため商用配布不可
- TD向け最優先案は`MusicSequence CHOP/DAT`。Foundation Modelsまたは小型Core MLモデルで
  note/chord/drumイベントを生成し、AVAudioSequencer/AVAudioUnitSamplerで鳴らす構成
- 高品質text-to-musicは`MusicGen CHOP`として別Python workerまたは専用helper processを使い、
  生成済みPCMをCHOPへstreamする案が現実的。巨大weightは従来どおりcommitしない

### 2026-07-19 Apple標準API作曲プラグイン実装

- `MusicCompose DAT`を新規実装。BPM/Bar/Key/Scale/Seed/Complexityからchords/bass/
  melody/drumsのMIDI event JSONを即時生成するAlgorithmモードを搭載
- Foundation Modelsモードは既存Swift helper方式を再利用し、厳密な同一JSON schemaを要求。
  Apple Intelligence利用不可、生成中、不正JSON時はAlgorithm結果を維持する
- `MusicSequence CHOP`を新規実装。Song JSON DATを読み、worker thread上のAVAudioEngine
  manual offline rendering + AVAudioUnitSamplerで44.1 kHz stereo PCMへ変換
- Play/Loop/Volume/Block Samples、SoundFont/DLS path、GM Program、Render/Restartに対応。
  初版は単一Samplerのため全track共通音色。track別Samplerは次版候補
- 両pluginともSDKビルドとad-hoc署名成功。TD MCPは直前の検証時に接続断しているため、
  TouchDesigner再起動後のJSON接続、PCM peak、破棄安全性の実機検証が残る
- 初回TD検証ではMusicComposeが毎frame cookされ、MusicSequenceがDAT更新と誤認して49回連続
  render。AVAudioEngine/Audio Unit teardown中にworkerでEXC_BAD_ACCESSとなった
- MusicComposeの`cookEveryFrameIfAsked`をAI busy中のみOnへ変更し、通常時のJSON totalCooksを
  安定化。TDをクリーン再起動して再検証し、213 events・16.5秒を約118ms、peak 0.374で出力
- 安定後はsubmits/renders=2のまま増加せず、検証ノードをinfo→sequence→composeの順で削除後も
  MCP応答・TDプロセスとも正常。`_codex_*`ノードを全削除済み
- 最終bundleを再ビルドして`codesign --verify --deep --strict`成功。MusicComposeDAT.pluginと
  MusicSequenceCHOP.pluginをTouchDesigner099の常設Pluginsディレクトリへ登録済み

### 2026-07-19 MusicCompose利用サンプル配置

- `sample.toe`の`/project1/MusicCompose_sample`へ独立base COMPを追加して保存
- 内部は`music_compose DAT -> music_sequence CHOP -> music_out -> audio_device_out`。
  README Text DATと両pluginのInfo CHOPも配置
- 既定例はuplifting electronic、120 BPM、8 bars、C minor、seed 7、complexity 0.6。
  206 events・16.5秒を約65.9msでrenderし、music_outの非ゼロPCMを確認
- Audio Device Outは不意な発音防止のためActive Off、Volume 0.35。ユーザーがActiveをOnにして試す
- サンプル配置中、AVAudioPCMBufferのconst pointer workaroundとして追加していたObjC categoryが
  Audio Device Out起動時のruntime method-cache競合を起こしEXC_BAD_ACCESS。categoryを完全撤去し、
  C++ `auto`でApple APIの戻り型を保持するよう修正。再ビルド・署名・常設bundle更新済み
- 修正版をクリーン再起動したTDで再検証し、Audio Device Out配置後もMCP応答、network map、
  全ノードerrors/warningsなしを確認

### 2026-07-19 MusicSequence音質修正

- ユーザー実聴で既定AVAudioUnitSampler出力が音楽ではなくノイズ状と判明。General MIDI bankを
  loadしていない単一Samplerへ全track/channelを密集させていたことが原因
- 既定rendererを追加音源不要のtrack別native synthへ置換。chords=soft pad、bass=低域倍音、
  melody=pluck、drums=kick/snare/hat専用合成、stereo pan、envelope、soft clipを実装
- AVAudioPCMBufferの型cast用ObjC categoryはAudio Device Out起動中にruntime method-cache競合を
  起こすことも再確認。旧AVAudioEngine rendererとcategoryを完全撤去
- TDを再起動して常設bundleからサンプルを再ロード。212 events・約19秒を約51ms、renders=1、
  errors/warningsなし。Audio Device OutをActive On・Volume 0.25にして`sample.toe`へ保存
- Audio Device Out稼働後もMCP network map取得成功、TDクラッシュなし。Soundbank/Programは
  将来backend互換の予約parameterとして残す

### 2026-07-19 MusicComposeサンプル再構築

- `sample.toe`の`/project1/MusicCompose_sample`を一度削除し、修正版track synth前提で再構築
- 左から`music_compose -> music_sequence -> music_out -> audio_device_out`の直線構成、上段に
  `00_README`、下段にcompose/sequenceのInfo CHOPを配置。色とnode commentも設定
- 既定値をAlgorithm、warm synthwave、112 BPM、8 bars、A minor、seed 42、complexity 0.48へ
  reset。以前のAI/rock band/ランダムseed状態は除去
- Audio Device OutはActive On、Volume 0.22。212 events・約17.5秒、render約99.4ms、
  PCM peak 0.161、全7node errors/warningsなしを確認して`sample.toe`へ保存
- network map再取得時もsubmits/renders=2のまま安定し、Audio Device Out動作中のMCP応答正常

### 2026-07-19 GeneralUser GS SoundFont適用

- ローカルにsf2/dlsがなかったため、公式GeneralUser-GS GitHubからv2.0.3の
  `GeneralUser-GS.sf2`（約31MB、SHA-256 `9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe`）を取得
- `models/GeneralUser-GS.sf2`へ配置。models/はgitignore対象で、LFSも使用せずcommitしない
- MusicSequenceへSoundFont backendを実装。AVAudioEngine manual offline renderingで4つの
  AVAudioUnitSamplerを使用し、chords=program 88、bass=38、melody=80、drums=percussion kit 0
- Soundbank空欄時は既存native track synthへfallback。SoundFont pathまたは各program変更を
  signature検知して自動再renderする
- TDを保存終了・再起動して常設bundleをreload。サンプルへSoundFont pathを設定し、
  212 events・約17.7秒を約1.86秒、peak 0.128、errors/warningsなしでrender
- `/project1/MusicCompose_sample/audiodevout1`をActive On・Volume 0.30、READMEをSoundFont割当に
  更新して`sample.toe`へ保存

### 2026-07-19 SoundFont版サンプル再構築

- `/project1/MusicCompose_sample`を再度削除し、GeneralUser GS backend専用サンプルとして再構築
- 直線配置は`music_compose -> music_sequence -> music_out -> audio_device_out`、READMEと
  compose/sequence Info CHOPを上下に配置。各nodeへSTEP commentと色を設定
- 既定曲はbright synthwave、110 BPM、8 bars、A minor、seed 42、complexity 0.5
- Soundbank=`models/GeneralUser-GS.sf2`、chords=88、bass=38、melody=80、drums=0を初期設定
- 212 events・約18.0秒、SoundFont render約874ms、非ゼロPCM、全7node errors/warningsなし
- render完了後にAudio Device OutをActive On・Volume 0.30として`sample.toe`へ保存

### 2026-07-19 CoreML TOP(汎用Core ML推論)実装

- 任意の`.mlpackage`/`.mlmodel`/`.mlmodelc`をロードし入力TOPに推論する汎用TOPを新規実装。
  SoundClassの独自Core MLモデル対応の設計思想を映像側へ拡張
- 出力を自動判別: Image(グレー/BGRA)→テクスチャ、MLMultiArray`[..,H,W]`/`[..,3,H,W]`→
  Mono32Float/RGBA32Float、分類→Info DAT上位10クラス。深度の生値対策にOutput Range
  (auto min-max/raw/manual)とInvert(Depth Anythingは近=大のdisparity系)を用意
- mlpackageのコンパイル結果を`~/Library/Caches/TDAppleML/`にキャッシュ(2回目以降高速)
- **実測(M2)**: Apple公式Depth Anything V2 Small F16(48MB・`models/`に配置・gitignore)、
  518x392、推論約33ms→約20fps。TD本体60fps維持。深度マップ・Invertを視認確認
- モデル入手先: https://huggingface.co/apple/coreml-depth-anything-v2-small
- 次にやること: YOLO等の物体検出(VNRecognizedObjectObservation→bbox)は現状未対応。
  SAM2は複数入力+プロンプトのため専用plugin化が要る

### 2026-07-19 Nvidia専用OP代替5プラグイン実装

指定された5件を新規実装。全て非同期worker+cook非ブロックの家族の型。

- **VisionFlow TOP**(`VNGenerateOpticalFlowRequest`): Optical Flow TOP(Nvidia)代替。
  RG32Floatで動きベクトル場。UV(既定・+v上向きに符号反転済み)/Pixels切替。
  720p Medium 約64ms→約15fps。実測フロー値が理論値と一致
- **VisionSubject TOP**(`VNGenerateForegroundInstanceMaskRequest`・macOS 14+):
  VisionSegment(人物限定)の汎用版。ソフトマスク/背景透過カットアウト/インスタンス分離。
  720p 約45ms。カットアウトを視認確認
- **VisionTrack CHOP**(`VNTrackObjectRequest`+`VNSequenceRequestHandler`): 任意物体追跡。
  Blob Track TOP代替に近い。valid/u/v/w/h/confidence。3〜5ms/frame。実写テクスチャで追従確認
- **FrameInterp TOP**(`VTFrameProcessor`・macOS 15.4+): MLフレーム補間/モーションブラー。
  720p 約67ms→約15fps。補間フレームを視認確認
- **Upscale TOP**(MetalFX Spatial / `VTSuperResolutionScaler`): Nvidia Upscaler TOP代替。
  MetalFX 2x=約16ms(リアルタイム)、VT SuperRes 4x(720p→5120x2880)約1.9s。両方動作確認
- 踏んだ地雷はハマりどころ集に反映済み: VNTrackObjectはRevision1明示必須(Revision2は
  macOS 26でbboxサイズエラー)、カットアウトはIOSurfaceバッファ必須、VTは64RGBAHalf専用、
  静止画入力はパラメータ変更検知で再投入。各README+ルート一覧+CLAUDE.md更新済み
- 5件とも`~/Library/.../Plugins/`へインストール済み(TD再起動で登録)

### 2026-07-19 Upscale TOP の Flip 既定をOffへ修正

- ユーザー指摘で再検証: Upscaleは**Flip=Onで出力が上下逆**、Off=ソースと同じ正立(実機視認)。
  Vision系はダウンロードflip+出力再反転で相殺するが、Upscale/FrameInterp/CoreMLは
  ダウンロードflipのみで出力を戻さないため、幾何変換のUpscaleではflip=1が余計な1回反転になる
- `Flip`の既定値を`1`→`0`に変更(理由コメント付き)。リビルド・インストール・
  新規ノードで既定0かつ正立出力を確認。READMEも「既定Off=正立」に修正
- 未対応(要相談): FrameInterp・CoreMLも同構造でflip時に上下逆になる(既定Onのまま)。
  揃えるなら両者もOffにする
  → 補足訂正: CoreMLは出力側で再反転する対称構造なので問題なし(Flip必要・既定Onが正しい)。
  FrameInterpのみUpscaleと同じ非対称構造だった(次エントリで解決)

### 2026-07-19 Upscale/FrameInterp から Flip パラメータを削除

- ユーザー指示「flip機能は必要なもの以外は削除して」を受け整理:
  **Flipが必要** = Vision/ML意味処理系(Vision全部・CoreML。正立画像でないと検出/推論が
  劣化し、出力側の再反転と対になっている) / **不要** = 向き非依存の Upscale・FrameInterp
- Upscale・FrameInterp から `Flip` パラメータと関連コードを削除。ダウンロードは
  `verticalFlip=false` 固定にし、入力の向きのまま処理して返す(理由コメント付き)
- リビルド・`~/Library/.../Plugins/` へインストール済み。TD実測: 両ノードとも
  Flipパラメータが消え、Upscale(2560x1440)・FrameInterp(1280x720)ともソースと同じ
  正立出力を視認確認。検証用一時コンテナは削除済み
- 実装の型3項を「Flipは Vision/ML意味処理系のみ・向き非依存系は持たない」に改訂
- 注意: 既にプロジェクトに置かれている Upscale ノード(例 `/project1/Upscale1`)は
  TD再起動で新バイナリに切り替わり、Flip par は自動的に消える

### 2026-07-19 CoreMLDetect DAT / TextAnalyze DAT / Denoise TOP / Upscale LLSRバックエンド実装

推奨候補1〜3をまとめて実装(ユーザー指示)。

- **CoreMLDetect DAT**: 検出系Core MLモデル(VNRecognizedObjectObservation)の汎用DAT。
  rank/label/confidence/u/v/w/h(bbox中心+サイズ・uv)をテーブル出力。
  コンパイルキャッシュはCoreML TOPと共有。実測(M2): YOLOv3Int8LUT(62MB・
  https://huggingface.co/apple/coreml-YOLOv3 → models/)で banana 0.994、
  単独38ms≈26fps。NMS込みエクスポートが対象(生テンソルYOLOは警告)
- **TextAnalyze DAT**: NaturalLanguageで感情(-1〜+1)・言語・固有表現(人名/地名/組織)・
  Reference Textとの文埋め込み類似度をkey/valueテーブル+Info CHOP出力。
  実測: 英文で sentiment+1.0、Tim Cook/Tokyo/Sonyを正抽出、similarity 0.33。
  感情スコアは日本語未対応(常に0)→Translate経由の英訳ワークアラウンドをREADMEに記載。
  実装時バグ: NLTagger は init 時に使う全スキームを渡す必要がある
  (TokenTypeを渡し忘れて語数が0になった)
- **Denoise TOP**(VTTemporalNoiseFilter・macOS 26+): **M2では isSupported=false で
  動作しない**(実測・maximumDimensions=0x0)。エラー表示のみのクリーンな非対応パスを確認。
  対応ハードでは動く実装だが実データ検証は未実施(ルートREADMEに「⚠ M2非対応」)
- **Upscale に VT Low Latency ML バックエンド追加**(VTLowLatencySuperResolutionScaler・
  macOS 26+): 2x固定・入力96〜960px。実測 640x360→1280x720 が定常21ms(単独時)で
  リアルタイム。**対応ピクセル形式は420v(YCbCr)のみ**で、当初64RGBAHalf前提で書いて
  出力がノイズになった → vImageでBGRA↔420v変換して解決
- 4件ともビルド・インストール済み。検証用一時コンテナは削除済み
- 次にやること: Denoiseの対応ハード実機検証、YOLOv8系NMS込みモデルの動作確認

### 新規ハマりどころ(上記実装で発見)

- **VTLowLatencySuperResolutionScaler の対応形式は 420v のみ**(他のVT系の64RGBAHalfと
  違う)。frameSupportedPixelFormats を必ず確認し、vImage(ITU-R 601 videoRange)で変換する
- **VTTemporalNoiseFilter は M2 非対応**(isSupported=false)。VT系は必ず isSupported と
  supportedScaleFactors/maximumDimensions をプローブしてから設計する
- **ANE系プラグインの同時実行は競合で数倍遅くなる**(実測: YOLO 38ms→262ms、
  LLSR 4ms→324ms)。重いML系を複数常時走らせる設計は避け、READMEに明記する
- **NLTagger は initWithTagSchemes に使う全スキームを列挙する**。列挙外のスキームで
  enumerate してもエラーにならず単に結果0件になる(気づきにくい)

### 2026-07-19 MusicCompose サンプルのノイズ感を再診断

- SoundFont出力をTDのAudio File Out CHOPで24-bit/44.1kHz WAVへ実録し解析。
  peak -5.22dB、RMS -20.98dBでクリップやサンプルレート不一致はなかった
- 原因はサンプル指定のGM Program 88/80（効果音寄りPad/鋭いLead）で、高域倍音が
  20kHz付近まで強く広がり「ノイズ」に聞こえやすい音色構成だった
- 既定とサンプルを Acoustic Grand Piano(0) / Acoustic Bass(32) / Flute(73) /
  Standard Drum Kit(0)へ変更。SoundFont使用時はまず明確な生楽器音で検証する

### 2026-07-19 MusicMIDI CHOP（外部DAW再生）実装

- MusicComposeのevent JSONをCore MIDI仮想ソース`TDAppleML Music`へリアルタイム送信
- chords/bass/melody/drumsを既定Channel 1/2/3/10へ分離。Note On/Off、MIDI Start/Stop、
  24 PPQN Clock、Loop、Restart、All Notes Off（Panic）を実装
- MIDI送信と再生スケジューリングは専用worker thread（1ms周期）。cookはJSON受け渡しと
  状態更新のみでブロックしない
- Info CHOPはexecutes/loads/events/playing/beat/bpm/midi_ready。Logic ProなどDAW側の
  Software Instrumentで音色・エフェクト・ミックスを担当する
- `./build.sh`成功、ad-hoc署名済み。仮想MIDI sourceはOP生成時にCoreMIDIへ登録される

### 2026-07-19 MusicMIDI 毎フレームcook確認

- TDタイムライン再生中、2秒間で`executes`/`total_cooks`が52455→52573（+118）へ増加。
  約59 cook/secで毎フレームcookされていることを実測確認
- `Play=True`、出力`playing=1`、`root.time.play=True`。LogicへのMIDI送信中もcook停止なし

### 2026-07-19 MusicEvents DAT実装（生成MIDIの可視化）

- MusicCompose JSONを演奏時刻順の表へ変換する`MusicEvents DAT`を追加
- 列はindex/bar/beat/position/track/channel/note/note_name/duration/velocity。
  MIDI番号だけでなくC4/A2等のノート名と小節位置を確認できる
- `sample.toe`へ`midi_events`を配置し、`music_compose`をSongに指定。実測208イベント、
  210行×10列、chords=1/bass=2/melody=3/drums=10を確認。エラー・警告なし
- ビルド・ad-hoc署名・Custom OPディレクトリへの登録済み

### 2026-07-19 MusicCompose パラメータ更新・AI競合修正

- Seed変更でJSON hashが`29c1d0212071`→`a2c015f74834`へ変わること自体は確認したが、
  Foundation Models生成中に設定を変えると古いAI応答が新しいAlgorithm fallbackを後から
  上書きする競合を発見
- 変更signatureへPromptとComposerを追加。全パラメータ変更で確実に自動再生成する
- AI生成中の変更は最新設定をpending保持し、旧応答はsignature不一致なら破棄。完了後に
  最新設定だけを再submitする。AI historyの同一結果を毎cook再適用する挙動も防止
- Algorithm生成時もInfo CHOPの`notes`を更新
- 新バイナリでPrompt変更、Seed変更のJSON hashがそれぞれ異なることを確認。
  ビルド・Custom OP登録済み。既存TDプロセスはplugin cacheのため再起動後に切替

### 2026-07-19 SAM2Segment / Shazam / Photogrammetry / VisionAesthetics / ImageMetadata 実装

推奨候補4件(小物2つ含む計5プラグイン)をまとめて実装(ユーザー指示)。

- **SAM2Segment TOP**: Apple公式 `coreml-sam2.1-tiny`(3モデル・計80MB・models/にDL済み)で
  点指定の任意物体マスク。実測(M2): エンコード390ms(フレーム変化時のみ)+デコード40ms
  (プロンプト変化時のみ)→静止画は点移動だけで25fps級。左端/中央のドラム缶を
  個別選択できることを視認(score 0.99/0.74)。出力はsigmoidソフトマスク Mono32Float 256x256
- **Shazam DAT**(Swiftヘルパ sh_): SHCustomCatalogによる完全オフライン照合。
  Reference Folderの音源からカタログ構築→Audio CHOPを照合し title/offset/skew を出力。
  実測: TD同梱mp3で matched=1・offset=29.06秒(曲内位置特定)
- **Photogrammetry SOP**(Swiftヘルパ ph_): PhotogrammetrySessionで写真→3Dメッシュ。
  OBJパース→SOP点+三角形出力。セッション起動・進捗・エラー報告・USDZ出力は検証済み。
  **実写真セットでのフルメッシュ検証は未実施**(撮影セットが無い)
- **VisionAesthetics CHOP**(macOS 15+): 美的スコア。実測 OilDrums score=0.381 utility=1
- **ImageMetadata DAT**(ImageIO): EXIF/GPS/IPTC key/valueテーブル。ファイルmtimeで自動再読込。
  TDサンプル画像はEXIFストリップ済みのため基本情報のみで検証(GPS十進変換は未実測)
- 5件ともビルド・`~/Library/.../Plugins/`インストール済み(TD再起動で登録)。
  検証用一時コンテナは削除済み
- 次にやること: Photogrammetryの実写真セット検証、SAM2+VisionTrackの連携デモ、
  ImageMetadataのEXIF/GPS付き実写真での確認

### 新規ハマりどころ(上記実装で発見)

- **SAM2(Apple Core ML版)のプロンプト座標は1024x1024ピクセル空間**。正規化0〜1を渡すと
  常に左上(壁など)が選択される。TD uv→ `x=u*1024, y=(1-v)*1024` に変換する
- **PhotogrammetrySession の modelFile 出力は USDZ のみ**(.obj指定は invalidOutput)。
  OBJが欲しい場合は一時USDZ→ModelIO(MDLAsset.export)で変換する
- **SOPプラグインは executeVBO() も実装必須**(純粋仮想。空実装でよい。忘れると
  abstract class エラー)
- ShazamKitのカスタムカタログ照合はエンタイトルメント不要・完全ローカル。
  Shazam公式カタログ照合はエンタイトルメントが要るため手を出さない

### 2026-07-19 整備3件(git公開・SAM2連携デモ・Photogrammetry実証)

- **git commit/push**: Claude Codeセッション分の8プラグイン+Upscale/FrameInterp改修+
  CLAUDE.mdを `codex/publish-all-changes` へコミット(e41cd76)・push完了。
  Codex作業中の Music* 系・巨大動画・CrashAutoSave は対象外のまま
- **SAM2+VisionTrack連携デモ**(`/project1/sam2_track_demo`・sample.toe保存済み):
  test_video_1(5人ダンス)で VisionTrack の u/v を式で SAM2 の Prompt Point に接続 →
  中央人物のフルカラー切り抜きを視認。組み立ての要点:
  ① マスクは正方形256x256なので Fit TOP は **fit=fill(stretch)** で入力アスペクトへ
  ② sigmoidソフトマスクは背景に中間値が残るので **Threshold TOP(0.5)** を挟む
  ③ Composite(multiply)は**出力formatをrgba8fixedに固定**(Mono32Float入力に
  引っ張られてモノクロ化する)
- **SAM2SegmentにMask Selectパラメータ追加**(largest=物体全体・既定 / score=部位)。
  スコア最高候補は「服だけ」等の部位を選びがちなため、面積最大候補で人物全体を選択。
  リビルド・インストール済み(**開いているTDセッションはパスキャッシュのため旧コード。
  TD再起動で有効化**)
- **Photogrammetry実写真検証完了**: Middlebury templeRing(47枚・640x480)で
  約1分(Preview)→ USDZ 450KB → OBJ変換 → SOP 1416点/2835三角形をレンダリング視認。
  データセットとメッシュを Assets/ に同梱、デモは `/project1/photogrammetry_demo`。
  ルートREADMEを「✅ 実装済み」へ更新
- 未コミット: この整備分(README更新・CLAUDE.md・SAM2のMaskselect・sample.toe)は
  次回コミットにまとめる

### 2026-07-19 Photogrammetry にテクスチャ対応を追加

- **ヘルパ**: 再構成完了時に usdz(実体はzip)から焼き込みテクスチャを `/usr/bin/unzip` で
  抽出し `<出力名>_tex0.png` に改名、`.mtl` の `map_Kd`(usdz内部参照)も書き換え。
  テクスチャパスは poll JSON の `texture` フィールドで返す
- **SOP**: OBJ の vt をパースし **UV付きで出力**(v/vt 分離は (v,vt) の組で点を分割して解決。
  templeRing 実測 1416点→1865点)。テクスチャパスは Info DAT `texture` 行で公開
- **実測**: templeRing 再構成→テクスチャ抽出(370KB png)→ Phong MAT Color Map で
  **テクスチャ付きメッシュのレンダリングを視認**。デモ(/project1/photogrammetry_demo)に
  tex(moviefilein)+phong(MAT) を追加して保存済み
- 使い方: Movie File In に `_tex0.png` → Phong MAT Color Map → Geo の Material

### 新規ハマりどころ(上記で発見)

- **SOP の一括 `setTexCoords()` は先頭UVが全点に入る**(実測・TD 2023系)。
  TD付属サンプルと同じ **per-point の `setTexCoord()`** を使うこと
- **PhotogrammetrySession は出力先に既存ファイルがあると invalidOutput**。開始前に削除する
- **ヘルパdylibの修正が反映されないときは install name キャッシュ**(ハマりどころ集①の実例)。
  .plugin のパスを変えても dylib の install name が同じだと dyld が旧dylibを使い続ける。
  Photogrammetry/Shazam の build.sh を `lib*_<epoch>.dylib` 方式に修正済み

### 2026-07-19 6件実装(既存強化3+新規3)

ユーザー指示で推奨リスト6件を一括実装。全てM2実測(GameControllerのみ構造検証)。

- **TextAnalyze日本語類似度**: NLContextualEmbedding(BERT系・macOS 14+)を第一候補に。
  平均プーリング+コサイン類似度。実測: ja文どうしで similarity=0.6433。
  非対応言語/OSはNLEmbeddingへフォールバック。初回アセットDLは警告表示
- **FoundationModel構造化出力**: DynamicGenerationSchemaで "name:type" スキーマ→
  スキーマ保証JSON。DATに Schema パラメータ+field行出力を追加。
  実測: 「真っ赤で激しく点滅」→ color=red / intensity=100 / strobe=1。
  helper dylib を epoch 付き名に修正(install nameキャッシュ対策)
- **VisionFace quality**: VNDetectFaceCaptureQualityRequest を Quality トグルで追加
  (face{i}/quality・bbox最近傍マッチ)。Offなら従来チャンネル互換。
  実測: ダンス動画3顔・quality=0.246
- **Shortcuts DAT**(新規): shortcuts CLI ブリッジ。List/Run・入出力受け渡し。
  実測: ユーザー実環境の21ショートカット列挙
- **Multipeer DAT**(新規): MultipeerConnectivity自動メッシュ(表示名辞書順で
  片方向招待=二重接続防止)。実測: 同一マシン2ノードが相互接続し
  "hello from A" の送受信を確認。入力DAT変化で自動送信
- **GameController CHOP**(新規): GCController 19ch+モーション6ch+CoreHapticsランブル。
  実機パッド未検証(未接続時の警告表示のみ確認)
- 6件ともビルド・インストール済み(TD再起動で反映)。README更新・ルート一覧に3行追加
- 次にやること: GameControllerの実機パッド検証、FoundationModelのfield行を使った
  ショー制御デモ、iPhone側Multipeerサンプルの用意

### 2026-07-19 FoundationModel構造化出力デモを sample.toe に追加

- `/project1/fm_structured_demo`: 雰囲気の言葉 → 構造化出力(r,g,b,intensity,strobe)→
  照明色として画面に出る完全チェーン。色は**数値RGBスキーマで受ける**のが配線を
  頑丈にするコツ(色名文字列だとマッピングが要る)
- field行の参照は **1列目がrow nameになる**ことを利用して
  `float(op('fm')['r',2] or 0)` の式で直接引ける(or 0 は生成前のNone対策)
- strobe は Level TOP opacity の式で LFO(square 8Hz)と合成:
  `intensity * (lfo if strobe else 1)`
- 実測: 「夕暮れの海のような…」→ r0.95/g0.9/b0.9/int0.7/strobe0、
  「真っ赤で激しく点滅する警報…」→ **r1/g0/b0/int1/strobe1** に切替を視認

### 2026-07-19 SpeechText に WhisperKit バックエンド追加

- Backend メニュー(apple/whisper)を追加。whisper は WhisperKit(Core ML版Whisper・
  SPMパッケージ・macOS 14+)を helper dylib(wk_・sp_ と同形の poll JSON)で統合。
  Whisper Model(tiny/base/small/large-v3)と Whisper Task(transcribe/**translate=英訳**)
- Whisper はストリーミング非対応のため「溜めたバッファを0.7秒毎に再認識して volatile 更新、
  無音(末尾0.8s RMS<0.005)or 30秒で確定行に落とす」チャンク方式
- 実測(M2・base・sayのTTS音声): 英語・日本語とも認識成功
  (ja: 「こんにちは、これはウィスパーホン性認識のテストです。部隊証明を真っ赤に…」—
  同音異義の誤りはbase相応。実マイク/大モデルで改善)。モデルは初回にHFから自動DL
- 次にやること: 実マイク音声での精度確認、large-v3系での品質比較

### 新規ハマりどころ(上記で発見)

- **Whisperは無音バッファに「[音楽]」等を幻覚する**。①ほぼ無音のバッファは認識せず捨てる
  (RMS<0.004)②括弧タグだけの確定行は破棄、の2段ガードが必須。
  ガード無しだと音声終了後に幻覚行が延々と積まれる
- WhisperKit は SPM 依存(ImageGenと同じ helper を Swift Package にする型)。
  swift build -c release 初回は依存込みで数分。dylib は install_name_tool で epoch 名に

### 2026-07-19 Multipeer CHOP + iPhoneセンサーアプリ実装

- **Multipeer CHOP**(新規): iPhone等から名前付きfloatチャンネルのバイナリを低遅延
  (unreliable)で毎フレーム受信し、CHOPが**チャンネルを動的生成**する。テキストの
  Multipeer DATの数値版。Service Type一致で自動接続、Prefix Peer Nameで複数台分離
- **ワイヤープロトコル TDMP**(LE): `"TDMP"|uint16 count|count×{uint8 nameLen, name, float32}`。
  CHOPとiOSアプリで共通。入力CHOP接続時は逆に全ピアへ送信も可
- **iOSサンプルアプリ**(`MultipeerCHOP/ios/TDSensor/`・SwiftUI): CoreMotionの
  gyro/accel/gravity/attitude/heading + タッチパッド(touch/touch_x/touch_y)を送信。
  iphonesimulator SDKで型チェック通過。Info.plistに要3キー(ローカルネットワーク/
  Bonjour `_td-sensor._tcp`/モーション)。README にXcodeビルド手順
- **実測**: 擬似送信ピア(macOSのMultipeerで同じTDMPを送るテストバイナリ)から4ch送り、
  CHOPが gyro_x/gyro_y/accel_z/touch を動的生成し値受信を確認(accel_z=0.98/touch=1.0一致)
- CHOP本体ビルド・インストール済み。実機iPhoneでの接続は端末があれば要確認
- 次にやること: 実機iPhoneでの接続・遅延測定、iOS側の受信(TD→iPhone表示/ハプティクス)

### 新規ハマりどころ

- **CHOPは0ch出力を嫌う**。受信前(チャンネル未確定)は1ch(connected)のダミーを出す。
  getOutputInfoでチャンネル名スナップショットを固定し、getChannelName/executeで整合させる
- opTypeはファミリー間で重複可(Multipeer DAT と Multipeer CHOP が同名"Multipeer"で共存)

### 2026-07-19 Multipeer を In/Out に分割(名前で送受信の役割を明示)

- ユーザー指示「multipeer opは in か out か名前で役割がわかるように」を受け、
  双方向1オペレータだった Multipeer DAT / CHOP を**方向別の2オペレータ**に分割:
  - **Multipeer In**(opType `Multipeerin`・icon MPI): 受信専用。CHOP=ピア→TD(動的ch生成・
    入力なし)、DAT=受信→`type/peer/message`テーブル
  - **Multipeer Out**(opType `Multipeerout`・icon MPO): 送信専用。CHOP=入力CHOP→ピア
    (出力`connected`)、DAT=入力DAT→ピア(出力`status/peers/sends`診断・入力必須)
- ObjCブリッジを共有ヘッダに切り出し(`MultipeerChopBridge.h`/`MultipeerDatBridge.h`)。
  In/Outは別バンドルなのでヘッダに`@implementation`を置いても重複シンボルにならない
- 1フォルダから2バンドルを作るため build.sh は共通ヘルパを使わず手動(build_one を2回)。
  共通ヘルパは`rm -rf build`を毎回するため2回呼べない
- iOSアプリのserviceTypeは`td-sensor`のままでIn CHOPの既定と一致(変更不要)
- 旧 MultipeerDAT.mm / MultipeerCHOP.mm は削除。旧インストール済みバンドルも削除し
  新4バンドルを配置。**TD再起動後にロード検証完了**(2026-07-19):
  MultipeerinCHOP/MultipeeroutCHOP/MultipeerinDAT/MultipeeroutDAT の4型が登録され、
  パラメータ生成・エラーなしを確認。同一マシンで Out→In を別Peer名・同Service Typeで接続し、
  **CHOP: gyro_x=0.42/accel_z=0.98/touch=1.0 が動的ch生成され値一致、
  DAT: "hello from out DAT" が In 側テーブルに到達**(Out診断 status=ok/peers=1/sends=1)
- 注意: In と Out を同一Macに置くとピアから2ピアに見える(別セッション)。センサー受信のみ
  なら In だけの最小構成を推奨
