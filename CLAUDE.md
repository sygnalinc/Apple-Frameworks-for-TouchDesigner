# CLAUDE.md — TDAppleOps 開発ガイド(AIエージェント向け)

> リポジトリは 2026-07-20 に `TDAppleML` から **`TDAppleOps`** へ改称(中身がML専用でない
> ため)。コード内のキャッシュパス `~/Library/Caches/TDAppleML/` と過去ログの旧名は、
> 互換性・履歴保持のため据え置き。ローカル作業フォルダ名は `TDAppleML` のままでも可。

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

### 2026-07-20 sample.toe に全カスタムOPの利用例を追加(/project1/examples)

- ユーザー指示「全てのopのコンテナを作って利用例を組む」を受け、`/project1/examples` 配下に
  **1オペレータ=1コンテナ**の最小利用例を51個構築。各コンテナは
  共有ソース参照(Select TOP→media_video / audiofilein→media_audio)→OP→out+説明textDAT
- バッチ順に保存・main直コミット(4コミット)。全OPエラーなしを確認、主要OPは実データ検証:
  VisionPose=5人検出、Segment 512x384、CoreML(Depth)518x392、YOLOv3 5検出、
  SAM2 256x256マスク、SoundFeatures 29ch、MusicEvents 214イベント、Upscale 640→1280x720
- Barcodeは動画にQRが無いのでCoreImageCode TOPでQR生成して入力(payload検出を確認)
- Shazam参照フォルダは著作物mp3の同梱を避けTD Samples/Audioを参照。SpeechText用に
  say生成の `Assets/sample_speech.aiff`(小・非著作物)のみ同梱
- **VisionSimilarity/VoiceActivity は未インストールだったので本セッションでインストール済み。
  TD再起動後に td.VisionsimilarityCHOP/VoiceactivityCHOP が現れるので、その2つの
  利用例コンテナを追加すれば全53OP網羅**(次セッションのTODO)
- 開いていた sample.toe は以前のデモ(sam2_track_demo等)を含まない2ノード状態だった。
  git HEADの旧版(28578B)はバックアップ済み。新しい examples 集約版で置き換えた

### 2026-07-20 Music系OPを全削除(期待動作せず)

- ユーザー判断により Music 系4オペレータ(MusicCompose DAT / MusicEvents DAT /
  MusicMIDI CHOP / MusicSequence CHOP)を**リポジトリ・インストール済みプラグイン・
  music専用モデルから全削除**。期待した音楽的出力が得られなかったため
- 削除対象: リポジトリの `MusicCompose/` `MusicEvents/` `MusicMIDI/` `MusicSequence/`
  (このブランチには未コミットの未追跡フォルダだった)、`~/Library/.../Plugins/` の
  4バンドル、`models/GeneralUser-GS.sf2`(32MB・MusicSequence専用・gitignore対象)、
  ルートREADMEのMusic 4行
- sample.toe には触れていない(ユーザー指示)。開いているTDに残る Music 例コンテナと
  カスタムOPは、削除済みバンドルのため TD再起動後にロードエラー(赤)になる。
  次に sample.toe を編集する際に該当4コンテナを手動削除すること
- 過去ログ(GeneralUser GS適用・MusicComposeサンプル等)は履歴として残置

### 2026-07-20 プラグインフォルダ名をフレームワーク接頭辞ラベルに統一

- opLabel/opType のフレームワーク接頭辞化に合わせ、フォルダ名・ソース.mm・build.sh・
  各READMEを12件リネーム(git mvで履歴保持):
  VisionBokeh→CoreImageBokeh / VisionKeystone→CoreImageKeystone /
  ImageAutoEnhance→CoreImageEnhance / SAM2Segment→CoreMLSAM2 / ImageGen→CoreMLImageGen /
  Upscale→MetalUpscale / Denoise→MetalDenoise / FrameInterp→MetalFrameInterp /
  MPSAnalyze→MetalMPSAnalyze / ImageMetadata→ImageIOMetadata /
  VoiceActivity→SpeechActivity / Photogrammetry→RealityKitCapture
- **Swiftヘルパのモジュール/dylib名は内部保持**(VoiceActivityHelper・PhotogrammetryHelper・
  libImageGenHelper)。build.shは`s/<旧NAME+family>/<新NAME+family>/g`でNAME・ソース.mm・
  plistのみ置換し、Helperを含む行は別substringなので巻き込まない設計にした
- **ImageGen(SPM)はフォルダ移動でModuleCacheパスが変わり再ビルド失敗**するため、
  移動後に`rm -rf helper/.build`してから`swift build`(既知のハマりどころ再現)
- ルートREADMEのリンク先hrefと表示名を全プラグインの新ラベル(Vision Pose /
  CoreImage Bokeh / Metal Upscale / RealityKit Capture 等)へ更新。表示名は実バイナリの
  opLabelと突き合わせて確定(Foundation Model / Translate / Text Analyze は据え置きが正)
- 12件を再ビルド・ad-hoc署名し、常設Pluginsへ再インストール。**旧名インストール済み
  バンドルは先に削除**(旧バンドルは既に新opTypeを内包しており、残すとopType重複衝突)
- `git add -A`が100MB超のローカル専用テスト動画(test_animal.mp4 366MB /
  test_video_2.mp4 175MB)を巻き込みpush却下(GH001)。動画2本・TDImportCache/・
  CrashAutoSave.*を.gitignoreへ追加し、リネームに絞って再コミット→push成功(a38e61b)
- 次にやること: sample.toe内のデモは変更opType(12種)で参照切れ。ユーザーは.toe破損許容
  済みだが、再構築するなら新opType(coreimagebokeh等)で貼り直しが必要

### 2026-07-20 RealityKit Splat TOP 実装(RealityRendererオフスクリーン描画)

- `RealityRenderer`(macOS 15+)で **USD/USDZ/Reality シーンをオフスクリーン描画**して TOP に出す
  新規プラグインを実装。**macOS 26 の RealityKit は 3D Gaussian Splat を描画**できるため、splat を
  含む USD をTDに取り込める(通常のPBRメッシュUSDZも可)。カメラはTDパラメータからオービット駆動
- **踏んだ地雷(スキルの pitfalls.md にも反映)**:
  - **RealityRenderer は `@MainActor` 拘束だが TDの TOP cook はメインスレッドではない**。
    execute から `MainActor.assumeIsolated` は trap する → **`DispatchQueue.main.async` で本物の
    メインスレッドへ描画を回す**(TDがメインランループをpump)。GPU完了(onComplete)で shared
    MTLTexture を CPU readback → latest。cookは非ブロックで latest をupload
  - **Gaussian Splat 専用ロードAPIは無い**(SDKに splat/gaussian シンボル無し)。USD経由で
    `Entity(contentsOf:)`。= splat専用ではなく「RealityKitが読めるUSDシーンを描くTOP」
  - **`entity.scale` でロード物を正規化すると内部トランスフォームと複合して破綻**(16単位が
    150単位に肥大)→ **エンティティは無変形、カメラ側でフレーミング**(target=bounds中心・
    distance=半径×倍率)。被写体サイズ非依存
  - **PBRメッシュはIBL/ライト無しで真っ黒**(Unlitは自己発光で出る)→ 簡易IBL
    (`EnvironmentResource(equirectangular:)`)+ DirectionalLight を常設
  - ModelIO の `MDLAsset.export` は `.usdz` 拡張子不可 → `.usdc`
- **検証(M2・TD MCP)**: ヘッドレスCLIでオフスクリーン描画を先に確認(箱・pencil.usdz)後、
  TDに C++ TOP でロード。デフォルトの箱シーン(自動フレーミング)と Apple サンプル pencil.usdz を
  **視認**。640×480で **約58fps**(frames が executes に追従・フレーム落ちなし)、loaded=1、
  errors/warnings なし。検証ノード削除済み
- 実装は Swiftヘルパ(`RealityKitSplatHelper`・C ABI `rk_`)+ CPUMem TOP。build.sh は epoch dylib。
  `~/Library/.../Plugins/` へインストール済み(TD再起動で `td.RealitykitsplatTOP` が出る)
- **splat 実アセット未検証**(手元に splat USDZ が無い)。ロード経路は USDZメッシュで検証済みで、
  splat も同じ `Entity(contentsOf:)` 経路。splatの実描画確認が次の課題。README に明記
- 次にやること: 実 Gaussian Splat USDZ での描画確認、sample.toe への利用例追加

### 2026-07-20 Plugins整理 + sample.toe利用例の作り直し(opType改称対応)

- **重複の実体**: フォルダのバンドルファイル自体はクリーンだったが、①`Plugins.json`(TD承認リスト)に
  旧名の残骸19件(StableDiffusion/ImageGen/Upscale/Music系/VoiceActivity等)、②**実行中TDプロセスの
  メモリに旧opType登録が残存**(今セッションで旧→新バンドル差し替え時の名残)。②は
  **TD再起動でクリーンなフォルダ再スキャンにより解消**(ファイル操作では消せない)
- Plugins.jsonのゴースト19件をバックアップ付きで削除
- **sample.toe `/project1/examples` を改称に追従して作り直し**(KeyframeEditorは未変更):
  - 旧opType参照の11例を新opに置換+コンテナ名を新ラベルへ(VisionBokeh→CoreImageBokeh、
    Upscale→MetalUpscale、SAM2Segment→CoreMLSAM2、Photogrammetry→RealityKitCapture等)。
    配線(inputs/outputs)とカスタムパラメータ値を維持したまま差し替え
  - 削除済みMusic系4例を除去
  - 欠落していた VisionSimilarity / SpeechActivity / RealityKitSplat の3例を追加
  - **全custom opのnode名を "op1" → 手動設置時の既定名 `<OpType>1`**(例 Coreimagebokeh1)に統一
  - 計50例、全てエラー無しを確認して保存。RealityKitSplatはデフォルト箱シーンの描画も視認
- **踏んだ罠**: ①TDのcustom op生成は `create('CoreimagebokehTOP')`(先頭大文字opType+FAMILY大文字)。
  小文字や'TOP'サフィックス無しは "Unknown operator type"。②新規追加opは**TD再起動まで未登録**で
  create不可(RealityKitSplatは再起動後に追加)。③VisionBarcode等の複数custom op containerは
  主opの取り違えに注意(先頭isCustomが補助opのことがある)
- 次にやること: 実Gaussian Splat USDZでのRealityKitSplat描画確認

### 2026-07-20 深度/RAW/HDR/文書/点群 5プラグイン実装(堅実な画像系)

ユーザー提案15件をSDK実機で実現可能性トリアージし(#1,6,11,12,13,15はmacOS公開API無しで除外)、
堅実な5件を実装。全てM2実測・TD MCP検証。

- **ImageIO Depth TOP**: iPhone写真の深度/視差/Portrait Matte/セマンティックマット(skin/hair/sky/
  teeth/glasses)を ImageIO 補助データから抽出→Mono32Float。合成視差HEIC(自作)で range 0.02〜0.5
  round-trip一致・Autoモード・深度なし警告を確認
- **CoreImage RAW TOP**: CIRAWFilterでDNG/ProRAW現像(露出/WB/ノイズ/シャープ)→RGBA16Float。
  パイプライン動作・パラメータ反映を確認。**実RAW視覚検証はサンプル未入手で未実施**(JPEGは開けるが
  非RAWは現像がズレる)
- **CoreImage HDR TOP**: HEICのHDRゲインマップ抽出/SDR/HDR(EDR)変換。自作ゲインマップHEIC
  (`writeHEIFRepresentation` option `.hdrGainMapImage`)で Gain Map/SDR を視認、HDR拡張は動作
  (>1は実HDR写真のheadroom必要)
- **Vision Document DAT**(Swiftヘルパ): 新Vision `RecognizeDocumentsRequest`(macOS 26+)で
  段落/表/セル/リスト構造を認識。自作文書画像で **table 4×3・12セル全てを正しいrow/col+テキスト**で
  抽出(Region/Q1/Q2, North/120/145…)を確認。高精度
- **ImageIO PointCloud SOP**: 写真深度を内部パラメータ(AVDepthData较正 or FOV)で逆投影→点群+色。
  合成深度HEICで **16384点(128×128)・Z範囲 −1.0〜−0.04 が視差×scaleと厳密一致**を確認。
  较正付き実写真の内部パラメータ経路は実写真未入手で未検証

- **踏んだ地雷(pitfalls.md反映)**: ImageIO補助データのfloat16変換(vImage)、AVDepthData较正の
  取り出し、HDRゲインマップのCIImageオプション、CIRAWFilterは非RAWも開く、**ModelIO/ImageIOは
  DNG/USDZを書き出せない**(テスト素材合成の壁)、**SOP_PluginInfoは`setAPIVersion()`**、
  **cplusplusSOPの試用時は.pluginフォルダ名=実行バイナリ名でないとdlopen失敗**
- 5件ともビルド・署名・`~/Library/.../Plugins/`インストール済み(TD再起動で登録)。README+ルート一覧(英日)更新
- 次にやること: 実深度写真(ポートレート)/実DNG での検証、複雑枠(CinematicDepth/SpatialAudio/
  GeneratedCaption)の実装可否判断

### 2026-07-20 Create ML 汎用Training OPの設計方針(未実装)

- ジェスチャー専用の `GestureTrain DAT` ではなく、Create ML本来のワークフロー
  **Task選択 → Dataset指定 → Train → Evaluate → Core MLモデル出力**をTD内から扱う
  汎用 **Create ML DAT** として実装する。表示名 `Create ML`、opType `Createml`、icon `CML`。
- Create ML DATは**学習・評価・モデル出力だけ**を担当する。推論は既存の CoreML TOP / CoreML CHOP、
  将来追加する CoreML DATへ渡す。モデル出力はユーザー指定先の `.mlmodel` / `.mlpackage`、必要なら
  `.mlmodelc`。生成モデルはリポジトリへコミットせず、LFSも使わない。
- DatasetはCreate MLアプリに近いファイル/フォルダ入力を基本とし、TD向けに入力DATも許可する:
  - Tabular Classification / Regression: CSVまたはTable DAT。Target columnとFeature columnsを指定
  - Image / Sound Classification: `<dataset>/<label>/<sample>` のラベル別フォルダ
  - Time Series Classification: sequence/frame/features/labelを持つCSVまたはDAT
  - Action / Hand Action: ラベル別動画フォルダ
  - 後続でObject Detection、Text Classification、Word Tagging、Recommender、Style Transfer
- **段階実装**:
  1. v1: Tabular Classification、Tabular Regression、Image Classification、Dataset検証、
     学習/評価、Metrics、Core ML書き出し
  2. v2: Time Series Classification、Sound Classification、Action Classification、Checkpoint/Resume
  3. v3: Object Detection、Hand Pose/Action、Text、Recommender、Style Transfer
- VisionPoseジェスチャー認識は専用OPにせず、汎用の **Time Series Classification** または
  **Action Classification** の利用例として提供する。前者はVisionPose CHOPの時系列を直接Dataset化、
  後者はラベル別動画を`MLActionClassifier`へ渡してCreate ML側でVision関節抽出を行う。
- 主パラメータ: Task / Training Path / Validation Path / Testing Path / Output Model / Model Name /
  Train / Pause / Resume / Cancel / Evaluate / Export。DataページにData Mode / Target Column /
  Feature Columns / Validation Split / Test Split / Shuffle / Seed / Cache Features。Trainingページに
  Iterations / Batch Size / Learning Rate(対応Taskのみ) / Maximum Time / Augmentation / Compute /
  Checkpoint Folder。Taskごとに関連パラメータだけenableする。
- DAT出力はModeで Summary / Metrics / Confusion Matrix / Classes / Model Description / Log を切替。
  共通キーは status / phase / progress / iteration / training_accuracy / validation_accuracy /
  training_loss / validation_loss / samples / elapsed_seconds / remaining_seconds / model_path。
  Info CHOPにもbusy/progress/iteration/accuracy/loss/elapsed/remainingを出す。
- **学習をTDプロセス/cook内で実行しない**。Swiftのhelper executable `CreateMLTrainer`を
  `.plugin/Contents/Helpers/`へ同梱し、設定JSONで起動、progress JSONをpollする別プロセス方式にする。
  TDをブロックせず、学習クラッシュの隔離、Cancel、Checkpoint、終了後のメモリ解放を可能にする。
  推奨構成:
  `CreateML/CreateMLDAT.mm` + `helper/Package.swift` +
  `Sources/CreateMLTrainer/{main,TaskFactory,DatasetLoader,MetricsWriter}.swift`。
- Create ML APIはTaskごとに非同期`MLJob`対応範囲やパラメータが異なる。共通設定を無理に全Taskへ
  適用せず、未対応値はhelperへ送らずApple既定値を使う。Pause/Resume/Checkpointも対応Taskのみ有効化。
- 学習前にDataset検証を必須にする: パス/拡張子、クラス数、サンプル数、欠損値、列型、ラベル不均衡、
  Train/Validationのクラス一致を検査し、Create MLへ投入する前にInfo DATへ明確なエラーを返す。

### 2026-07-20 Cinematic Audio Mix CHOP設計方針(未実装)

- Logic ProのStem Splitterは外部公開API無し。一方、macOS 26のCinematic / AudioToolboxにある
  **AUAudioMixは公開Audio Unit**なのでTD Plugin化可能。ただし通常楽曲のVocal/Drums/Bass分離ではなく、
  **対応Spatial Audio素材のForeground(主にspeech) / Background(ambience)分離・再ミックス**である。
- 新規Pluginは既存`Cinematic/`(深度・フォーカス・映像再レンダ)へ混ぜず、別フォルダ
  `CinematicAudioMix/`、表示名 `Cinematic Audio Mix`、opType `Cinematicaudiomix`、CHOP、icon `CAM`。
- 入力はファイル指定を基本とする。対象はiPhone 16以降等のSpatial Audio動画、FOA/APACトラック、
  必要なSpatial Audio Mix metadataを持つMOV/QTA。一般的なMP3/WAVでは意味のある分離はできない。
  `CNAssetSpatialAudioInfo`で対応可否を事前検査し、非対応理由をInfo DATへ出す。
- Rendering Style: Standard / Cinematic / Studio / In-Frame。Stem用に各スタイルの
  Foreground Stem / Background Stemがある。出力Mode:
  - Mixed: `left/right`
  - Stems: `foreground_l/r`, `background_l/r`(2つのAUAudioMixを同期、またはofflineで2回render)
  - All Stylesは12ch出せるが6回render相当で重いため初版対象外
- 主パラメータ: File / Mode / Style / Intensity(0..1) / Position / Play / Loop / Speed /
  Sample Rate / Render / Reset。Info CHOPは executes/renders/busy/valid/duration/samplerate/
  channels/position、Info DATは status/has_spatial_audio/content_type/rendering_style/error。
- 実装順: ①`CNAssetSpatialAudioInfo`素材検証 ②Mixed stereo ③Foreground ④Background
  ⑤4ch同期Stem ⑥Position/Play/Loop ⑦cook中のIntensity変更 ⑧offline WAV書き出し。
- リアルタイム版はAudio Unit pull model→Float32リングバッファ→CHOP sample block。cook内ファイルI/O禁止、
  parameter変更ごとのAU再生成禁止、seek時Flush、2 Stemのsample同期、sample-rate変換、underrunは0出力。
  初期検証はAppleの`SpatialAudioCLI`と同じAVAssetWriter/offline render経路から始めてもよい。

### 2026-07-20 Cinematic 2プラグイン実装(iPhone Cinematicモード動画)

iPhone Cinematicモード動画から深度・被写体・フォーカスを扱う2プラグインを実装(Apple `Cinematic`
framework・macOS 26+)。Apple公式サンプル "Playing and editing Cinematic mode video" のAPIに準拠。

- **Cinematic Data(CHOP)**: `CNScript.frame(at:)` からフォーカス深度・被写体スロット
  (type/bbox/depth/trackID)を毎フレーム出力。ピクセルデコード不要。83ch(focus/strong/subjects+10×8)
- **Cinematic Video(TOP)**: Depth mode=視差マップ(Mono32Float)、Rendered mode=`CNRenderingSession`
  でf値/ピント差し替え再レンダ(RGBA16Float)。ワーカースレッドでデコード/レンダしcook非ブロック
- 共有Swiftヘルパ `CinematicHelper`(cn_)で時刻指定デコード(AVAssetReader)。1フォルダから
  2バンドル生成(Multipeer In/Out と同型のbuild_one×2)

- **検証(M2・TD MCP)**: **両プラグインのロード・パラメータ生成・チャンネル構造・File未指定の
  安全動作を確認**(クラッシュ・エラーなし)。**実Cinematic動画での深度/再レンダ/被写体の視覚検証は
  実素材未入手のため未実施**。Apple公式サンプルはコードのみで動画非同梱、ネット上に検証可能な
  Cinematic動画が無いことを確認(実機撮影→AirDropが必要とREADMEに明記)
- **踏んだ罠(pitfalls.md反映)**: CHOPの`execute(CHOP_Output*`は非const・`CHOP_GeneralInfo.timeslice`
  は小文字s、Cinematicのメタデータは`CNScript`でデコード不要、再レンダは3トラック(video/disparity/
  metadata)を同時刻デコード→`encodeRender`、Cinematic動画は合成不可で実機撮影必須
- 途中でTDがクラッシュ(→再起動)したが、クリーン再ロードで再現せず**プラグイン起因ではなく
  TD/MCPの一時的不安定**と確認。ロード安全確認後に常設インストール
- 次にやること: 実Cinematic動画(iPhone 13以降・AirDrop)での深度・再レンダ・被写体の視覚検証、
  スクラブ高速化(AVSampleBufferGenerator)

### 2026-07-20 Cinematic 実動画検証 → iPhone 17新形式は現状読めないと判明

- ユーザーが実Cinematic動画を2本追加(`Assets/cinematic_footage.mov` 37MB / `cinematic_footage2.mov` 15MB)。
  gitignoreへ追加(検証に使えず巨大なため)
- 両方 **iPhone 17 Pro / iOS 26.5.2 の新Cinematic video形式**。`CNAssetInfo` が
  `CNCinematicErrorCodeIncomplete`(=3)で失敗。原因を実機解析:
  - トラック = 映像1(**hvc1 単層HEVC** 3840×2160)+音声aac+メタmebx の3本のみ
  - **旧Cinematicモード(iPhone 13〜16)の分離した視差トラックが無い**
  - MV-HEVC第2レイヤーも無し(subtype hvc1)、mebxは5サンプル8バイト(フラグのみ)、映像に深度aux無し
  - `com.apple.quicktime.cinematic-video` フラグは有り(=Cinematic撮影はされている)
- **結論: iPhone 17の新Cinematic形式から深度を取り出す公開macOS APIが現状(26.4 SDK)存在しない**。
  `Cinematic` framework(CNAssetInfo/CNScript)は旧形式専用。WWDC25の新Cinematicは撮影側API
  (AVCaptureDeviceInput.cinematicVideoCaptureEnabled 等)で、読み取り/編集側の新形式対応は未提供
- プラグインは**旧形式向けに正しく実装済み・ロード検証済み**。iPhone 13〜16の動画があれば動く想定。
  新形式対応はAppleの読み取りAPI提供待ち(足場として残す)。pitfalls.md / README に明記
- 深度が今すぐ要る用途は ImageIO Depth / ImageIO PointCloud(iPhone写真)を案内

### 2026-07-20 Cinematic 結論の訂正: 「新形式で読めない」は誤り→転送で深度が剥がれていた

- 前エントリで「iPhone 17の新Cinematic形式は読めるAPIが無い」と結論したが**誤り**。裏取りで訂正。
- Apple公式([support.apple.com/en-us/101995](https://support.apple.com/en-us/101995) 他)によると、
  Cinematic動画をAirDropする際に**共有→オプション→「すべての写真データ(All Photos Data)」をオンに
  しないと、通常動画に平坦化され深度・フォーカスを編集できなくなる**。Cinematic frameworkが読めるのは
  深度データ付きのファイルのみ
- 手元の2ファイル(iPhone 17 Pro)が「単層hvc1・視差トラック無し・CNAssetInfo Incomplete」だったのは、
  まさに**平坦化された(All Photos Data無しで転送された/IMG_E焼き込み版)通常動画**の状態。形式やAPIの
  問題ではなく**転送方法の問題**だった
- 正しい取り出し: 写真アプリ→クリップ選択→共有→オプション→「すべての写真データ」ON→AirDrop→
  Mac側フォルダの**「IMG_E」接頭辞が無い .MOV** を使う。機種(13〜17)問わず正しく転送すれば読める想定
- README/skill/この記録を訂正。プラグイン実装自体は変更なし(Apple サンプルAPI準拠で正しい)。
  深度保持ファイルが入手でき次第、視覚検証する

### 2026-07-20 Cinematic 実素材で全機能検証完了(深度・被写体・f値再レンダ)

- ユーザーが「すべての写真データ」付きの正しいCinematic原本(iPhone 17 Pro・`IMG_2531/IMG_2531.MOV`
  等・視差track id2 あり)を提供。`CNAssetInfo OK`(前回の平坦化ファイルと違い視差トラックを持つ)
- **実データで全機能を視認確認**:
  - Cinematic CHOP: focus_disparity=0.75、被写体4個(猫=pet depth2.0、物体 depth0.18)
  - Cinematic TOP Depth: 手前=近い の視差深度マップ
  - Cinematic TOP Rendered: 3840×2160再レンダ、f/2.0(背景大ボケ)↔f/16(背景くっきり)を視認
- **デバッグで潰した実バグ(pitfalls.md反映)**:
  1. **Swiftの `memcpy(&array[i], ...)` が不安定** → 行反転コピーで出力破壊(縦縞)。
     `withUnsafeMutableBufferPointer` のベースポインタ+offsetに修正
  2. **AVAssetReaderのCVPixelBufferはreader破棄で無効化** → cancel後の変換で解放済みメモリ読み
     (実行毎に変わるガベージ)。reader/CMSampleBufferを変換完了まで保持
  3. **再レンダのメタは `AVAssetReaderOutputMetadataAdaptor`→`nextTimedMetadataGroup()`→
     `FrameAttributes(timedMetadataGroup:)`**。生サンプルは FrameAttributes/AVTimedMetadataGroup とも nil
  4. **視差の無効画素は巨大sentinel(1.566e38、isFinite通過)** → `>1e4`も無効除外して正規化
  5. depth抽出はIOSurface無し(タイトbytesPerRow)、renderはIOSurface付き、と用途で分ける
- 途中TDが落ちたがクリーン再ロードで再現せず(プラグイン起因でないと確認済み)
- 両プラグイン最終ビルド・署名・常設インストール済み。README/skill/この記録を「検証完了」に更新。
  テスト動画(IMG_2531/2532フォルダ)は巨大なのでgitignore

### 2026-07-20 CreateML Image DAT 実装(オンデバイス画像分類学習)

- CreateML `MLImageClassifier` でラベル付きフォルダ(サブフォルダ=クラス)から画像分類を
  オンデバイス学習し `.mlmodel` を書き出す DAT を新規実装。**出力モデルは既存 CoreML TOP が
  推論できる**ので「TD内で撮る→ラベル付け→学習→推論」を閉じられる
- Swiftヘルパ `CreateMLImageHelper`(cm_)。非同期 `train()→MLJob`、`job.result` を Combine `.sink` で
  購読し完了で `write(to:)`。進捗は `job.progress.fractionCompleted` を poll。cook 非ブロック
- **検証(M2)**: 合成データ(horizontal/vertical/checker 縞・各15枚)を自作。ヘッドレスで学習
  → **val_acc 1.0**、.mlmodel 出力。出力モデルを Vision/CoreML で推論し3クラス全て正解(信頼度1.000)。
  TDでも Train パルス→done・val_acc 1.0・モデル書き出しを確認
- **踏んだ罠(skill反映)**: `MLJob` と `AnyCancellable` を state に保持しないと購読が即解放。
  pulse は `pulsePressed(name)`(OP_Inputs無し)→フラグ→execute で処理。CreateMLはSwift/Combine専用
- README+ルート一覧(英日)更新、常設インストール済み(TD再起動で `CreateML Image` 登録)
- 次にやること: CreateML HandPose(ジェスチャ学習・VisionHandと連携)、TOP画像からの直接学習
  (キャプチャ→一時ラベルフォルダ)、CoreML TOPでのTD内推論デモ

### 2026-07-20 CreateML Motion DAT(学習)+ CoreML Motion CHOP(ライブ推論)実装

- ユーザー「Vision Poseの動きやジェスチャを学習させたい」→ **学習+ライブ推論の2オペレータ**構成で実装
- **CreateML Motion DAT**(Swiftヘルパ cma_・opType `Createmlmotion`・icon CMM): 録画した時系列
  CHOP系列のCSV(1行=1フレーム、`label`列+`recording`列+特徴列)から `MLActivityClassifier` で
  動き/ジェスチャ分類を**オンデバイス学習**し `.mlmodel` を書き出す。特徴列は空欄で自動採用
- **CoreML Motion CHOP**(ObjC++ CoreML・opType `Coremlmotion`・icon CMO・minInputs=1): 学習モデルを
  ロードし、入力CHOP(VisionPose等)を予測窓ぶんリングバッファして**ライブ分類**。出力は
  `prob_<class>` + confidence + predicted + buffered。モデル記述から特徴名/窓/クラスを自動取得、
  recurrent state(stateOut)を毎フレームフィードバック
- **実測(M2)**: 合成4特徴・30収録×80フレーム・3クラス(circle/wave/still)で学習→done約1秒・
  983KB。TDライブ推論で **円運動→prob_circle=1.0、横振動→prob_wave=1.0** を確認(切替追従)
- **踏んだ罠(skill反映)**: ①`MLActivityClassifier` はフラット表を拒否("x0 type is not a Sequence")。
  収録IDでグループ化し**各特徴を[Double]配列にしたシーケンス列テーブル**(1収録=1行)を作る必要。
  ②TD constant CHOP の式は Python なので `sin` 単体は NameError→式が壊れると**チャンネルが空**になり、
  CHOP側は特徴不一致で0埋め→常に"still"。`math.sin`/`math.cos` を使う(推論ロジックは単体harnessで
  30/30正答済みだったので、原因はテスト入力側だった)
- README(英日ルート一覧含む)更新、両プラグイン常設インストール+ad-hoc署名済み(TD再起動で登録)。
  検証用TDノード(_mvin/_mvinfer/_mvnull)は削除済み
- 次にやること: 実VisionPose 68ch を録画→学習→ライブ認識のデモを sample.toe に組む、
  CreateML HandPose(手ジェスチャ)、TOP/CHOP録画ユーティリティ

### 2026-07-20 CreateML DAT(汎用トレーナ・全8Task統合)実装

- ユーザー「HandPoseやposeなど汎用的なCreateMLにできるならまとめたい」→ 個別の CreateML Image /
  CreateML Motion を**1つの汎用 CreateML DAT に統合**(opType `Createml`・label "CreateML"・icon CML)。
  当初 CLAUDE.md の「汎用 Create ML DAT・Task選択方式」方針に合流
- **Task メニュー8種**を1オペレータで切替: Image(`MLImageClassifier`)/ Hand Pose
  (`MLHandPoseClassifier`)/ Action 体(`MLActionClassifier`)/ Hand Action(`MLHandActionClassifier`)/
  Sound(`MLSoundClassifier`)/ Activity CHOP時系列(`MLActivityClassifier`)/ Tabular 分類
  (`MLClassifier`)/ Tabular 回帰(`MLRegressor`)。出力 .mlmodel は既存 CoreML TOP /
  CoreML Motion CHOP / SoundClass 等がそのまま推論
- **統合ヘルパ `CreateMLHelper.swift`(ml_)**: フォルダ系5種は `.labeledDirectories(at:)`+`MLJob`
  を汎用 `wireJob<T>()`(job.progress/cancel/精度/書き出しを型消去で配線)で共通化。Activity は
  シーケンス列 `MLDataTable`、Tabular は `MLDataTable` をバックグラウンドThreadで同期学習
  (`MLJob`版が無いため)。全Taskの API シグネチャは事前に `swiftc -typecheck` で実SDK確認
- **ポーズ/ジェスチャの学習ルートは2つ**とREADMEに明記: フォルダ素材(HandPose/Action=CreateMLが
  Vision抽出)/ CHOP録画(Activity=VisionPose/Hand関節の時系列CSV、追加素材不要・推論は CoreML Motion)
- **実測(M2・ヘッドレスharness)**: Tabular分類 train/val=1.0、Tabular回帰 RMSE 0.12(metadata付き書き出し)、
  Activity train1.0/val0.571(特徴自動検出)、Image 学習完走+クラス自動列挙。フォルダ系残り4種は
  Image と同一機構+型チェック確認済み(実素材=手画像/ラベル動画/音声は未合成)
- **API確定メモ**: `MLActionClassifier.ModelParameters(validation:batchSize:maximumIterations:`
  `predictionWindowSize:augmentationOptions:algorithm:targetFrameRate:)`、HandAction も maximumIterations、
  Image/Sound は maxIterations、HandPose は maximumIterations。Tabular の `write(to:)` は `metadata:` 必須。
  精度は全分類器 `trainingMetrics/validationMetrics.classificationError`、回帰は `rootMeanSquaredError`
- 旧 CreateMLImage / CreateMLMotion は**フォルダごと git rm・インストール済みバンドルも削除**して吸収。
  推論側 CoreML Motion CHOP は独立OPとして残す。README(新規+ルート英日)更新。CreateMLDAT.plugin を
  常設インストール済み(**TD再起動で `Createml` 登録**)
- 次にやること: TD再起動後の Createml ロード+Taskメニュー+学習の実機確認、フォルダ系4種の実素材検証、
  sample.toe の CreateML 例更新(旧 Createmlimage/Createmlmotion 参照を Createml へ)

### 2026-07-20 CoreML汎用推論OPの名前を「CoreML」に統一(TOP/CHOP/DAT)

- ユーザー指示「core ml opの名前が統一されてない。chop/dat/topは色でわかるので全てのCoreMLという
  同じ名前にして、それらとCoreML ImageGenで整理して」を受け、**汎用CoreML推論の3オペレータを
  opLabel/opType とも統一**:
  - CoreML TOP: `Coreml` / "CoreML"(変更なし)
  - CoreML CHOP: `Coremlchop`/"CoreML CHOP"/icon CMC → **`Coreml`/"CoreML"/CML**
  - CoreML Detect DAT: `Coremldetect`/"CoreML Detect"/icon CMD → **`Coreml`/"CoreML"/CML**
- **opType はfamily間で重複可**(既出のMultipeer In/Out同様)。TOP/CHOP/DAT が同じ `Coreml` でも
  family(色)で区別され、OP Create Dialogでも各familyに1つずつ「CoreML」が出る。ノード自動命名も
  `coreml1` で揃う
- **特化型は個別名で維持**(同family衝突&機能特化のため): CoreML Motion(CHOP・動作分類ライブ)、
  CoreML SAM2(TOP・セグメンテーション)、CoreML ImageGen(TOP・生成)。ユーザーの「ImageGenで整理」
  =生成系は別枠、の指示通り
- バンドル名(CoreMLCHOP.plugin / CoreMLDetectDAT.plugin)は不変。中身のopTypeだけ変えて同名上書き
  インストール。リビルド・署名・インストール済み。README(各+ルート英日)更新
- **注意**: opType変更で、sample.toe の `Coremlchop`/`Coremldetect` 参照ノードはTD再起動後に
  ロードエラー(Unknown operator type)になる。ユーザーは.toe破損許容済み。examples再構築時に
  `Coreml`(family指定)で貼り直す。CoreML TOP例はopType不変なので影響なし
- 次にやること: TD再起動後に3family全て「CoreML」表示・`Coreml` opTypeでの生成を確認、
  sample.toe examples の CoreML CHOP/Detect/CreateML 参照を更新

### 2026-07-20 sample.toe examples を現行OP群に合わせて作り直し + ゴースト解消

- ユーザー指摘「Create Dialogに Coremlchop / coremldetect / CoreML Motion が残る」を調査。
  **原因はディスク上のバンドルではなく、sample.toe の旧・利用例ノード**
  (`examples/CoreMLCHOP/Coremlchop1`・`examples/CoreMLDetect/Coremldetect1`)が旧opTypeを
  抱え、TDが型をレジストリに保持していたため(バンドル無しでも生成可能なゴースト化)
- インストール済み・リポジトリ・全ディスクを走査し、旧opType `Coremlchop`/`Coremldetect` を
  登録するバンドルは**存在しない**ことを確認(scratchpadの古いコピー1件のみ・TD非スキャン)。
  TDプロセスは新バンドル(`Coreml`)を読み込み済み
- 旧2ノードを新 `Coreml`(CHOP/DAT)へパラメータ・配線維持で置換 → ゴーストの発生源を除去。
  型はTD再起動時のみ破棄されるため、旧ノード除去済みの.toeを保存すれば次回起動で消える
- **CoreML Motion(CHOP)は意図的な別OP**(`Coremlmotion`)でありゴーストではない旨をユーザーに回答
- **不足していた8例を新規作成**(50→58コンテナ)。全てエラーなし・実データ検証:
  - **CreateML**(DAT): Task=Tabular、同梱CSVで Train パルス→ status=done・val_acc=1.0
  - **CoreML Motion**(CHOP): 同梱動作モデル+円運動LFO入力→ **prob_circle=1.0**(実証モデルを流用)
  - **Cinematic Data**(CHOP): ローカル実素材で 83ch・focus_disparity 取得
  - **Cinematic Video**(TOP): 3840×2160 レンダ
  - **ImageIO Depth / PointCloud・CoreImage HDR / RAW**: op+パラメータ+説明note(実撮影素材が
    要るためnote中心)
- 例の学習データを `Assets/ml_examples/`(sample_tabular.csv / sample_motion.csv + README)に同梱。
  **.mlmodel はコミットしない**(規約通り `Assets/ml_examples/*.mlmodel` を gitignore・READMEに再生成手順)
- **CoreML Motion 例の教訓**: モデルパス不変だとCHOPが再ロードしない(ensureModelが早期return)→
  Model を空→再設定で強制リロード。入力LFOは学習の角速度と一致必須(実証済み `absTime.seconds*9`
  で prob_circle=1.0、周波数がずれると circle が wave に化ける)。MLActivityClassifier は
  4特徴合成データだと val_acc が伸びない(0.6〜0.7)ので、ライブ実証済みデータ/モデルを使う
- sample.toe 保存済み。**次回TD再起動で Coremlchop/coremldetect のゴーストは Create Dialog から消える**

### 2026-07-20 README横断調査と次期プラグイン優先順位

- ルートREADMEと全58件の利用例に対応する各READMEを再調査。主要なApple ML/メディア領域は既に広く実装済み:
  Vision姿勢・顔・手・追跡・OCR・文書・マスク、Core ML TOP/CHOP/DAT、Create ML 8タスク、
  NaturalLanguage解析、Foundation Models、翻訳、音声認識/合成/分類、Object Capture、深度点群、
  RealityKit Splat、Cinematic、VideoToolbox補間/超解像/ノイズ除去。
- 過去候補の `LanguageAnalyze` は既存 **TextAnalyze DAT**(言語/感情/固有表現/類似度)と重複、
  `ObjectCapture DAT/SOP` は既存 **RealityKit Capture SOP**、`TextToScene` は既存
  **Foundation Model DATの構造化出力**で構成可能。新規OPを増やす前に既存OP拡張/サンプル化を優先する。
- README未掲載・未追跡の `SpatialAudio/` と `SpatialMixer/` にCHOP実装ソースとbuild.shが存在する。
  前者はmono音源のHRTF 3D配置、後者は多ch bedのbinaural mix。まずビルド/TD実音検証、README、
  ルート一覧、sample.toe、常設登録を完了して正式Plugin化する。
- 次期優先順位:
  1. **Spatial Audio CHOP / Spatial Mixer CHOPの完成**(既存未完了資産、音声系の明確な穴)
  2. **Cinematic Audio Mix CHOP**(設計済み。対応Spatial Audio動画のspeech/ambience再ミックス)
  3. **Video Writer DAT**(TOP+CHOPをAVAssetWriterでHEVC/H.264/ProResへ記録)
  4. **Training Recorder DAT**(VisionPose/Hand/音声等をCreateML用recording/label付きDatasetへ収録)
  5. **Video Timeline / Export DAT**(AVMutableCompositionでカット/結合/速度/音声mix、非同期export)
  6. **Caption Author DAT**(SpeechText→SRT/WebVTT/AVCaption、動画字幕track書き出し)
  7. **AR Bridge SOP/CHOP**(既存Multipeer iOS基盤でARKit anchor/mesh/depthをMac TDへ送信)
  8. **RoomPlan SOP/DAT**(iPhone LiDARで収録したCapturedRoomの壁/開口/家具/寸法を出力)
  9. **Text Analyze拡張**(新規OPでなく、token/POS/lemmaとembedding vector出力を追加)
  10. **Foundation Model Tool Calling拡張**(TDノード読取/操作を明示的なtool schemaで接続)
  11. **FCPXML DAT**(TDの編集結果をFinal Cut Proへ受け渡すinterchange)
  12. **Spatial Video TOP/DAT**(MV-HEVC左右眼、mono/stereo変換、metadata)
- `Generated Subtitles(macOS 27)`は主にAVPlayer再生時の自動機能で、任意字幕を抽出する汎用APIでは
  ないため優先度を下げる。SceneKitはdeprecated、Model I/O単体SOPはTD標準3D I/Oと重複が大きい。

### 2026-07-20 マイナーなmacOS公開API横断調査

- 一般的なVision/Core ML/AVFoundation以外をApple公式資料で調査。TDとの相性が特に高い候補:
  1. **Core Audio Process Tap CHOP**: macOS 14.2+の`CATapDescription`/
     `AudioHardwareCreateProcessTap`で、指定アプリまたは複数プロセスの出力だけをcapture。mono/stereo
     mixdown、exclude、mute可能。現SystemAudio CHOPの画面収録ベース全体音声と明確に差別化できる。
  2. **Gameplay Agents CHOP/SOP**: `GKAgent2D/3D`、Goal、Behavior、Pathでseek/flee/avoid/separation/
     alignment/cohesionと経路追従。TDの多数インスタンス/粒子/群集制御に向く。
  3. **Gameplay Pathfind SOP**: `GKGraph`/Grid/Obstacle/MeshGraphで障害物回避最短経路をPolyline出力。
  4. **Image Capture DAT/TOP**: ImageCaptureCoreでUSBカメラのファイル/metadata/thumbnail、テザー撮影、
     スキャナのoverview scan/本scanを制御。通常のAVCapture非対応の静止画カメラ/スキャナ用途。
  5. **Core Spotlight DAT**: macOS 15+の`CSUserQuery`がアプリ独自indexに対してOS内蔵semantic search。
     macOS 27はFoundation Models用`SpotlightSearchTool`も追加。ただしMac全体の私的Spotlight indexを
     無制限に検索するAPIではなく、主に自アプリが登録したコンテンツ向け。
  6. **Quick Look TOP**: `QLThumbnailGenerator`で画像/RAW/PDF/テキスト/音声/動画など任意ファイルの
     OS標準thumbnailを非同期CGImage出力。ファイルブラウザ/メディア一覧向け。
  7. **ColorSync TOP/DAT**: ICC profile列挙・変換、display/device色特性、macOS 27 betaの
     headroom-adaptive HDR gain curve metadata。展示の複数display/projection色管理に有用。
  8. **CoreWLAN CHOP/DAT**: Wi-Fi RSSI/noise/channel/rate/interface/event。位置推定より、会場の
     無線状態可視化・品質連動演出向け。network scan/SSID情報は位置情報権限等の制限を実測確認する。
  9. **Gameplay Noise TOP/SOP**: Perlin/Billow/Ridged/Voronoi/Cylinder/Sphereの2D/3D procedural field。
     面白いがTD標準Noise TOP/SOPと重複が大きく、Apple API採用理由は弱い。
  10. **Live Photo TOP/Writer**: `PHLivePhotoEditingContext.frameProcessor`で写真+短い動画+音声を
      フレーム編集。Photos権限/asset workflowが必要。
- 補助候補: PDFKit DAT/TOP(PDF text/outline/form/annotation/render)、MapKit Snapshot TOP(地図/衛星/3D
  building)、iBeacon CHOP(CoreLocation相対近接)、IOHID CHOP(任意USB HID)、Core Haptics Out CHOP
  (Mac本体ではなく対応game controller actuator)。
- **別製品扱い**: CoreMediaIO Virtual CameraはmacOS 12.3+だが署名済みhost app+System Extension+
  App Group+管理者承認が必要。MediaExtensionの独自format reader/video decoder/RAW processorも
  ExtensionKit bundle+host appが必要。通常の`.plugin`単体では配布できない。
- 非推奨/注意: SensorKitはMacの一般センサー取得APIではない。Mac内蔵ambient light等のprivate APIは
  使用しない。Core HapticsはMac本体のTaptic Trackpadを汎用振動器として制御できず、主にcontroller用。

### 2026-07-20 ImageCaptureCoreテザー撮影・ライブビュー調査

- ImageCaptureCoreにはメーカー/機種の固定compatibility listがなく、接続後の
  `ICCameraDevice.capabilities`で機能を判定する。リモートシャッターは
  `ICCameraDeviceCanTakePicture`、本体シャッター併用は
  `ICCameraDeviceCanTakePictureUsingShutterReleaseOnCamera`、PTP pass-throughは
  `ICCameraDeviceCanAcceptPTPCommands`を見る。PTP対応でもremote capture対応とは限らない。
- 公開標準機能: device/file/folder列挙、metadata/thumbnail、部分read/download/delete、battery、clock sync、
  `requestTakePicture`による静止画capture、新規ファイルevent→自動download。macOS 14以降は標準take
  picture対応cameraでtetheringが既定有効となり、旧`requestEnableTethering`はdeprecated/no-op。
- **ImageCaptureCoreに汎用live-view/viewfinder frame stream APIはない**。`requestSendPTPCommand`は可能だが、
  live viewは多くがCanon/Nikon/Sony固有PTP opcode/data formatであり、メーカー別実装・対応表・SDK規約が必要。
- リアルタイムpreviewの堅実な経路:
  1. cameraのUSB webcam/UVC mode→AVFoundation/TD Video Device In
  2. clean HDMI→capture card→TD Video Device In
  3. Canon EDSDK / Sony Camera Remote SDK / Nikon Camera Remote SDK(MAID)でEVF/live-view取得
  4. ImageCaptureCore標準のみなら、撮影→生成file event→thumbnail/full image downloadの低速プレビュー
- Pluginを作るならv1はブランド非依存の**still tether**に限定し、起動時に実機capability tableをDAT出力。
  Live Viewは`Backend: UVC / Canon / Sony / Nikon`の別TOPまたは後続版にする。メーカーSDKバイナリは
  ライセンス確認なしにrepoへ同梱しない。検証対象cameraの正確な型番・firmware・USB modeをREADMEに残す。

### 2026-07-20 Sony α7 Camera Remote SDK対応調査

- 2026-07-20時点の公式Camera Remote SDK最新は **Ver.2.02.00(2026-06-10)**、macOS 14.1/15.1/26、
  USB・有線LAN・Wi-Fi(実際のphysical layerは機種別)。Apple Silicon対応macOS SDKあり。
- 公式対応α7系: `ILCE-7RM6 / 7RM5 / 7RM4A / 7RM4 / 7CR / 7SM3 / 7M5 / 7M4 /
  7CM2 / 7C`。**α7/II/III、α7R/RII/RIII、α7S/SIIはCamera Remote SDK非対応**。Imaging Edge
  Webcam/Mobileの対応表はより広いが、Camera Remote SDK対応を意味しない。
- 共通中心機能: device connect/disconnect、live-view frame取得、remote shutter/AF、静止画/動画操作、
  exposure/ISO/aperture/shutter/WB等property get/set、状態/event、撮影file transfer、複数台制御。
  個々のproperty・接続方式はSDK同梱Function list/API listとruntime support確認を正とする。
- 公開release noteから確定する主な差:
  - **α7 IV**: Wi-Fi、約100設定拡張、full remote、remote control+file transfer同時、optical zoom absolute、
    exposure通知timing、動画menu/TC/UB、camera内data delete。TD統合の第一検証機に最適。
  - **α7R V**: full remote、exposure通知timing、動画menu/TC/UB、処理高速化。高解像still向け。
  - **α7S III**: Wi-Fi、約100設定拡張、camera内data delete、動画/RAW出力色域property変更注意。
  - **α7CR / α7C II**: focus absolute position、focal length、interval/AF追従等、camera内delete。
    firmware更新後にfocus position値の再calibrationが必要。
  - **α7R IV/IVA / α7C**: 初期世代SDKのbasic remote/live view/capture/file transfer中心。
  - **α7 V / α7R VI**: Ver.2.01/2.02で新規追加。詳細差は登録後の最新版API listで確認する。
- Sony公式SDKは無償・商用販売可だが、日本ページでは**個人へ提供不可**、利用/商用は法人の許諾申請が
  必要。したがってrepoへSDK dylib/headerを直接commitせず、ユーザー取得SDKをbuild時に指定する設計。
  OSS公開可能部分とSony binary dependent backendを分離する。firmwareとSDK versionの組合せも固定記録する。

### 2026-07-20 FUJIFILM Camera Control SDK対応調査

- 公式名は **FUJIFILM X Series and GFX System Digital Camera Control SDK**。現行公開は
  Ver.1.34(2025-11-12)、macOS 10.12〜26、USBとTCP/IP(Wi-Fi AP経由)対応。画像自動転送と
  compatible cameraのbasic remote controlsを提供。RAF RAW現像APIは含まれない。
- 公式対応機種(2026-07-20): X-M5、X-T3、X-T4、X-Pro3、X-S10(FW 2.00+)、X-H2S、X-H2、
  X-T5、X-S20、GFX 50S/50R/100/100S/50S II/100 II/100S II/100RF、GFX ETERNA 55。
  X-T2以前、X-T30系、X-T50、X100系等は現行SDK一覧にない。Webcam/XApp対応とSDK対応を混同しない。
- SDKで期待できる中心機能: connect、camera information/status、live-view/preview、remote shutter、
  recording control、exposure parameters(Shutter/Aperture/ISO/EV)、WB等の基本property、focus drive、
  撮影fileの自動transfer。実際のproperty writable/readable差はmodel/FWごとにSDK header/runtime確認。
- TDでは`Fujifilm Camera TOP`(live view)、CHOP(property/status)、DAT(device/property/file events)に分離し、
  SDK dylib/headerをrepoへ含めず`FUJIFILM_SDK_PATH`からbuildする方式が妥当。高品質映像はSDK preview
  ではなくHDMI capture併用を推奨。
- **重大な契約注意**: 個人向けEULA/公式ページは、SDKで接続・制御した対応cameraがメーカー限定保証の
  対象外になると明記。利用前にユーザーへ明示し、検証機の保証状態を確認する。SDKはroyalty-freeで、
  Libraryは自作systemへobject codeとして組み込んで顧客配布可能だが、GPL/LGPL等のOSS条件をSDKへ
  課すことは禁止。TDAppleML本体のlicenseと分離し、SDK backendはoptional binary componentにする。

### 2026-07-20 LAN内デバイス・hostname・IP列挙API調査

- Apple公開APIで堅実なのは **Network.framework Bonjour (`NWBrowser`)** または低レベル
  **dns_sd (`DNSServiceBrowse/Resolve/GetAddrInfo`)**。Bonjour service instance→service type→hostname/port→
  IPv4/IPv6/TXTを取得できる。同一hostの複数serviceをhostname/addressでmergeしてDAT化する。
- `_services._dns-sd._udp.local.`をqueryすればadvertised service type自体を列挙し、その各typeをbrowse可能。
  ただしarbitrary/all Bonjour type browseはmulticast entitlementが必要になる場合があり、通常は
  `_ssh._tcp`、`_http._tcp`、`_osc._udp`、`_airplay._tcp`等を明示する方が安全。
- **BonjourはLAN全端末一覧ではない**。serviceをadvertiseしないcamera、IoT、Windows、sleeping device、
  firewall越し/VLAN越しのhostは見えない。CoreWLANはAP/SSID/RSSIを扱うが接続client一覧は取れない。
- 全IPv4 host探索のApple高レベルAPIはない。`getifaddrs`でinterface/subnetを得て、Network.frameworkの
  bounded TCP probe、ICMP/ARP、reverse DNS/mDNSを組み合わせるactive scanが必要。hostnameはPTR/mDNSが
  無ければ得られない。IPv6全域scanはaddress space的に不可。routerのDHCP lease/client listも標準APIなし。
- Plugin案は **Network Discovery DAT**:
  - Mode `Bonjour`(既定、安全) / `Active IPv4 Scan`(明示pulse)
  - columns: device/hostname/ip4/ip6/interface/service/type/port/txt/latency/last_seen/source
  - service TTL/removed eventを反映、重複host merge、scan concurrency/rate/timeoutを制限
  - `NSLocalNetworkUsageDescription`と`NSBonjourServices`が必要。macOSのLocal Network許可は
    TouchDesigner本体がresponsible processとなる可能性があるため、.plugin単体でInfo.plistを足して解決
    できるか実機検証する。必要なら署名host/helper app方式。

### 2026-07-20 空間音響4プラグイン実装(Spatial Audio / Spatial Mixer / PHASE / Audio Mix)

ユーザー指定の空間音響4件を実装。全て純ObjC++(Swiftヘルパ不要)・M2実機検証。

- **Spatial Audio CHOP**(`Spatialaudio`・AVAudioEnvironmentNode): モノ音源を3D配置しHRTF
  バイノーラルでTDに戻す。manual rendering(offline)+ AVAudioSourceNode。実測: 方位-90°で
  rmsL/R=1.67、+90°で0.64(定位反転)
- **Spatial Mixer CHOP**(`Spatialmixer`): 多chサラウンドを各ch標準スピーカー位置のmono sourceとして
  envでバイノーラル化。実測: ステレオ(左大/右小)でL/R=1.14。AUSpatialMixer('3dem')の多ch生設定は
  manual renderで不安定(segfault)だったため env+positioned source に変更
- **PHASE CHOP**(`Phase`): Apple PHASEで物理ベース空間化してデバイス(ヘッドホン)へ再生。
  **PHASEは出力バッファ取得APIが無くTDに音を戻せない**ため再生モデル。PullStreamNodeの
  renderBlock(リアルタイムスレッド)へロックフリーSPSCリングバッファでcookから供給。実測:
  playing=1/buffered=8820/rendering=1(稼働・デバイス再生)。ドライ入力はパススルー
- **Audio Mix CHOP**(`Audiomix`・AUAudioMix 'amix'・macOS26): 空間音声のspeech/ambience分離。
  実測: input_ch=4/output_ch=5/renders>0。**'amix'は4ch First-Order Ambisonics(layoutTag 0x930004)
  入力専用・出力5ch**で、標準ステレオは-10868拒否。AU自身のinputBusses[0].formatでconnect。
  合成入力は無音で、実分離には4chアンビソニックス素材が必要(未入手のため実分離は未検証)

- **踏んだ罠(pitfalls.md反映)**: ①**オーディオフィルタCHOPは timeslice=true**。入力と異なるch数を
  出すなら `getOutputInfo` で **true+numChannels明示**が必須(falseだと出力が入力=モノ1chに一致し
  `channels[1]`書き込みが範囲外で**TD即クラッシュ**・実際に踏んで修正)。②AVAudioSourceNodeは
  AVAudio3DMixing準拠でposition/HRTF直接設定可。③多音源は音源ごと独立read position(共有だとプル順で
  壊れる)。④AUSpatialMixer多ch生設定はsegfault。⑤AUAudioMixは4ch FOA専用。⑥PHASEはデバイス出力専用
- 4件ともビルド・署名・インストール・TD再起動後の生成/実データ検証済み。README(各+ルート英日)更新
- 検証中にTDが1度クラッシュ(上記①のバグ)→ 修正版で再検証しクラッシュ再現せず
- 次にやること: PHASEのEarly/Late Reverbの実聴、Audio Mixの4chアンビソニックス実素材での分離検証、
  sample.toe への利用例追加

### 2026-07-20 有力12プラグイン(その1): Gameplay Agents/Path・Quick Look・PDF実装

ユーザー指定の有力12件を優先度順に実装開始。第1バッチ4件(実データ検証済み)。

- **Gameplay Agents CHOP**(`Gameplayagents`・GameplayKit): GKAgent2D群をGKGoal(seek/separate/
  align/cohere/avoid/wander/reach-speed)で駆動する群集シミュ。agent{i}/x,y,vx,vy,angle出力。障害物は
  任意入力CHOP(x,y,radius)。実測: 30体・目標seekで速度(2.92,0.70)の群れ挙動
- **Gameplay Path SOP**(`Gameplaypath`): GKObstacleGraphで始点→終点の障害物回避経路をLine出力。
  障害物は入力SOPの点を多角形化。実測: 原点障害物を迂回する(-4,0)→(0,1.42)→(4,0)
- **Quick Look TOP**(`Quicklook`・QuickLookThumbnailing): 任意ファイルのOS標準サムネイル→BGRA8。
  実測: PDF→198x256サムネイル
- **PDF Document DAT+TOP**(`Pdfdocument`・PDFKit・1フォルダ2バンドル): DAT=構造(Info/Outline/
  Text/Annotations)、TOP=ページ描画。実測: 2ページPDFでpages=2・テキスト抽出・850x1100描画

- **踏んだ罠**: ①**GKPolygonObstacleはCCW巻き順**が正しい(CWは全遮蔽で経路0・harnessで確定)。
  半径が小さく頂点が始点終点線分上に乗ると迂回しないことがある。②SIMD `vector_float2` の `.x/.y` を
  `emplace_back` へ直接渡すと"non-const reference cannot bind"→ float に展開してから渡す。
  ③std::vector<vector_float2> 要素への compound literal 代入も同様に注意
- 4件(5バンドル)ビルド・署名・インストール・TD再起動後の実データ検証済み。README+ルート一覧(英日)更新
- **TD再起動は自分で実施**(quit→open→MCP疎通待ち)。MCPサーバは起動後1〜2分立ち上がりに要することあり
- 残り: #1 Process Audio、#6 ColorSync、#5 Semantic Index、#7 WiFi Monitor、#4 Image Capture、
  #11 HID、#10 Beacon、#12 Live Photo

### 2026-07-20 有力12(その2): WiFi Monitor CHOP・ColorSync TOP

- **WiFi Monitor CHOP**(`Wifimonitor`・CoreWLAN): 接続中Wi-FiのRSSI/noise/SNR/tx_rate/channel/
  tx_power/PHYを数値出力、SSID/BSSID/interface/securityをInfo DAT。実測: rssi=-41/noise=-93/snr=52/
  tx_rate=400Mbps/channel=120。**SSID/BSSIDは最近のmacOSでLocation権限が要る**(無いと空・数値は取れる)。
  `connected`はchannel関連付け(またはrssi≠0)で判定
- **ColorSync TOP**(`Colorsync`・CoreGraphics/ICC): 入力TOPをsRGB/Display P3/Adobe RGB/Rec.2020/
  Generic/Gray/任意.icc間で色空間変換。CGColorSpace(ColorSync管理)のCGImage描画で変換。実測:
  sRGB(0.9,0.1,0.1)→P3(0.824,0.208,0.165)で成分値が正しく変化
- 罠: Info DAT の `getInfoDATSize` は **bool返し**(getNumInfoDATSizeは無い)
- 2件ビルド・署名・インストール・TD検証済み(自分で再起動)。README+ルート一覧(英日)更新
- 残り: #1 Process Audio、#5 Semantic Index、#4 Image Capture、#11 HID、#10 Beacon、#12 Live Photo

### 2026-07-20 有力12(その3): Process Audio CHOP(Core Audio Process Tap)

- **Process Audio CHOP**(`Processaudio`・Core Audio Process Tap・macOS 14.4+): システム全体または
  指定プロセス(PID)の音声だけをタップ→48kHz stereo CHOP。IOProc(RTスレッド)→SPSCリング→timeslice出力。
  実測: Global で `say` 連続音声中に peak=0.535 捕捉(TD内で確認)
- **踏んだ罠(pitfalls反映)**: ①**オーディオ出力CHOPは getOutputInfo で sampleRate=48000 必須**
  (未設定だと60Hz扱いでnsamp=12の「音でない」出力)。②`initStereoGlobalTapButExcludeProcesses:` に
  自プロセス(TD)を渡すと捕捉0になる→Exclude既定Off。③リング溢れ時はread→write-nへ追いつかせる。
  ④ヘッダは CATapDescription.h と AudioHardwareTapping.h を明示import。⑤検証は実フレームcook+連続音源
  (強制cookは実時間が進まずr.drainできず無音区間に当たる)
- ビルド・署名・インストール・TD検証済み(自分で再起動)。README+ルート一覧(英日)更新
- 残り: #4 Image Capture、#11 HID、#10 Beacon、#12 Live Photo(ハード/素材/権限依存)

### 2026-07-20 有力12(その4・完): HID / Semantic Index / Image Capture / Beacon / Live Photo

指定12件の残り5件を実装。ハード/権限/素材依存が主でロード+構造検証、Semantic Indexは実データ検証。

- **HID CHOP**(`Hid`・IOHIDManager): 任意HIDのraw入力を要素値CHOPに。バックグラウンドrun loopで値変化
  受信。**入力監視(Input Monitoring)TCC権限**が要る(未許可だと要素0)
- **Semantic Index DAT**(`Semanticindex`・NSMetadataQuery): OS全体のSpotlightファイル検索。実測:
  Query=README で15件・first=README.ja.md。**CoreSpotlight CSUserQueryは不採用**(アプリ索引/
  エンタイトルメント必須でプラグイン文脈0件)。**startQueryはメインキューにdispatch必須**(cookスレッド
  直呼びだと通知が発火しない)
- **Image Capture DAT**(`Imagecapture`・ICDeviceBrowser): テザーカメラ/スキャナ列挙。要実機
- **Beacon CHOP**(`Beacon`・CoreLocation): iBeacon測距(macOS10.15+)。要Location権限+実ビーコン
- **Live Photo TOP**(`Livephoto`・Photos/PHLivePhoto): Live Photoの動画コンポーネントの任意時刻フレーム。
  要実素材(image+video)。CoreMediaリンク必須
- 5件ビルド・署名・インストール・TD再起動後にロード/エラーなし確認(自分で再起動)。全12件完了
- **これで指定12プラグイン全て完了**。README(各+ルート英日)更新。commit/push

### 2026-07-20 最近16件をApple標準フレームワーク名へリネーム(ユーザー指示)

- ユーザー「Pluginの名前はなるべくApple標準のフレームワーク名になぞって」を受け、既存の
  「Framework Feature」規約に合わせて**11件をリネーム**(opLabel/opType/opIcon/フォルダ/ソース.mm/
  build.sh/README/ルート一覧/バンドル名):
  Process Audio→**CoreAudio Tap**、Gameplay Agents→**GameplayKit Agents**、Gameplay Path→
  **GameplayKit Path**、WiFi Monitor→**CoreWLAN**、PDF Document→**PDFKit**、Beacon→
  **CoreLocation Beacon**、HID→**IOHID**、Semantic Index→**Spotlight**、Audio Mix→
  **AudioToolbox Mix**、Spatial Audio→**AVAudio Spatial**、Spatial Mixer→**AVAudio Mixer**
- **維持**(既にApple標準名): PHASE / ColorSync / Quick Look / Image Capture / Live Photo
- git mv でフォルダ・ソースを改名、sed で opType/opLabel/クラス名を一括置換。12バンドル再ビルド・
  常設Pluginsの旧12バンドル削除+新12設置。TD再起動後に全12型が新opTypeで生成できることを確認
- **踏んだ罠**: ①**opType==opLabel が同一文字列(Beacon)だと sed が opLabel も巻き込む**→手動修正。
  ②**opIcon の sed で "HID"→"IOHID"(5文字)になり3文字ルール違反でTDがロード拒否**(IOHIDが未登録に)
  →"IOH"へ修正。opIconは英字3文字厳守。③12バンドル入れ替え直後の初回起動はプラグイン再検証で
  ロードが数分かかる(2回目はキャッシュで通常速度。固まったら強制終了→再起動でよい)
- sample.toe の examples は旧opType参照だった16件を含まない(利用例未追加)ため参照切れ無し
- 次にやること: リネーム16件の sample.toe 利用例追加(任意)

### 2026-07-20 実素材でLive Photo検証(ユーザー追加素材)

- ユーザーが実素材を追加(Assets/LIVE_Photo_sample/・spatial_video_sample.MOV・gs_sample.ply/NGSP。
  いずれも大きくgitignore)。これらで未検証プラグインを実データ検証:
- **Live Photo TOP**: 実Live Photoペアで t=0.5 のフレームを **1308×1744 抽出**・duration=2.93s・
  中央ピクセル非ゼロの実画像を確認。フレームアクセス(全フレーム)が機能。`is_live_photo` は
  ペアリング識別子依存で、抽出ファイルでは0になった(抽出自体は識別子非依存で動く)→READMEに明記
- **AudioToolbox Mix**: spatial_video の音声は **AACステレオ**で 4ch First-Order Ambisonics ではないため
  検証不可(FOA素材が必要)。**RealityKit Splat**: gs_sample は **NGSP独自形式**・.ply は生3DGS で
  USD/USDZ ではないため直接ロード不可(USDZ変換が要る)。両者は素材待ちのまま

### 2026-07-20 Gaussian Splat SOP実装(3DGS .ply→TD点群)

- ユーザー「変換して進めて、変換もpluginからできると尚良い」を受け、gs_sample.ply(3DGS)をTDに取り込む
  経路を検証:
  - **RealityKit RealityRenderer は点群(UsdGeomPoints)を描画しない**(実測: 点群USDはロードされ
    loaded=1 だが出力は黒 nonbg=0)。**3DGS .ply → splat USDZ の公開変換APIは無し**(ModelIOは3DGSの
    62プロパティで "Corrupt position attribute" となり空USDに)。SDKに gaussian/splat シンボルも無し
  - → **Gaussian Splat SOP** を新規実装。3DGS .ply(x,y,z,nx,ny,nz,f_dc_*(45+3),opacity,scale_*,rot_*・
    stride 62 float)を**自前パース**し、位置+Cd(SH DCから色)+pscale(exp(scale))+opacity(sigmoid)を
    TDの点群SOPに。ヘッダのプロパティ名でオフセットを動的解決。ワーカースレッドでパース(cook非ブロック)
  - **実測(M2)**: 369085頂点91MBを Maxpoints=150000 で **184543点**にパース。Cdは点ごとに実データ
    (pt0=(0.58,0.47,0.44)等)、opacity/pscaleも点属性。TDがネイティブに色付き点群描画
- 真のガウシアン(異方性カーネル)描画は splat入りUSDZ + macOS26 RealityKit のsplat USDスキーマ待ち
  (未公開)。当面は点群可視化で実用
- README(新規+ルート英日)更新。TD再起動後に184543点の実splatパースを確認。commit/push
- **踏んだ罠**: RealityRendererはメッシュは描くが点群は描かない。3DGS .plyはModelIO/RealityKitとも
  直読み不可。SOPのCd/pscale等は per-point の setCustomAttribute(Color配列はfloat*にキャスト)

### 2026-07-20 Gaussian Splat調査の結論 + Gaussian Splat SOP / RealityKit Splat を削除

Gaussian Splat の TD 取り込みを実機(macOS 26.4 / Xcode 26.4)で徹底調査した結論と、暫定実装の撤去。

**調査の確定事実:**
- **公開splat API `GaussianSplatComponent` は macOS 27.0(現在ベータ)** で追加(iOS/iPadOS/Mac Catalyst/
  visionOS も 27.0 beta)。Apple公式ドキュメントJSONで確認。26.4 SDKには未存在
  (https://developer.apple.com/documentation/realitykit/gaussiansplatcomponent)
- `GaussianSplatComponent(_:)` + `splatResource: GaussianSplatResource`。**「フレームワークはファイルを
  直接ロードしない。PLY/USDは自前パースしてバッファ(LowLevelBuffer)を埋める」**とドキュメント明記
  → 3DGS .plyパーサ(旧Gaussian Splat SOPのもの)が将来そのまま流用可能
- macOS 26.4時点: 公開API無し / RealityRenderer(オフスクリーン)はsplatも点群も**描画しない**(黒・実測) /
  USDスキーマ `UsdSplatsPreliminary_GaussianSplatsAPI`(Preliminary=実験的)+ private `Vista.framework`
  (`VSTSplatProxyRenderer`)+ private `CorePhotogrammetry`(`CPGEnvironmentGSSession*`・splat学習Metal
  カーネル)は在るが、**公開API・RCP 2.0・Object Captureアプリのいずれからも露出していない**
- `CPGGaussian3DLoadFromURL` はINRIA .plyを拒否(Apple独自フォーマット専用)。CorePhotogrammetryの
  splat生成はCVPixelBuffer+カメラ内外パラメータのフルSfM+GS private pipelineで、ヘッダ無し盲目再構成は非現実的
- **splat USDサンプルファイルは本機に一切存在しない**(Xcode/RCP同梱含む)

**撤去:**
- 暫定実装だった **Gaussian Splat SOP(`Gaussiansplat`)** と **RealityKit Splat TOP(`Realitykitsplat`)** を
  ユーザー判断で削除(フォルダ git rm・常設バンドル削除・ルートREADME英日から除去・sample.toeの
  RealityKitSplat例と残存Gaussiansplat1ノードを除去して保存)
- 理由: 26.4ではRealityKit Splatは真のsplat描画不可(RealityRenderer非対応)、Gaussian Splat SOPは
  点群可視化止まり。**macOS 27で `GaussianSplatComponent` が公開されたら、.plyパーサ+同コンポーネントで
  作り直す**方針(足場は本ログに記録)

**次にやること(macOS 27で):** `GaussianSplatComponent`+`GaussianSplatResource` を使い、.ply/USDを自前
パースしてバッファ投入 → RealityKit Splat TOP を真のsplat描画で再実装。オフスクリーンRealityRendererで
描けるかは27で要検証(不可ならオンスクリーン→Syphon等)

### 2026-07-20 プラグインのファイル名をopLabel規則へ統一(CoreMLDetect / Cinematic)

opLabelとソース/フォルダ/バンドル名がずれていたものを監査して修正(opType・opLabelは不変)。

- **CoreMLDetect → CoreMLDAT**: opLabel統一で「CoreML」になった際に旧機能名"Detect"が
  ファイル/フォルダ/バンドルに残っていた。`CoreMLDetect/CoreMLDetectDAT.mm` →
  `CoreMLDAT/CoreMLDAT.mm`(git mv・クラス名/build.sh/README/ルートREADMEリンク更新)。
  これでCoreML三兄弟がCoreMLTOP.mm / CoreMLCHOP.mm / CoreMLDAT.mm と揃い、常設バンドルも
  CoreMLTOP/CoreMLCHOP/CoreMLDAT.plugin(+ImageGen/Motion/SAM2)で統一
- **Cinematic の2ソースをラベルに合わせて改称**: Multipeer In/Out の先例(ファイル名=各opの
  ラベル)に倣い、`CinematicCHOP.mm`(opLabel "Cinematic Data")→ `CinematicDataCHOP.mm`、
  `CinematicTOP.mm`(opLabel "Cinematic Video")→ `CinematicVideoTOP.mm`。フォルダは共有の
  `Cinematic/`、opTypeも共有の`Cinematic`のまま。バンドルも CinematicDataCHOP/CinematicVideoTOP に
- **Phase は変更しない**(参考): opLabel "PHASE"(Apple表記の頭字語)だが、opTypeは規則上
  全大文字にできず`Phase`。フォルダ/ファイル`Phase`/`PhaseCHOP.mm`はopType準拠で正しい
- opTypeを変えていないため sample.toe の既存 examples は無傷。3型を再起動後にcreateして
  errs=0・opType不変(Coreml/Cinematic)を確認。examples/CoreMLDetect コンテナのみ
  CoreMLDAT へ改名して保存(Cinematic例は既にCinematicData/CinematicVideoで一致)
- 旧バンドル(CoreMLDetectDAT/CinematicCHOP/CinematicTOP.plugin)を削除し新名で再インストール・
  署名検証OK。TD再起動で反映済み

### 2026-07-20 5件実装(TextAnalyze拡張 / Training Recorder / Caption Author / FM Tool Calling / Spatial Video)

ユーザー指定の5件を実装。全てM2実機・TD MCPで実データ検証済み。

- **TextAnalyze DAT 拡張**(既存OP): `Output` メニュー(summary/tokens/embedding)を追加。
  tokens=`index/token/pos/lemma/start/length`(NLTagSchemeLexicalClass + Lemma。init に全スキーム
  列挙必須の罠を踏襲)、embedding=文埋め込みベクトルを `index/value` 数値列(NLEmbedding
  sentence→NLContextualEmbedding フォールバック)。実測: "visited"→Verb/lemma=visit、英文で512次元
- **Training Recorder CHOP**(新規・`Trainingrecorder`): 入力CHOP時系列を CreateML Activity 用
  CSV(`recording,label,<feat...>`・1行=1フレーム)へ収録。DATはCHOP入力を受けられないので**CHOP**が
  正。Record区間=1収録、Save/停止で確定・追記、session tag付きrecording IDで衝突回避。実測:
  noise3ch を wave/circle で収録→2 recordings・正しいヘッダのCSVを生成(CreateMLがそのまま読める)
- **Caption Author DAT**(新規・`Captionauthor`): 文字起こし/字幕テーブル→SRT/WebVTT整形+ファイル
  書き出し。start/end列があれば使用、無ければ Default Duration で自動連番(SpeechTextの
  index/text/final をそのまま字幕化)。`Only Finalized Rows` で volatile 行除外。出力は setText。
  実測: SRT/VTT(ドット区切り)/自動連番 いずれも正しく生成
- **Foundation Model Tool Calling 拡張**(既存OP+helper): FoundationModels の `Tool` プロトコルを
  動的スキーマ(`Arguments=GeneratedContent`・`parameters:GenerationSchema`)で実装。**ツール実行を
  ホスト(TD)へ委譲**する往復: LLMがツール呼び出し→helperが `withCheckedContinuation` で停止し
  `pending_tool`/`pending_tool_args` を poll に出す→TDが `Tool Result` を書いて `Return Tool Result`
  →`fm_tool_result` が継続を再開。実測: `get_sensor({"name":"temperature"})` 要求→TDが
  `{"value":42}` 返す→**"The current temperature in the show is 42 degrees Celsius."** と回答
- **Spatial Video DAT/TOP**(新規・`Spatialvideo`・1フォルダ2バンドル・純ObjC++): MV-HEVC 空間ビデオ。
  DAT=メタデータ(CMFormatDescription拡張: HasLeft/Right/HeroEye/StereoCameraBaseline/
  HorizontalFieldOfView/HorizontalDisparityAdjustment)。TOP=`AVAssetReaderTrackOutput` に
  `kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs=[0,1]` を要求し、`CMTaggedBufferGroup` の
  `kCMTagCategory_VideoLayerID` で左右眼を分離→Left/Right/Side-by-Side BGRA出力。
  実測(実iPhone空間ビデオ Assets/spatial_video_sample.MOV): 1920×1080・is_spatial=1・
  baseline 19.255mm・FOV 63.4°、左眼中央px[0.122,0.122,0.137]≠右眼[0.141,0.161,0.161](視差確認)

- 5件ともビルド・署名・常設インストール・TD再起動後の実データ検証済み。README(各+ルート英日)更新
- 検証用TDノード(_v_*)とテストCSVは削除済み

### 新規ハマりどころ(上記で発見)

- **FoundationModels の動的ツールは `Tool.Arguments=GeneratedContent`+`parameters:GenerationSchema`**
  (`DynamicGenerationSchema`から構築)。`call(arguments:)` で `arguments.jsonString` が引数JSON。
  `Output:PromptRepresentable` は String でOK。ホスト実行の往復は `withCheckedContinuation` を
  helper側に保持し、C ABI(`fm_tool_result`)で resume する(pending は poll JSON で公開)
- **MV-HEVC両眼デコードは `AVAssetReaderTrackOutput.outputSettings` に
  `AVVideoDecompressionPropertiesKey → kVTDecompressionPropertyKey_RequestedMVHEVCVideoLayerIDs`**。
  各 CMSampleBuffer は `CMSampleBufferGetTaggedBufferGroup` で取り、`CMTagCollectionGetTagsWithCategory
  (…kCMTagCategory_VideoLayerID)` + `CMTagGetSInt64Value` でレイヤーID(0=左/1=右)を判定して
  `CMTaggedBufferGroupGetCVPixelBufferAtIndex` で各眼を取る
- **StereoCameraBaseline は micrometers・HorizontalFieldOfView は thousandths of a degree**(CFNumber)
- **Training Recorder は CHOP**(DATはCHOP入力不可)。CreateML Activity CSV は `recording`/`label` 列名が
  CreateMLHelper の既定と一致している必要がある(recordingで系列化)

### 2026-07-20 2件リネーム(Training Recorder→CreateML Training Recorder / Foundation Model→AFM Core)+ Network Discovery DAT

- **Training Recorder → CreateML Training Recorder**(ユーザー指示「CreateMLとセットで使うと分かる名前に」):
  opType `Trainingrecorder`→`Createmltrainingrecorder`、opLabel「CreateML Training Recorder」、icon TRN→CTR。
  フォルダ/ソース/build.sh/README/ルートREADME/バンドルを改名(git mv)
- **Foundation Model → AFM Core**(ユーザー指示「FoundationModelは一般的すぎる。Apple Foundation Models の
  ローカル版なので AFM Core に」): opType `Foundationmodel`→`Afmcore`、opLabel「AFM Core」、icon FDM→AFM。
  フォルダ FoundationModel→AFMCore、ソース FoundationModelDAT.mm→AFMCoreDAT.mm。**Swiftヘルパ(module
  FMHelper・dylib libFMHelper・C ABI fm_)は内部保持**(build.sh は NAME/ソース/plist識別子のみ置換)
- 2件とも再ビルド・旧バンドル削除・新バンドル設置。TD再起動後に `Createmltrainingrecorder` /
  `Afmcore` が errs=0 で生成できることを確認
- **注意**: opType変更で sample.toe の旧参照(examples の Foundationmodel、fm_structured_demo)は
  TD再起動後にロードエラー。次に examples 更新時に Afmcore へ貼り直す(ユーザーは.toe破損許容済み)

- **Network Discovery DAT**(新規・`Networkdiscovery`・icon NWD): Bonjour(NSNetServiceBrowser)で
  LAN内サービスを発見し `service_type/name/hostname/ip4/ip6/port/txt` を出力。Service Types を複数同時
  ブラウズ、resolve で host/IP/port/TXT を取得
  - **踏んだ罠①**: NSNetServiceBrowser は**ランループ駆動**。cook スレッド任せでは**コールバックが
    全く発火せず結果0**。**専用スレッド+常駐ランループ**(NSMachPort でランループを生かす=ビジー
    ループ防止)でブラウズする
  - **踏んだ罠②(TDクラッシュ)**: 専用スレッド版で cook から `performSelector:onThread:` で設定を
    渡した初版が **EXC_BAD_ACCESS でTDクラッシュ**(faultingは別スレッドのPython param binding=
    ヒープ破壊の疑い)。**cross-thread performSelector を全廃**し、cook は設定を `@synchronized` で
    **保留キューに積むだけ**、browserスレッドが自分のループ内で保留設定を適用する polled 方式に変更。
    NSNetServiceBrowser/NSNetService の生成・破棄・列挙は**全て browserスレッド上**に限定し、cook 側は
    `@synchronized` スナップショット(NSDictionary配列=不変)を読むだけ、で解決
  - Local Network 権限(責任プロセスはTD本体)が要る。全端末一覧ではなく広告サービスのみ見える。
    Active IPv4 Scan は将来
  - **実測**: `_airplay/_raop/_googlecast` で **10サービス発見**、hostname/ip4(192.168.49.10)/
    ip6/port(7000)/TXT(at=4;model=…)まで resolve。TD安定(クラッシュ再現せず)
  - README(新規+ルート英日)更新

### 新規ハマりどころ(Network Discovery で発見)

- **Bonjour(NSNetServiceBrowser/NSNetService)は必ず専用スレッド+常駐ランループで回す**。
  cookスレッド任せだとコールバックが発火しない。さらに **cook→browserスレッドへ
  `performSelector:onThread:` で状態を渡すのは危険**(TDでEXC_BAD_ACCESSを実際に踏んだ)。
  設定は `@synchronized` の保留キューに積み、browserスレッドが自分で適用する polled 方式にする。
  Bonjourオブジェクトの生成/破棄/列挙は browserスレッドに一極集中させ、cookは不変スナップショットを読むだけにする
