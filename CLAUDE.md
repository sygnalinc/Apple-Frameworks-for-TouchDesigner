# CLAUDE.md — TDAppleOps 開発ガイド(AIエージェント向け)

> リポジトリは 2026-07-20 に `TDAppleML`→`TDAppleOps`、2026-08-07 に一般公開へ向け
> **`Apple-Frameworks-for-TouchDesigner`**(表示名 "Apple Frameworks for TouchDesigner")へ改称。
> 旧GitHub URLは自動リダイレクトされる。コード内のキャッシュパス `~/Library/Caches/TDAppleML/`
> と過去ログの旧名は互換性・履歴保持のため据え置き。ローカル作業フォルダ名は `TDAppleML` のままでも可。

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
- **Custom OPからのPythonコールバック+ノード自動生成**(実例: CoreWLANScan):
  `customOPInfo.pythonCallbacksDAT` に stub をセットすると Customページに「Callbacks DAT」+
  Addボタンが付く。C++からは `context->createArgumentsTuple` + `callPythonCallback` で発火し、
  コールバック内の Python で隣にノードを自動生成できる(二重生成ガードを入れる)。
  **Callbacks DAT 自体も初回cookの `PyRun_String` で自動生成・接続できる**(配置だけで全自動)。
  罠: ①`OP_NodeInfo::opPath` は空のことがある→ `createArgumentsTuple` の args[0](自ノード
  PyObject)を `__main__` に渡して参照 ②生成直後はカスタムパラメータ未生成で失敗→成功を
  読み戻して毎cookリトライ ③PyRunの `__main__` に op/textDAT は無い→ `import td` で明示。
  ビルドは Python.h(TD同梱3.11)+ `-undefined dynamic_lookup`
- **自動生成DATはGLSL風ドックチップにできる**: `d.dock = n` + `d.expose = True` +
  `d.viewer = True` + **`d.showDocked = False`** で「閉じた↓チップ」(CoreWLANScanの既定)。
  **チップの↑開/↓閉の実体は showDocked**(expose/viewer は無関係・実機の全プロパティ差分で特定)。
  `expose=False` は見た目が「×」チップになるので通常使わない。ドック後の nodeX/Y は無効。
  詳細は skill の pitfalls.md「Python コールバック」節

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
- **TDのダイアログは computer-use で自分でクリックして対応する**(プラグイン追加/再インストール後の
  読み込み確認、再起動時の "Save changes?" 等)。放置するとTD操作が止まる。TD再起動は
  quit→screenshotでダイアログ確認→クリック→open。保存ダイアログはコミット済み.toeを正とし、
  UI状態だけの軽微差分は "Don't Save"、MCPで意図的に保存した未保存内容があれば "Save"

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
| Gemma | Gemma | Google Gemma 4を明示。llama.cppローカルサーバー接続のDAT |
| Translate | Translate | Translation |
| CoreML ImageGen | Coremlimagegen | **外部Core MLモデル専用**(SD/SDXL/Turbo。CoreML系=外部モデルのルール) |
| ImagePlayground | Imageplayground | Apple Image Playground(ImageCreator)。外部モデル不要で別op |

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

### 2026-07-20 ImageIO Depth TOP → ImageIO File In TOP(Color表示・EXIF向き補正を追加)

ユーザー要望「TDでHEIFを表示できない/depthも色も出したい/汎用画像ファイルopに/縦写真が横倒し」を実装。

- **リネーム**: ImageIODepth → **ImageIOFileIn**(opType `Imageiofilein`・label "ImageIO File In"・icon IFI)。
  フォルダ/ソース/build.sh/README/ルートREADME/バンドルを改名(git mv)
- **Color 表示を追加**(Data Type メニュー先頭・既定): 主画像を `CGImageSourceCreateImageAtIndex`→
  BGRA8 出力。**TDのMovie File Inが開けないHEIF/HEICを表示できる代替**になった
- **EXIF Orientation(1〜8)を適用**して正立化。汎用リマップ関数 `applyOrientation`(4byte/px)で
  color(BGRA)も depth(float)も同じ経路で回転/反転。iPhone縦写真は横センサー+**Orientation=6**で
  保存され、旧depthは横倒しだった → 補正で解消
- Info CHOP に `has_disparity/has_depth/has_matte/width/height` を追加(画像に含まれるデータが分かる)
- **実測(実iPhoneポートレートHEIC IMG_2540.HEIC・raw 4032×3024・Orientation=6・disparity内蔵)**:
  Color=**3024×4032 正立ポートレート**を視認確認(横倒し解消)、Disparity=576×768 正立の深度マップを視認。
  `.save()`でPNG化しReadで目視検証(color=被写体正立・logo可読、depth=手前明/奥暗で正しい向き)
- sample.toe の examples/ImageIODepth → **ImageIOFileIn**(Color・実HEIC)へ更新して保存
- **ドラッグ&ドロップでカスタムOP生成は不可**: `OP_CustomOPInfo` にファイル拡張子登録フィールドが
  無く(SDK確認済み)、TDのファイルドロップ→op生成割り当てはTD内部仕様でカスタム.pluginに割り当て
  できない。HEIFドロップは標準の Movie File In が作られる。回避は本OPを手動作成 or DAT Execute で
  moviefilein 生成を監視して差し替える運用(READMEに明記)

### 新規ハマりどころ

- **EXIF Orientation を適用しないとiPhone縦写真は横倒し**(raw横センサー+Orientation=6)。
  `kCGImagePropertyOrientation` を読み、8種を汎用ピクセルリマップで正立化する。color/depth 共通経路にできる
- **カスタム.pluginはファイルのドラッグ&ドロップ生成に割り当てられない**(OP_CustomOPInfoに拡張子欄なし)

### 2026-07-20 ImageIO File In の Color 向きバグ修正(decodeColorが上下逆でEXIF回転が破綻)

ユーザー実機で Color 表示が「IMG_2540(Orientation=6)=左右反転 / IMG_E2540(Orientation=1)=上下反転」と判明。
- **原因**: `decodeColor` が `CGContextTranslateCTM(0,H)+ScaleCTM(1,-1)` で**bottom-upバッファ**を作っていた。
  深度側 `loadAux` は top-down なので、同じ `applyOrientation` を掛けると color だけ縦が逆になり、
  EXIF Orientation の回転が鏡像/上下逆に化けていた
- **修正**: decodeColor の反転を撤去し、CGBitmapContext の描画結果(=loadAuxと同じ縦向き)を
  そのまま使う。これで color/depth が同一経路(top-down → applyOrientation → TOP行反転)になり整合
- **検証(offline PNG化 + TD .save を Read で目視)**: 全8向き候補を生成し Preview と突合。
  修正後、IMG_2540(orient=6)・IMG_E2540(orient=1)とも **Color が正立でPreview一致**、
  Disparity も同じ正立(白箱=左/銀箱=右)を確認。TD実機の .save 出力もPreview一致
- **教訓**: EXIF Orientation を手動リマップするなら、色と補助データの**縦向き(top-down/bottom-up)を
  必ず一致させてから**同じ変換を掛ける。片方だけ反転していると回転が鏡像化する(pitfalls反映)

### 2026-07-20 ImageIO PointCloud も EXIF向き対応(横倒し修正)

ユーザー指摘「PointCloudも向きがおかしい」。ImageIO File In と同根で **EXIF Orientation 未適用**。
- **修正**: 深度(loadDepth)・色(RGBデコード)・カメラ内部パラメータ の3つに Orientation を適用。
  - 深度/色は共通 `applyOrientation`(4byte/px)で回転
  - 内部パラメータは `orientIntrinsics`: 90°回転で **fx↔fy 入替え**+**主点(cx,cy)を順写像**。
    FOV近似時は向き適用後の dW から再計算
- **Flip Vertically の既定を On→Off に変更**: 向き適用後は画像上端を 3D上(+Y)へ写すのが正立。
  旧既定On(pos.y=Y)だと画像上端が3D下になり**上下反転**していた(実測で確認)
- **検証**: IMG_2540(orient=6)で Geo+Camera+Render の点群レンダをPNG化しPreviewと突合。
  修正後 **白箱=左/銀箱=右・正立(机が手前下)** を視認。Applyorientation=1・Flip=0 が正
- README(パラメータにApply EXIF Orientation追加・Flip既定Off)更新

### 2026-07-20 Cinematic Video の depth 向き修正(disparityにpreferredTransform未適用)

ユーザー指摘「Cinematic Video は color 正しいが depth が上下左右両方逆(=180°)」。
- **原因**: Rendered(color)は `CNRenderingSession(preferredTransform: info.preferredTransform)` で
  **preferredTransform を適用**して正立。一方 depth は disparityトラックを生読みするため**変換未適用**。
  実測: IMG_2531.MOV の video/disparity 両トラックの preferredTransform は **a=-1,b=0,c=0,d=-1 = 180°**。
  そのため depth だけ 180° ずれていた
- **修正**: cn_open で `info.preferredTransform` から回転角(atan2(b,a))を求め `CNState.rotDeg` に保存。
  disparityToFloat に `rotateDisparity`(0/90/180/270の汎用リマップ)を追加し、生disparityへ回転を適用して
  render と表示向きを揃える(その後に既存のTD用上下反転)。90/270は次元入替えにも対応
- **検証**: IMG_2531.MOV(180°)で depth/color を並べて .save→Read で目視。修正後、**depthの猫(近い=明)が
  color と同じ中央下・背景キッチン(遠い=暗)が上** で一致(180°ズレ解消)
- README更新。90/270素材は未入手のため 180 のみ実測(汎用実装済み)

### 2026-07-20 PDFKit TOP の上下逆を修正

- PDFの `drawWithBox:toContext:` は **PDF座標(左下原点=bottom-up)** で描くため、TD表示で上下逆だった
- 描画後にバッファを**行反転**してからアップロード(ImageIO File In と同じ TD 縦向き対応)
- 検証: 上=赤/下=青のテストPDFを描画し、TDで**赤が上・青が下**の正立を視認

### 2026-07-20 System Audio 削除 + CA Tap → CA Process Tap リネーム

- **System Audio CHOP を削除**(ユーザー判断)。ScreenCaptureKit ベースのシステム音声取得は
  CoreAudio Process Tap(CA Process Tap)と機能重複し、画面収録権限も要るため。
  フォルダ git rm・常設バンドル削除・ルートREADME英日から除去・sample.toe の examples/SystemAudio 削除
- **CoreAudio Tap の opLabel を "CA Tap" → "CA Process Tap"**(表示名のみ。opType `Coreaudiotap`・
  フォルダ・ファイルは不変=sample.toe無傷)。リビルド・再インストール済み

### 2026-07-20 Live Photo 削除 + Screen Capture のウインドウ名プルダウン化

- **Live Photo TOP を削除**(ユーザー判断)。フォルダ git rm・常設バンドル削除・ルートREADME英日から除去
- **Screen Capture の window 選択を「ウインドウ名の動的プルダウン」に**:
  - `appendDynamicStringMenu` + `buildDynamicMenu` で「アプリ名 - タイトル」を列挙。内部値は
    **ウインドウID(安定)**で選択(一覧順が変わってもズレない)
  - ウインドウ一覧は非同期(SCShareableContent)でキャッシュ。生成時 / Restart / 約120cook毎に更新
  - start は選択windowIDに一致するSCWindowを使用(無ければ Display Index にフォールバック)
  - **踏んだ罠**: `appendDynamicStringMenu` は **defaultValue が空文字だと append 失敗**し、
    パラメータが生成されない(Active/Mode等は出るのに Window だけ出ない現象)。
    公式サンプル同様、**非空の defaultValue("0")** を設定して解決
  - **実測**: window モードで **40ウインドウ**を列挙(Chrome/ChatGPT/プレビュー等)、
    選択したウインドウを 1235x831 で取り込み(警告なし)を確認
  - 検証中の MCP 切断は TD/MCP の一時不安定(クラッシュレポート無し・TDは稼働継続)

### 2026-07-20 Screen Capture: コントロールセンター等をウインドウ一覧から除外

- ウインドウ列挙に **`windowLayer==0` フィルタ**(通常アプリ窓のみ)+ `com.apple.controlcenter`
  バンドル除外を追加。メニューバー/オーバーレイ系(コントロールセンター等)がプルダウンから消える
- 実測: フィルタ前40件 → **11件**(Chrome/ChatGPT/TouchDesigner/Claude/Finder 等の実窓のみ)、
  コントロールセンター項目=0

### 2026-07-20 AFM Core Tool Calling デモを sample.toe に追加

- `/project1/afm_tool_demo`: sensor(constant CHOP: temperature=42/humidity=58)→ afm(AFM Core・
  Enable Tool Calling・Tool=get_sensor(name:string))+ handler(DAT Execute)+ note
- handler の onTableChange が `pending_tool_args` を検知→sensor CHOPを名前引き→Tool Result に
  JSONを書いて Return Tool Result をパルス(ツール往復を自動化)
- **実測**: Prompt「現在のtemperatureは?」→ LLMが get_sensor を要求→handlerが42を返す→
  **"The current temperature is 42.0 degrees Celsius."**。sensorを15に変えると回答も15.0に追従
  (=LLMがライブTD値を読んでいることを確認)

### 2026-07-20 「TOP→自然文キャプション」デモを sample.toe に追加(Vision Classify → AFM Core)

- `/project1/afm_describe_demo`: src(Movie File In: Assets/test_image_1.jpg)→
  classify(Vision Classify: 内容タグ)→ driver(Execute DAT onFrameEnd)→ afm(AFM Core)
- driver は毎フレーム afm を cook(LLM生成をポーリング)し、classify のタグが変わったら
  タグからプロンプトを組んで Submit。afm が1文キャプションを生成。状態は parent().store('lasttags')
- Apple公開オンデバイスAPIに画像キャプションは無い(Vision=分類/OCR/検出のみ、FoundationModels=
  テキスト専用)ため、**Vision Classify(ラベル)→ AFM Core(文章化)** の連携で実現
- **実測**: test_image_1.jpg → タグ `people, adult, crowd, outdoor, sky, cloudy` →
  **"A group of people is gathered under a cloudy sky in an outdoor space."**
- **踏んだ罠**: 非同期C++ DAT(Vision Classify)の更新は datexecuteDAT の onTableChange が
  安定して発火しない。**executeDAT の onFrameEnd で毎フレーム駆動**する方が確実

### 2026-07-21 SpeechSynth CHOP のノイズ修正(timeslice=false→true)

- ユーザー報告「SpeechSynth がノイズ」。原因は **オーディオ生成系CHOP なのに `timeslice=false`+固定
  `Blocksamples` 出力**していたこと。60fps で毎フレーム固定1024サンプル消費 → 22.05kHz音声を実時間の
  約2.8倍速で読み出し=早送りノイズになっていた
- 修正: `getGeneralInfo` を `timeslice=true`、execute のループ上限を `myBlock`→`out->numSamples`
  (TDが実時間×sampleRateから算出したサンプル数)。これで実時間ペースで再生される
- **検証**: SpeechSynth→Audio File Out で WAV 実録し解析。22050Hz・**非無音2.94秒の連続発話**
  (発話1回ぶんの正しい長さ)、peak0.289/rms0.027、**ZCR=0.188(ノイズは~0.5)/energy CoV=0.61
  (動的=発話)** で「speech-like」判定。早送りノイズ解消を確認
- 教訓(pitfalls既出の補強): **音声を生成して出すCHOPは timeslice=true + out->numSamples**。
  固定ブロック(timeslice=false)は再生速度が実時間とズレてノイズ化する

### 2026-07-21 MobileCLIP(apple/coreml-mobileclip)DL + zero-shot interrogate デモ追加

- **Apple公式 Core ML版 MobileCLIP** をDL: `apple/coreml-mobileclip`(HF)から S0 の image/text
  エンコーダ `.mlpackage` を `models/`(gitignore)へ。image 23MB / text 96MB
  - I/O(protoで確認): image= 256x256画像 → `final_emb_1`[1,512]、text= [1,77]int32トークン → [1,512]
- **テキスト埋め込みバンクを事前計算**(TDでテキストを回すにはトークナイザが要るため):
  - 純Python の CLIP BPE トークナイザ(`bpe_simple_vocab_16e6.txt.gz`)で36概念を77トークン化
  - Swift Core ML CLI で text エンコーダを実行 → L2正規化した512次元を `Assets/mobileclip_text_bank.csv`
    (175KB・コミットする)へ。※coremltools 9はPython3.14でネイティブlib不可→**Swiftで実行**が確実
- **デモ `/project1/clip_interrogate_demo`**: src(TOP)→ clip(CoreML CHOP: MobileCLIP-S0 image・512次元)
  → rank(Script DAT: 画像埋め込みと各テキスト埋め込みのコサイン類似度で並べ替え top-8)
- **実測(discriminative確認)**: 群衆画像 → 「a crowd at an event/a crowd of people/people」上位、
  動物動画 → 「a cat/an animal」上位。画像内容を正しく識別(トークナイザ/両エンコーダ/ランキングが正しい)
- **踏んだ罠**: ①Script DAT のスクリプトは inline 不可 → callbacks に Text DAT を指定。
  ②File In DAT は CSV を1セルで読む(表化しない)→ **rank スクリプトで CSV を直接 open/parse** が確実。
  ③CoreML CHOP は初回 ANE コンパイルで数秒 valid=0 → 数秒後に valid=1/count=512
- モデル本体は規約通り**コミットしない**(models/ gitignore)。テキストバンクCSVのみ同梱(画像モデルを
  DLすれば動く)。再生成: bpe_simple_vocab → tok.py → textemb.swift(scratchpadに残す)

### 2026-07-21 MLX LLM DAT実装(Apple MLXでGemma 4等のローカルLLM)

- ユーザー「Gemma 4をローカルで動かしたい→MLX LLM opを作る方針」。Apple **MLX**(mlx-swift-lm)で
  任意の mlx-community モデル(Gemma 4 / Qwen / Llama)を完全オンデバイス実行する **MLX LLM DAT**
  (opType `Mlxllm`・icon MLX)を新規実装。AFM Core(Apple Intelligence固定モデル)と違い任意モデルを選択
- **アーキテクチャ: ヘルパ実行ファイルを別プロセスで spawn**(dylib同梱ではない)。DAT は
  posix_spawn + pipe + reader thread で **JSON-lines プロトコル**通信(load/gen/reset/quit →
  progress/ready/token/done/error)。cook非ブロック、トークンを会話テーブルへストリーミング。
  多GBモデル+Metalをプロセス隔離しTDを巻き込まない、停止でメモリ解放
- **最大の地雷: mlx-swift の Metal(default.metallib)は `swift build` で作れない**(公式README明記)。
  `swift build` 版は実行時 `Failed to load the default metallib` で生成に到達せず。
  → **xcodebuild でビルド**: `xcodebuild build -scheme MLXLLMHelper -configuration Release
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .xcbuild -skipPackagePluginValidation
  -skipMacroValidation`。**`-skipPackagePluginValidation` 必須**(mlx-swiftのCudaBuildプラグインが
  対話承認を要求しBUILD FAILED)。metallibは `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`
  に生成。実行ファイルは静的リンク=同梱は実行ファイル+Cmlxバンドル(metallib)+Hubバンドルを隣に置くだけ
- mlx-swift-lm は huggingface/transformers を内製化(MLXHuggingFace+マクロ)。ただしマクロが
  `HuggingFace.HubClient`/`Tokenizers.AutoTokenizer` に展開されるので**消費側も swift-huggingface +
  swift-transformers に依存**が必要。API: `#huggingFaceLoadModelContainer(configuration:
  ModelConfiguration(id:)){progress}` → `ChatSession(container, instructions:, generateParameters:)`
  → `streamResponse(to:)`(AsyncThrowingStreamでトークン)
- **実測(M2)**: `mlx-community/gemma-4-e2b-it-4bit`(3.3GB)。単体CLI・TD内とも生成成功。
  TDで Load→ready(progress 100)、Submit で「Name one primary color」→**"Red"**、続けて
  「別の色」→**"Blue"**(マルチターン文脈保持)。2文(~35token)を約1秒=インタラクティブ速度
- ビルド・署名・`~/Library/.../Plugins/` インストール・**TD再起動後にロード/生成を実機確認**。
  helperは quarantine xattr無し(ローカルビルド)でGatekeeper非ブロック。sample.toe の
  `/project1/examples/MLXLLM` に利用例を追加。README(新規+ルート英日)更新。Package.resolvedをコミット、
  .build/.xcbuild とモデルは gitignore
- 次にやること: 大きめモデル(Qwen/Llama)での速度比較、Stop/中断、TOP画像キャプション用に
  MLX VLM(将来)、AFM Core同様のTool Calling拡張

### 2026-07-21 MLX LLM をローカルディレクトリ対応(完全オフライン実行)

- ユーザー「modelフォルダに gemma-4-e2b-it-4bit をDLしてローカルだけで実行して」。
  HFキャッシュから `models/gemma-4-e2b-it-4bit/`(config/tokenizer/model.safetensors 等・3.3GB・
  gitignore)へコピー
- ヘルパに `makeConfig()` を追加: Model 文字列が**存在するディレクトリなら
  `ModelConfiguration(directory:)`**、そうでなければ従来通り HF リポジトリID。
  mlx-swift-lm の `resolve()` は `.directory` を **downloader非経由**で扱う(ソース確認済み)ため
  ネットワーク一切なしでロード
- **オフライン厳密検証**: HFキャッシュを一時退避 + `HF_HUB_OFFLINE=1` で `models/` から
  ロード→生成成功("Blue")。TD実機でも例の Model を `project.folder + '/models/gemma-4-e2b-it-4bit'`
  エクスペッション(.toe位置に追従)にして Load→ready→Submit→**"Hello!"** を確認
- sample.toe の `/project1/examples/MLXLLM` を更新(ローカルパス+オフライン説明)。README更新
- リビルド(xcodebuild・incremental)・署名・インストール・TD再起動で反映済み

### 2026-07-21 ローカルファイル参照デモを sample.toe に追加

- `/project1/mlx_local_demo`: MLX LLM DAT がローカルの `models/gemma-4-e2b-it-4bit` を
  参照して完全オフライン実行するデモ。構成 = `mlx`(MLX LLM DAT・Model=
  `project.folder + '/models/gemma-4-e2b-it-4bit'`)+ `info`(status)+ `response`(Text TOP・
  最新assistant行を表示)+ `note`(手順)
- 実測: Load(ローカルからDL無しで ready)→ Submit → **"I am Gemma 4, a Large Language Model
  developed by Google DeepMind."** を生成し response TOP に表示。sample.toe 保存済み

### 2026-07-21 MLX LLM に画像入力(VLM・マルチモーダル)を統合

- ユーザー「既存 MLX LLM DAT に画像入力あり/なしを統合」。`MLXVLM` を追加リンクし、DAT に
  **Image TOP パラメータ + Use Image トグル(Visionページ)** を追加。Submit時に指定TOPを
  downloadTexture(BGRA8/verticalFlip)→ ImageIOで一時PNG化 → helperへ image パスを渡し、
  `session.streamResponse(to:images:[.url(path)])` で VLM に投入
- **自動LLM/VLM判別**: mlx-swift-lm の `load()` は ModelFactoryRegistry を VLM→LLM の順で試す。
  MLXVLM をリンクすれば同じ `#huggingFaceLoadModelContainer` が VLMモデルを自動ロード
- **踏んだ罠(重要)**:
  1. **`import MLXVLM` だけだと dead-strip されて VLM factory が登録されない**
     (`NSClassFromString("MLXVLM.TrampolineModelFactory")` が nil)。**`_ = VLMModelFactory.shared`
     で明示参照**してリンクを強制する(nmで 6MLXVLM…Trampoline シンボルの有無を確認)
  2. **`gemma-4-e2b-it-4bit` は VLMとしてロードできない**(この量子化repoの重みキーが
     mlx-swift-lm 3.31.4 の Gemma4 VLM 実装と不一致 = `keyNotFound(language_model.model.layers…)`)。
     自動でテキストLLMにフォールバックし画像は無視される。**画像は Qwen2-VL 等を使う**
  3. **DATはTOPをワイヤ入力できない**(DAT入力はDAT)。**TOPパラメータ(appendTOP/getParTOP)**で参照する
  4. 低temp+短maxだと稀に1トークン("A")で早期停止する(サンプリング挙動)。temp 0.5+/max 128+ で安定
- **実測(M2・完全オフライン)**: `models/Qwen2-VL-2B-Instruct-4bit`(HFからDL→models/へコピー・
  1.2GB・gitignore)。TD実機で img TOP(群衆写真)→ **群衆・Pokémonイベントを認識し看板を OCR**
  ("WELCOME, TRAINERS!" / "May 29 - June 1" / "TOKYO")。sample.toe に `/project1/mlx_vision_demo`
  (img→mlx(Use Image)→response TOP)を追加
- build.sh に CoreGraphics/ImageIO を追加。README(画像入力・モデル互換性)更新。リビルド・
  署名・インストール・TD再起動で実機確認済み

### 2026-07-21 LLM系OPの表示名を統一(AFM Core→LLM AFM / MLX LLM→LLM MLX)

- ユーザー「LLM関連のopは名前を統一したい」。**opLabel のみ変更**(opType据え置き)で
  AFM Core→**"LLM AFM"**、MLX LLM→**"LLM MLX"**。opType(`Afmcore`/`Mlxllm`)・opIcon(AFM/MLX)・
  フォルダ・ファイルは不変なので、既存デモ(afm_tool_demo / afm_describe_demo / mlx_local_demo /
  mlx_vision_demo)は参照切れせずそのまま動く(「CA Process Tap」と同じ opLabel-only 方針)
- 両プラグインをリビルド・署名・インストール。ルートREADME(英日)一覧の表示名と各README見出しを更新
- 注意: opType未変更のため OP Create Dialog では "LLM AFM"/"LLM MLX" と表示され、生成される
  ノード型は従来通り Afmcore/Mlxllm

### 2026-07-21 CoreML ImageGen を外部モデル専用化 + Image Playground を別opに分離

- ユーザー「CoreML ImageGen は StableDiffusion 等の外部モデル専用に。Image Playground は
  単一の別opに。CoreML関係は外部モデルを使うというルールに統一」
- **CoreML ImageGen**(`Coremlimagegen`・TOP): Backend/Style メニューと Image Playground
  (`pg_*` C ABI・PGSession・igCGImageToRGBA・`import ImagePlayground`)を**全削除**し、
  **ml-stable-diffusion(外部Core MLモデル)専用**に。Model Folder / Steps / Guidance / Seed /
  img2img はそのまま。opType/opLabel/icon 不変(既存 examples/CoreMLImageGen は無傷)
- **ImagePlayground**(`Imageplayground`・opLabel "ImagePlayground"・icon IPG・TOP・新規):
  ImageCreator(macOS 15.4+・**外部モデル不要**)でテキスト+スタイル生成。Swiftヘルパは
  SPM不要の素の swiftc dylib(`libPlaygroundHelper`・pg_ プレフィックス・`-framework
  ImagePlayground`)。Style(animation/illustration/sketch)/Prompt/Generate/Flip
- 両方ビルド・署名・インストール。CoreMLImageGenのバイナリから Backend/playground 文字列が
  消えたこと、ImagePlayground が Imageplayground/ImagePlayground で登録されることを strings で確認
- README(CoreMLImageGen改訂・ImagePlayground新規・ルート英日一覧にImagePlayground追加)更新
- 注意: 本セッションは TouchDesigner MCP 切断中のため TD実機の生成検証は未実施
  (ビルド/インストール/バイナリ確認まで)。TD再起動で `Imageplayground` が Create Dialog に出る。
  ImagePlaygroundの利用例は sample.toe に未追加(MCP復帰後のTODO)

### 2026-07-21 VisionFlow 動作確認(黒画面は仕様) + IOHID / QuickLook 削除

- ユーザー「VisionFlowが黒画面しか見えない」→ **プラグインは正常**。スタンドアロンの Vision
  テスト(2フレームで物体を+30px移動)で `VNGenerateOpticalFlowRequest` を実行し、**最大フロー
  ≈23px・動いた領域でdxが負**(動き検出・方向とも正しい)を実測確認。黒く見える原因は
  ①**入力が静止**(静止画は1フレームしか来ずフロー未計算=常時黒 / 動画でも動きが無ければ0=黒)
  ②**UVモード既定は解像度で正規化=値が極小**(肉眼で黒。Math TOPで×20〜50増幅、または
  Pixelsモード、+0.5オフセットで可視化)。VisionFlow README に「黒い画面に見えるとき」節を追記
- **IOHID / QuickLook を削除**(ユーザー判断「使い所が分からない」)。リポジトリの `IOHID/`
  `QuickLook/` を git rm、常設バンドル `IOHIDCHOP.plugin`/`QuickLookTOP.plugin` を削除、
  ルートREADME(英日)の該当行を削除
- 注意: 本セッションは TouchDesigner MCP 切断中。sample.toe に IOHID/QuickLook の利用例
  コンテナがあれば TD再起動後に "Unknown operator type"(赤)になる。MCP復帰後に examples の
  該当2コンテナを削除する(.toe破損許容済み)。VisionFlowの可視化デモ追加もMCP復帰後のTODO

### 2026-07-21 ImagePlayground に顔ソース画像入力を追加(人物生成対応)

- ユーザー「ImagePlaygroundで人物を生成すると『Provide a source image containing a person's
  face』と出る」→ Apple仕様(人物はテキストのみ不可)。**入力0に顔画像TOPを接続**して
  `ImagePlaygroundConcept.image(CGImage)` として渡す対応を追加
- **helper**: `pg_generate` に sourceRGBA/w/h を追加、`igRGBAToCGImage`(データコピー)で CGImage 化し
  concepts に `.image(source)` を先頭追加。**TOP**: maxInputs 0→1、Generate時に入力0を
  downloadTexture(RGBA8/verticalFlip)して渡す
- **検証(スタンドアロン)**: `ImagePlaygroundConcept.image(face)+.text(prompt)` で
  「provide source image」エラーは解消(=顔concept経路に入る)。ただし**ImageCreator生成は
  前面GUIアプリ内でしか動かず、ヘッドレスCLIは `backgroundCreationForbidden`**(=TDでは動くが
  ターミナル検証は不可)。API経路・ビルド・入力配線は確認済み
- README(入力0=顔・「人物を生成する」手順・backgroundCreationForbidden注意)更新。インストール済み
- **新ハマりどころ**: ImagePlaygroundのImageCreator生成は**前面GUIアプリ限定**。
  ヘッドレス/バックグラウンドは `backgroundCreationForbidden` で拒否される
- 注意: 本セッションMCP切断中のためTD実機での人物生成検証は未実施(次回TODO)

### 2026-07-21 TDダイアログのclick対応を標準化 + README/CLAUDE.md最新化

- ユーザー「TDのプラグイン追加時・終了時のダイアログも自分でクリックして対応して」→ 標準運用化。
  computer-use(request_access→screenshot→left_click)でダイアログを処理する。memory
  (feedback: handle-td-dialogs-via-clicking)と本CLAUDE.mdの検証の作法に反映
- README(英日)を最新化して監査: 削除済みop(IOHID/QuickLook/System Audio/Live Photo/Music/
  Gaussian Splat/RealityKit Splat)の残存参照なし、ハードコードのop数なし、を確認。
  ImagePlayground行に「人物は入力0に顔画像」を追記
- **現状の主要な棚卸し(2026-07-21時点)**:
  - LLM系: LLM AFM(Afmcore)/ LLM MLX(Mlxllm・任意mlx-communityモデル+VLM画像入力)/ Gemma(llama.cpp)
  - 生成系: CoreML ImageGen(外部SDモデル専用)/ ImagePlayground(ImageCreator・顔入力で人物可)
  - 直近削除: IOHID, QuickLook(使い所不明)
  - VisionFlowは正常(黒画面は静止入力orUV正規化で値が小さいため。READMEに可視化手順)

### 2026-07-21 全プラグイン opHelpURL付与 + authorName統一 + VisionFlow可視化モード

- **authorName → "SYGNAL Inc."** 全81プラグイン統一(旧 TDAppleML/sygnal 混在)。会社名で表示。
  codesignは会社名にできず現状ad-hoc維持(要 Developer ID 法人証明書)。gitコミット作者は個人のまま
- **opHelpURL 追加**(全81): `FillXXXPluginInfo` に `https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/
  blob/main/<Folder>/README.md` を **null ガード付き**で。OPの Help(`?`)ボタンから README が開く。
  **OP Create Dialog のホバー説明は SDK に該当フィールドが無く不可**(opHelpURL が代替)
- **VisionFlow に Output メニュー追加**: `flow`(生RG32Float・従来) / `visualize`(RGBA8カラー・
  向き=色相/速さ=明るさ/フレーム最大で自動スケール)。**増幅ノード無しで動きがそのまま見える**
  (黒画面問題の恒久対策)。実映像2フレームで非ゼロフロー(max2.78px・6.1%可動)を可視化検証済み
- 全プラグイン リビルド+再インストール(75/76自動+Gemmaは build.sh の実行ビット欠落で手動)。
  バイナリで SYGNAL Inc./opHelpURL/visualize を確認。81 bundle インストール済み
- **新ハマりどころ**: `opHelpURL` は構造体で `=nullptr` 既定。TDが未確保でも安全なよう
  `if(x.opHelpURL) x.opHelpURL->setString(...)` とガードする。opIcon等はTDが確保するがopHelpURLは要確認

### 2026-07-21 opLabel↔opType 全op整合 + folder規約統一 + Gemma削除

- ユーザー「opLabelとopTypeはなるべく揃えて。Folderも基本opLabelだがCI/CAは展開して」
- **opType=opLabel(スペース除去)** に統一(0不一致): CI×6(Cibokeh等)/ GameKit×2 /
  CA Process Tap(Caprocesstap)/ LLM AFM(Llmafm)/ LLM MLX(Llmmlx)/ Cinematic Data・Video
- **folder=opLabel(CI/CA展開)**: CoreAudioTap→CoreAudioProcessTap / AFMCore→LLMAFM /
  MLXLLM→LLMMLX / Multipeer→MultipeerDAT(CoreML同様 family接尾)。CI/GameKitのフォルダは
  展開済(CoreImage…/GameplayKit…)で維持。ファイル・バンドルも新フォルダ名に追従
- **Gemma op 削除**(役割重複)。三層命名ルールを skill/naming.md に明文化
- 影響: opType変更13件で sample.toe の examples/デモが赤(Unknown operator type)。**MCP復帰後に
  新opTypeで貼り直し必要**(ユーザー .toe破損許容済み)。ops_catalog/README(英日)は更新済み
- LLMMLX は folder移動で .xcbuild を消してフルリビルド(mlx-swift C++再コンパイル・十数分)

### 2026-07-21 sample.toe 修復 + TD MCPをHTTP直送で駆動(重要テクニック)

- opType改名で参照切れになった sample.toe の16ノードを新opTypeへ貼り替え(examples CI×6 /
  Cinematic×2 / LLM×2 と afm_*/mlx_* デモ)。パラメータ・配線を保持し、例ノードは`<NewOpType>1`、
  例コンテナ AFMCore/MLXLLM→LLMAFM/LLMMLX に改名。全ノード0エラーで保存
- **重要: touchdesigner MCP クライアントがセッション未登録でも、TD内の `td_mcp_server` の
  HTTPエンドポイントに直接JSON-RPCを投げて駆動できる**([[td-mcp-http-direct]] にメモ):
  - TDのリスニングポートを `lsof -nP -iTCP -sTCP:LISTEN -p <tdpid>` で調べる(今回 9988)
  - エンドポイントは `http://127.0.0.1:<port>/mcp`。`initialize`→`notifications/initialized`→
    `tools/call`(run/create/set/wire等)を JSON-RPC で送る。session id は初期化応答の
    `Mcp-Session-Id` ヘッダを以降のリクエストに付ける
  - scratchpad の `tdmcp.py`(最小HTTPクライアント)で `run(python)` を実行した
- **ノードのopType付け替え手順**: 旧ノードの parent/name/pos/color/入出力接続/customパラメータを退避
  → 新opTypeで create → `new.copyParameters(old)`(同名paramは値/式ごとコピー)→ inputConnectors/
  outputConnectors で配線再接続 → old.destroy → 新を旧名にrename。これで .toe を新opTypeに移行できる
- ゴースト注意: 旧opTypeは実行中TDのメモリに残る(Create Dialogに出る)が、新opTypeのみ参照する
  .toeを保存すれば次回クリーン再起動で消える

### 2026-07-21 セットop統合(Cinematic Data / Spatial Video DAT / PDFKit DAT を各TOPへ吸収)

- ユーザー「GLSL TOPの様に設置で相方も生成できないか?できるなら他もまとめて」→ SDK調査の結論:
  **OP_CustomOPInfo に設置時の別ノード自動生成フックは無い**(実ヘッダ確認。pythonCallbacksDAT は
  Callbacks DAT**パラメータ**追加のみ。GLSL TOPのドックDATはTD内部の組み込み専用挙動)。
  代替は **①Info CHOP/Info DATへの統合(TD標準流儀・Movie File Inと同じ)②palette .tox**
- ユーザー指示で3ペアを統合(補助op削除):
  - **Cinematic Data CHOP → Cinematic Video TOP の Info CHOP**: 診断5ch+`focus_disparity/
    focus_strong/subjects`+`subject{i}/8ch`(Max Subjects par追加・cn_meta呼び出しはworkerに
    直列化)。**ついでにPosition(0..1)を秒として渡していた潜在バグを pos×duration に修正**
    (旧TOPは全尺スクラブ不可だった)
  - **Spatial Video DAT → Spatial Video TOP**: 数値(baseline_mm/FOV/is_spatial等13ch)は
    Info CHOP、全key/value(codec/hero_eye含む)は Info DAT。メタ解析はファイル変更時にworkerで
  - **PDFKit DAT → PDFKit TOP の Info DAT**: `Info DAT Mode` par(Info/Outline/Text/Annotations)
    追加。テーブルはworkerが構築したキャッシュを getInfoDATSize/Entries が返す。Textモードは
    行ごと(line/text)の表形式に変更。Page parは描画とText/Annotationsで共用
- 3フォルダとも build.sh を1バンドル化、旧バンドル(CinematicDataCHOP/SpatialVideoDAT/
  PDFKitDAT.plugin)を常設Pluginsから削除。**PDFKit/Multipeer以外で「1フォルダ2バンドル」は解消**
- **実測(M2・実素材)**: Cinematic=IMG_2531で duration 17.26s/focus_disparity 2.049/被写体2
  スロット取得、Spatial=19.255mm基線/63.4°FOV/disparity_adjustment 200 を Info CHOP+DAT両方で、
  PDF=自作 `Assets/sample_doc.pdf`(コミット済み15KB)で pages/title/Text行分割/Annotations(none)
  と 1275×1650 描画。3例(CinematicVideo/SpatialVideo/PDFKit=新設)を sample.toe に反映・
  全ノード0エラーで保存
- **罠**: ①稼働中TDでの検証ノード編集中にTDが落ち、**未保存のsample.toe編集が消えた**(保存は
  こまめに)。②cp -R したバンドルが codesign verify 失敗(sealed resource invalid)→ コピー後に
  再署名で解決。③Info DATの内容はop本体のcook+worker完了後に反映(パラメータ変更→即読みは旧値)
- 注意: 旧opType(Cinematicdata/Spatialvideo DAT/Pdfkit DAT)を参照する.toeはロードエラーになる。
  sample.toeは修復済み。catalog 80→77op。README(各+ルート英日)更新

### 2026-07-22 Network Discovery に「全デバイス検出」(Active IPv4 Scan)を追加

- ユーザー「ネットワークのデバイスを全て検出できるように」。従来はBonjour(広告サービス)のみ
  だったので、**アクティブIPv4スキャンを追加**して Bonjour非対応機器も含めLAN全機器を拾えるように
- **仕組み(特権不要)**: サブネット内の各ホストへ 1byte UDP を投げる→カーネルが送信前に **ARP解決**
  →応答した機器だけ ARPエントリが complete(MACあり)になる→`sysctl(CTL_NET,PF_ROUTE,NET_RT_FLAGS)`
  で ARPテーブルを読む(=`arp -an` 相当)。ICMPも raw socket も不要。逆引きは `getnameinfo`(DNS/mDNS)。
  **全IPv4探索の高レベル Apple API は無い**のでこの方式が現実的(既存調査どおり)
- **Mode: Bonjour / Active IPv4 scan / Both(既定)**。Bothは同一IPをBonjourサービスとARP結果で
  マージ(Bonjour行にMAC補完・`source=bonjour+arp`)、ARPのみの機器は別行。出力列に **mac / source** 追加、
  ip4昇順ソート。スキャンは専用ワーカースレッド(cook非ブロック・一回スイープ、Rescan/設定変更/初回で起動)
- **実測(M2・自宅LAN 192.168.49.0/24)**: **20機器**検出。Bonjour非広告の機器(ルータ/各種端末)が
  MAC付きで並び、AppleTV/FireTV(.21)は複数Bonjour行に同一MAC補完、自Mac(.16)も _raop+MACでマージ。
  スタンドアロンharnessで先にARP読取を検証(18機器)→TD実機でも同数+Bonjour。エラー/警告なし
- **踏んだ罠**: ①ARPテーブルにサブネットブロードキャスト(.255・MAC全ff)が載る→`iph==bcast` と
  `mac=="ff:ff:ff:ff:ff:ff"` で除外。②`sockaddr_inarp` は `<netinet/if_ether.h>`、`sockaddr_dl`/LLADDR は
  `<net/if_dl.h>`、route message 内の sdl オフセットは `roundup4(sin_len)`(SA_SIZE相当を自前定義)。
  ③en* インターフェースのみ対象(utun/awdl/llw/bridge除外)。④逆引きは件数多いと遅い→ワーカースレッドで
- パラメータ: Mode / Rescan Now / Service Types / Domain / Resolve Timeout / Subnet(空=自動) /
  Scan Timeout / Max Hosts / Reverse DNS / Restart Bonjour。**Max Hosts で大サブネット暴走を防止**
- 注意: ARP非応答機器・別VLAN・FW越し・スリープ端末は見えない。IPv6全域は不可。DHCPリース一覧APIは無い。
  MACベンダー(OUI)名は未対応(将来候補)。README(新規節+ルート英日)更新。バンドル再ビルド・インストール済み

### 2026-07-22 Network Discovery に自機IP表示を追加

- ユーザー「自分のIPアドレスもわかるように」。自機はBonjour広告(_raop等)がある時しか表に出ず、
  無ければ全く出なかった。`getifaddrs` で自機の en* IPv4 + MAC(AF_LINKのsockaddr_dl)+ `gethostname`
  を取得し、**Mode に関わらず必ず self 行を注入**(既存のBonjour/ARP行と一致すれば source に "self" を足す)
- 実測(M2・TD): 自機 192.168.49.16 が **`source=bonjour+arp+self`** でMAC/ホスト名付きで表示。
  スタンドアロンで en0 の ip/mac/host 取得も確認。バンドル再ビルド・インストール済み

### 2026-07-22 Network Discovery を LanScan Pro 相当に(MACベンダー/DNS名・mDNS名分離)

- ユーザーがLanScan Proのスクショを提示「同じような情報を取得したい」。不足していた
  **Vendor(MACベンダー)** と **DNS名/mDNS名の分離** を追加
- **Vendor(OUI)**: IEEE公式から MA-L/MA-M/MA-S を取得し `oui.txt`(約53000件・1.65MB・**コミット**)
  を生成、プラグインの `Contents/Resources/` に同梱。実行時に `dladdr(&関数)` で自バンドルの
  MacOS実行ファイルパス→`../Resources/oui.txt` を導いて1回ロード(`std::call_once`)。MAC先頭
  24/28/36bit を **longest-match**。ランダム化MAC(ローカルアドミニスタード)は空欄。
  生成スクリプトは `tools/gen_oui.py`
- **DNS名 / mDNS名の分離**: `dns_name`=標準リゾルバの逆引き(getnameinfo・ユニキャストPTR。
  `.local`以外)、`mdns_name`=**強制マルチキャスト逆引きPTR**(`DNSServiceQueryRecord` +
  `kDNSServiceFlagsForceMulticast`・`.local`)。`assignRevName` で `.local` 判定して振り分け。
  Bonjour解決名は mdns_name に入れる
- 出力列を **ip4 / mac / vendor / dns_name / mdns_name / service_type / name / ip6 / port / txt /
  source** に再編(LanScan Pro相当)。実体のない行(ip/mac/name全空)は除外
- **実測(M2・自宅LAN)— LanScanと一致**: BUFFALO.INC/Espressif/Amazon/Hitachi Global Life
  Solutions/Panasonic/ATOM tech/Intel、mdns=linux-2.local/HITACHI.local/各iPhone.local、
  dns=ルータのap50c4dd…。スタンドアロンで mDNS逆引き(dns_sd)を先に検証してから TD 実機で確認
- **踏んだ罠**: ①`DNSServiceRefSockFD`(末尾FD大文字。SockFdではない)。②dns_sdは追加フレームワーク
  不要(libSystem)。③OUIロードは `dladdr` でバンドルResourcesパスを取得(C++クラスなのでNSBundle
  bundleForClass不可)。④逆引きは1台~1秒×件数でスキャンが数十秒になる(ワーカースレッドなのでcookは
  非ブロック)
- **未対応**: SMB Name/Domain(NetBIOS 137/445)は LanScan にあるが未実装(将来候補)。README
  (新規節+実測表+ルート英日)更新。build.sh に oui.txt 同梱処理追加

### 2026-07-22 Network Discovery に SMB名/ドメイン(NetBIOS)を追加(LanScan Pro完全対応)

- ユーザー「SMB Name/Domain(NetBIOS)追加して」。NetBIOS Name Service(UDP 137)の
  **Node Status(NBSTAT)クエリ**で Windows/NAS/Samba のコンピュータ名・ワークグループを取得
- **リクエスト**: 特殊名 "*"+null15 を first-level encoding(各バイト→2ニブル+'A')し、
  QTYPE=NBSTAT(0x21)/QCLASS=IN で UDP 137 へ。**応答パース**: RR の RDATA から numNames→
  各 16byte名+2byte flags。unique 0x00=`smb_name`(コンピュータ名)、group 0x00=`smb_domain`
  (ワークグループ)。`__MSBROWSE__` は除外
- 出力列を **ip4/mac/vendor/dns_name/mdns_name/smb_name/smb_domain/service_type/name/ip6/port/
  txt/source**(13列)に拡張。`NetBIOS / SMB Name` トグル(既定On・1台0.6s)
- **検証**: ①合成NBSTAT応答でパーサが `MYPC`/`WORKGROUP` を抽出 ②**疑似レスポンダで
  フル送受信ラウンドトリップ**(高ポートにバインド→リクエスト受信→合成応答→`NAS-SERVER`/`HOME`
  を取得)③TD実機で13列・Netbiosパラメータ・エラーなしを確認。**このLANはNetBIOS応答機器が
  無く実機のSMB値は空**(現代の機器はNetBIOS無効が多い・macOSのnetbiosdも既定オフ)
- **踏んだ罠**: NBNSは応答が無くてもエラーにならない(応答機器が無いだけ)。フル検証には
  疑似レスポンダを立てる(137は特権ポートなのでテストは高ポートで送受信を確認)
- **TD起動が固まった**: バンドル入れ替え後の初回起動が7分たっても "Loading" のまま→
  強制終了(`pkill -9`)→再起動で2回目はキャッシュで通常起動(CLAUDE.md既知挙動どおり)
- README(smb列・実測注記・パラメータ)+ルート英日更新。これで LanScan Pro の全列(IP/MAC/
  Hostname/Vendor/DNS/mDNS/SMB Name/SMB Domain)に対応

### 2026-07-22 WiFi SSID取得の検証: CoreLocation組み込みでも取れない(結論)

- ユーザー「CoreWLANプラグインに位置情報リクエストを組み込んでSSID取得を試す」。CoreLocationの
  許可リクエストを実装し、プラグインと同じ処理を単体アプリで段階検証した結果、**macOS 26.5.1では
  SSIDは取れない**と判明。コードは追加せず結論をREADME/本ログに記録
- **実測(スタンドアロン)**:
  - 裸のCLI(Info.plist用途文字列なし)= 許可プロンプトすら出ず notDetermined 固定 → ssid=nil
  - 正しい.app + `NSLocationWhenInUseUsageDescription` = **authorizedAlways取得してもssid=nil**
  - + 実位置フィックス(実座標35.33,139.49が返る) = **ssid=nil**
  - + フル精度認可(`requestTemporaryFullAccuracyAuthorization`) = **ssid=nil**
  - `ipconfig getsummary en0`=`SSID : <redacted>`、`system_profiler`=`<redacted>`(システムレベルで伏せ)
- **結論**: macOS 26 は SSID を Location権限＋正規署名(ad-hoc不可)の両方でゲート。教科書通りの
  完全条件でも第三者アプリからは返らない
- **TDプラグイン固有の決定的な壁**: 責任プロセス TouchDesigner.app の Info.plist に `NSLocation*`
  用途文字列が無い → プラグインから `requestWhenInUseAuthorization()` を呼んでもサイレント無反応
  (プロンプト出ない=SFSpeechRecognizerで踏んだTCCの壁と同構造)。`.plugin`単体でplistキーを足せず、
  TD.appのplist改変は署名を壊す。よって**位置情報リクエストの組み込みは断念**(常にnilの動かない
  トグルになるため)。数値(RSSI/SNR/channel/rate/PHY)は現状CoreWLANプラグインで問題なく取れる

### 2026-07-22 CoreWLAN Scan CHOP 実装(電波混雑・空きチャンネル探し)

- ユーザー「周りに飛んでるSSID一覧は取れる?」→ 検証: `scanForNetworks` は動くが **SSID名/BSSIDは
  macOS 14+ privacyで伏せられ取得不可**(接続中SSIDと同じLocationゲート・プラグインからは実質不可)。
  ただし **AP数・RSSI・帯域(2.4/5GHz)・チャンネル幅は取れる**。ユーザー了承のもと「名前抜きの
  電波環境スキャン(混雑度・空きch探し)」を新規OPで実装
- **CoreWLAN Scan CHOP**(opType `Corewlanscan`・icon CWS・別OP。接続中数値の CoreWLAN CHOP とは別):
  - **混雑度モデル**: 各APの占有帯域(中心周波数±幅/2)を各20MHz枠との重なり割合で按分し
    線形強度 `10^(rssi/10)` を加算。**40/80MHz幅APの隣接ch干渉も反映**。バンドごとに最大=1へ正規化。
    `best_ch` = 最も混雑度が低いch
  - 出力126ch: 診断5 + 2.4GHz(ch1-14)×(aps/rssi/congestion) + 5GHz(36-165の25ch)×3 +
    best_ch/best_congestion×2バンド
  - **scanForNetworks はブロックするのでワーカースレッド**で実行(Scan Interval秒 or Rescanパルス)、
    cookは集計スナップショットを読むだけ(非ブロック)
- **実測(M2・macOS 26.5.1)**: 6ネットワーク検出。ch10の40MHz強AP(-44dBm)が ch8-12 に干渉する
  グラデーション、**best 2.4=ch1 / best 5=ch36** を正しく提示。スタンドアロンで混雑度モデルを
  先に検証してからTD実機で126ch・エラーなしを確認
- **踏んだ罠**: `channelWidth`(20/40/80/160MHz)と `channelBand`(2GHz/5GHz)から中心周波数を
  計算して帯域重なりを出す。2.4GHzは ch14=2484 の特例、他は 2412+(ch-1)*5。5GHzは 5000+ch*5
- README(新規+ルート英日)更新。バンドル常設インストール済み(TD再起動で `Corewlanscan` 登録)

### 2026-07-22 Shortcuts DAT の Run が失敗する問題を修正(URLスキーム委譲)

- ユーザー「musicアプリで再生するショートカットを実行して」。Shortcuts DATの `Run`(`shortcuts run` CLI)
  が **「操作を完了できませんでした。ショートカットが見つかりませんでした」** で失敗
- **切り分け**: ①名前は完全一致(NFC・生バイト一致・正規化問題ではない)②ターミナルからの
  `shortcuts run` は TTY無し/nohup/最小envでも全て成功(exit 0)③プラグインの `list` は成功
  (21件取得)、`run` だけ失敗。→ **原因は責任プロセス=TouchDesigner の権限**。`list` は読み取りのみ
  で通るが、`run` は Music/HomeKit等を操作するため実行権限が要り、TD未認可だと「見つからない」という
  紛らわしいエラーになる(macOSの仕様)
- **修正**: `open -g shortcuts://run-shortcut?name=...&input=...` で **Shortcuts.app に委譲**する
  App方式を追加し既定に。権限を持つ Shortcuts.app 側で走るので確実。`Run Method` メニュー
  (app=既定/cli=出力を返す)を追加。URL構築は `NSURLComponents`+`NSURLQueryItem` で正しくエンコード
- **トレードオフ**: App方式は**出力テキストを受け取れない**(fire&forget)。値を返すショートカットは
  CLI方式(ただしTD権限が要る)。動作させたいだけなら App、出力が要るなら CLI、と使い分け
- **実測**: OP経由(App方式)で「今聴いているアルバムの全曲を再生」→ **Music.app が playing**。
  CLI方式では「見つからない」を再現。sample.toe の `/project1/shortcuts_demo`(List実行済み+手順note)
  も保存
- **踏んだ罠**: TD等GUIアプリからの `shortcuts run` CLI は責任プロセスの権限で走り、外部アプリ操作系
  ショートカットは「見つからない」で失敗する。**URLスキーム(open shortcuts://)でShortcuts.appに
  委譲**すれば回避できる(出力は諦める)。listは読み取りのみで権限不要

### 2026-07-22 Shortcuts DAT のUX改善(プルダウン選択 + 常時status表示)

- ユーザー「DATの画面に一覧もstatusも出て分かりづらい。プロパティからプルダウンで選び、画面は
  常にstatus/情報が出る形に」
- **Shortcut を動的メニュー(プルダウン)化**: `appendDynamicStringMenu` + `buildDynamicMenu`。
  **起動時にワーカースレッドで `shortcuts list` を自動取得**してメニューに入れる(21件)。
  `Refresh List` パルスで再取得。動的メニューは**非空の既定値が必要**(ScreenCaptureの教訓)→
  `defaultValue="(refresh list)"`
- **画面(出力テーブル)は常に status/情報**: `status / shortcut / method / output / took_ms /
  shortcuts(一覧数)`。一覧はテーブルにダンプせずプルダウンへ。旧 `List Shortcuts`(テーブルダンプ)
  は廃止し `Refresh List`(プルダウン更新)に
- 状態は myList(プルダウン用)/ myStatus,myLastShortcut,myLastOutput,myLastMethod,myTookMs
  (常時表示用)に分離。Info CHOP に `shortcuts` 数を追加
- **実測**: TD再起動後、起動時自動取得で21件がプルダウンに、画面は `status=ready shortcuts=21`。
  プルダウン選択→Run(App方式)で Music再生を確認(status=launched)。ショートカット自身の挙動
  (「再生中のアルバムを再生」はMusic停止中だと何もしない)はOP外
- **踏んだ罠**: `appendDynamicStringMenu` は非空 defaultValue 必須。buildDynamicMenu は
  `info->name` で対象par判定し `addMenuEntry(value,label)`。一覧はmutex保護のスナップショットを読む

### 2026-07-22 AppleScript DAT 実装(汎用オートメーション・osascript)

- ユーザー要望「AppleScript実行DAT」。Shortcuts DATの権限問題(TD権限で外部アプリ制御が失敗)の
  流れで、AppleScript/JXAを実行して結果も返す汎用オートメーションOPを実装
- **AppleScript DAT**(opType `Applescript`・icon ASC): `osascript` をワーカースレッドで実行
  (スクリプトは stdin へ流す)。Language=applescript/javascript(JXA)。スクリプトは**入力DAT優先**
  (全セルを改行連結・複数行に最適)、なければ Script パラメータ。画面は常に
  `status / result / error / took_ms / language` を表示(Shortcuts DATと同じUX)
- **実測(M2・macOS26.5.1)全部OP経由で成功**: `(10+5)*2`→30、JXA `6*7`→42、
  `system version`→26.5.1、`Finder home name`→murata、構文エラー→status=error+error列に理由(落ちない)、
  **`tell application "Music" to play`→playing**(TD権限で外部アプリ制御が成功・結果も取れる)
- **Shortcutsとの違い**: Shortcuts CLI方式は外部アプリ操作が「見つかりません」で失敗したが、
  AppleScript は**正規の Automation TCC 許可フロー**に乗る。初回に「TouchDesignerが<アプリ>を制御
  しようとしています」ダイアログ→許可すればTDから直接アプリ制御でき結果も返る。Shortcutsより自由度高い
- sample.toe `/project1/applescript_demo`(system info実行+手順note)追加。README(新規+ルート英日)更新
- **踏んだ罠**: osascript は stdin からスクリプトを読める(`echo '...' | osascript`)。-l で言語指定。
  他アプリ制御は Automation権限(TCC)必須で、責任プロセスはTD本体(初回ダイアログで許可が要る)

### 2026-07-22 SwiftUI TOP 実装(macOS標準UIフレームワークをTDで)

- ユーザー「macOS標準のUIフレームワークをTDで使えるプラグイン」→ 調査提案の結果 **#1 SwiftUI TOP**
  を実装。SwiftUIビューをテクスチャにレンダしてTDの映像に(SF Symbols/システムフォント/Gauge/
  ProgressView)。値はTD側パラメータから流し込む一方向
- **アーキテクチャ**: Swiftヘルパ `SwiftUIHelper`(C ABI su_)が `ImageRenderer`(macOS 13+)で
  SwiftUIビューをCGImage→BGRA化。**SwiftUIはメインスレッド専用**なので `DispatchQueue.main.async`
  で回す(TDがメインrunloopをpumpする・RealityKit/Cinematicで実証済みのパターン)。cookは最新
  テクスチャを非ブロックでupload。Translateプラグインが既にNSHostingView動作の前例
- **Mode**: text / symbol(SF Symbol) / gauge(円形) / progress(バー)。Foreground/Background(RGBA)、
  Font/Symbol Size、Value(0..1)、Width/Height
- **実測(M2・視認)**: 4モードすべて正しくレンダ・向き正立。Text「SwiftUI in TD」(rounded)、
  `bolt.fill`(黄・色反映)、`waveform.circle.fill`、Gauge 72%(円形+ラベル)、赤背景+白「● LIVE ●」。
  デモ(sample.toe `/project1/swiftui_demo`)は Value を sin 駆動でゲージがライブで動く
- **踏んだ罠**: ①`ImageRenderer`/`.cgImage`/`.scale` は `@MainActor` → 呼ぶ関数に `@MainActor` を付け、
  `DispatchQueue.main.async` 内で呼ぶ。②RGBAパラメータ(appendRGBA)は Python から成分ごと
  (`Textcolorr/g/b/a`)に設定(タプル代入は効かない)。プラグインは `getParDouble4` で読取。
  ③SwiftUI/CGは top-down → TD表示に合わせヘルパ側で行反転(bottom-up)して格納
- **制約**: 一方向(表示専用)。TOPにはマウス/キーが渡らないので双方向操作は不可(双方向は別途
  NSWindow方式が必要)。macOS 13+必須。README(新規+ルート英日)更新
- **調査で分かった代替**: 通知/ファイル選択/アラート/基本色選択は既に AppleScript DAT で叩ける。
  ネイティブでないと無理な候補は SwiftUI TOP(実装)/ MenuBar(NSStatusItem)/ ColorSampler(画面
  スポイト)/ Native Panel(浮遊NSWindow)/ Native Text Input(IME)

### 2026-07-22 SwiftUI TOP: progressバー修正(色対応)+ SF Symbols/マウス操作の整理

- ユーザー「progress/barをマウス操作したい・バーの色も変えたい・SF Symbolの中身は?」
- **progressバーの描画バグ修正**: `ProgressView(value:)` は **ImageRenderer で正しく描けない**
  (黄色い全幅バー+🚫アイコンに化ける)。**カスタム図形(Capsule×2: トラック+塗り)**に置換。
  塗り=Foreground色、トラック=Foreground薄色、幅=value。実測で緑バー65%を視認、色制御OK
- **バーの色 = Foreground**(Gaugeも同様)。TD PythonのRGBA設定は成分ごと(`Textcolorr/g/b/a`)
- **マウス操作**: TOPはテクスチャで**TDからマウスイベントが来ない**(レンダ画像を直接クリック不可)。
  値をUIで動かすには TD側UIを `Value` に配線: ①Valueパラメータのスライダー ②Slider COMP を
  `Value.expr="op('slider1').panel.u"` ③Mouse In CHOP。実測: Slider COMP値0.2/0.8/0.5にバーが追従。
  sample.toe `/project1/swiftui_demo` を slider1→swiftui1(progress) の構成に更新
- **SF Symbols**: Appleのアイコン集(約5000+)。文字でなくベクターアイコン。名前は SF Symbols.app で確認
  (star.fill/bolt.fill/wifi/waveform 等)。symbolモードで名前指定→システム色/サイズで描画
- **踏んだ罠**: SwiftUIの一部コントロール(ProgressView等)は ImageRenderer で正しく描けない
  → 図形(Shape)ベースで自前描画すると確実。GeometryReaderは使わず既知のw/hから寸法計算
- README更新(バー色・SF Symbols・マウス操作の節を追加)

### 2026-07-22 SwiftUI TOP に window(JSON UIツール群)モード追加

- ユーザー「window自体をMac標準パーツでレンダできるUIツール群にしたい」→ SwiftUI TOPに
  **window モード**を追加。**JSONでUIを記述**するとトラフィックライト付きタイトルバー+各コントロールを
  ネイティブ風にレンダ(ショー制御パネル/HUD向け)
- **JSON→SwiftUIビルダー**(`UIWindow`/`UINode`・再帰)。対応type: text/symbol/button/toggle/slider/
  progress/card/divider/spacer/row/col。トップに title/traffic/bg/spacing。色は[r,g,b,a]配列
- **ImageRenderer検証で判明**: NSButton/NSSwitch(Toggle)/NSSlider などネイティブコントロールは
  **オフスクリーンでラスタライズできない**(黄色い箱+🚫)。**スタンドアロンではButtonが描けたが
  TD埋め込みでは描けなかった**(AppKit活性コンテキストの差)。→ button/toggle/slider は**SwiftUI図形で
  同じ見た目を自前描画**。text/SF Symbol/タイトルバー/Material はネイティブでOK
- JSONは Layout パラメータ(式で Text DAT 参照 `op('json1').text` 可)。mode==4 で su_submit_json
- **実測**: スタンドアロン+TD実機でウインドウUI(タイトルバー/Start Showボタン/Auto Modeトグル/
  Brightnessスライダー/Render62%バー/Now Playingカード/★4.5)を視認。全パーツ正立でレンダ
- sample.toe `/project1/swiftui_demo` に window1(JSON→window mode)+ window_json(Text DAT)を追加
- 踏んだ罠(pitfalls): SwiftUIのネイティブコントロール(Button/Toggle/Slider/ProgressView)は
  ImageRendererで描けない→図形(Shape)で自前描画。GeometryReaderは避け既知w/hで寸法計算

### 2026-07-22 SwiftUI Panel CHOP 実装(本物の操作可能なmacOSウインドウ=TDのUI)

- ユーザー「操作可能なwindowにしたい・windowコンテナで表示してTDのUIとして使いたい」→ SwiftUI TOP
  (テクスチャ・表示専用)とは別に、**実ウインドウ(NSWindow+NSHostingView)にインタラクティブな
  SwiftUIコントロールを表示し、操作値をCHOPで返す** SwiftUI Panel CHOP を新規実装(#4 Native Panel)
- **実ウインドウなのでネイティブコントロールがそのまま操作できる**(ImageRendererが描けなかった
  Slider/Toggleも本物として動く)。JSONでコントロール定義(id付き)→ id がチャンネル名
- **アーキテクチャ**: Swiftヘルパ `SwiftUIPanelHelper`(C ABI sp_)。`PanelModel`(ObservableObject)が
  UI値を @Published で持ちつつ、ロック保護の store にも書いてCHOP(cookスレッド)が読む。ボタンは
  pressed Set を1回消費(モーメンタリ)。ウインドウは `.floating`・DispatchQueue.main.async で表示
- **実測(computer-useで実操作)**: Brightnessスライダーをドラッグ→brightness 0.48→0.99(ウインドウ
  表示と一致)、Strobeトグル→strobe=1、Fireボタン→fire が1フレームだけ1(次cookで0)。全て検証
- **CHOP**: JSONを `NSJSONSerialization` でパースしてコントロール(id,type)を取得、id=チャンネル名。
  slider/stepper→値、toggle→0/1、button→sp_take_button(モーメンタリ)。getOutputInfoとexecuteで
  同じparseControlsを呼びチャンネル並びを一致させる
- opType `Swiftuipanel`・icon SUP・CHOP。sample.toe `/project1/swiftui_panel_demo` に利用例。
  README(新規+ルート英日)更新。TD再起動は今回ダイアログ無しで正常起動(スクショ権限も復帰)
- 未対応: 値の書き戻し(TD→ウインドウ)、NSTextField(テキスト入力)。将来候補

### 2026-07-22 UI Widget DAT + Panel の Widgets DAT 対応(COMP風のUI部品合成)

- ユーザー「TD標準のCOMP opみたいに Button/Slider op を Container でまとめたい」
- **重要な制約(確認済み)**: C++ Custom OP SDK は **TOP/CHOP/DAT/SOP/POP のみで COMP は作れない**
  (SDKサンプル・FillXXXPluginInfo に COMP 無し)。=「Button COMP を Container COMP に入れる」TD標準
  そのものはプラグイン化不可(それはTD標準機能で既に可能)。ネイティブUIでやるなら **部品=DAT /
  コンテナ=Panel(実ウインドウ)** に置換する
- **UI Widget DAT**(opType `Uiwidget`・icon UIW): Type(slider/toggle/button/stepper/text/header/
  divider)+ id/label/min/max/value/color を **1行のJSON spec(1x1テーブル cell(0,0))** に出力
- **SwiftUI Panel CHOP に Widgets DAT パラメータ(appendDAT/getParDAT)を追加**: DATが繋がっていれば
  各行 cell(r,0) を1コントロールとして `{"controls":[...]}` に集約、無ければ従来の Json パラメータ
- **フロー**: UI Widget DAT ×N → **Merge DAT** → Panel の Widgets → 1つの実ウインドウに集約。
  値は Panel 出力の id別チャンネル(Select CHOPで個別取り出し)。TDのWidget→Container→パネルの
  データフロー版
- **実測(実操作)**: slider/toggle/button の3部品を Merge→Panel で「Assembled Panel」1窓に集約、
  Brightnessドラッグ→出力 brightness 0.60→0.95 追従を確認。全chエラーなし
- sample.toe `/project1/uikit_demo`(UI Widget×4 + Merge + Panel、Show=0既定=起動時は窓を出さない)。
  README(UIWidget新規・Panel更新・ルート英日)更新。opカタログ 32/21/24/4
- 未対応: 画像/動画widget(TOP参照をPanelに表示)、値の書き戻し、NSTextField。将来候補

### 2026-07-22 SwiftUI Panel構成を palette用 .tox 化(NativePanel.tox)

- ユーザー「SwiftUI Panel構成を.tox化してpaletteに」。**.plugin(エンジン)+ .tox(テンプレート)の
  二層**方針。ネイティブUIレンダは.pluginが担い、.toxは配線済み・パラメータ露出済みの再利用テンプレ
  (.tox単体では動かない=プラグイン必須)
- **NativePanel.tox**: `UI Widget DAT ×4 → Merge(widgets) → SwiftUI Panel CHOP → out` を1つのbaseCOMPに。
  COMPに**カスタムパラメータ Show/Title を appendCustomPage で露出**し `panel.par.Show/Title` を
  `parent().par.X` 式でバインド。out(null CHOP)にウインドウ操作値(level/enable/trigger)
- **TD標準の質問への答え(確認済み)**: ①TD標準Slider/Buttonを.tox化してpaletteに=TD標準だけで可能
  ②TD標準Widgetの見た目をSwiftUIに差し替え=不可(TDにフック無し)③SwiftUI Panel構成を.tox化=可能
  (.plugin別途要)④.tox単体でネイティブUI=不可(ネイティブコード必須)。今回は③を実装
- **保存先**: TDユーザーpalette `~/Library/.../palette/sygnal/NativePanel.tox` + リポジトリ `palette/`。
  `paletteData.json` の sygnal コレクションに登録(TD再起動 or palette更新で Palette Browser に出る)
- **実測**: `loadTox` でフレッシュロード→Show/Titleカスタムpar・全部品・out 3ch復元、Show=1で
  「TD Native Panel」ウインドウ表示を確認。tox 1.2KB(軽量・配線のみ、pluginは参照)
- **踏んだ罠**: `appendToggle/appendStr` の label は**キーワード引数**(位置引数だと "Single name
  argument expected" エラー)。COMPカスタムpar露出は `comp.appendCustomPage(name)` → `pg.appendToggle`
- palette/README.md 作成(必要プラグイン・登録手順・実測)。ルートREADMEは対象外(paletteは補助)

### 2026-07-22 SwiftUIButton.tox(Button COMPのネイティブUI版)を palette に追加

- ユーザー「Button COMPを元に拡張したSwiftUI Button。元のボタン機能そのまま、UIがSwiftNative」
- **前提(確認済み・再掲)**: TD標準Button COMPのUI描画をSwiftUIに差し替えるのは不可(フック無し)。
  作れるのは「Button COMPと同じ出力仕様(クリック→state)を持つ、UIがネイティブSwiftUIな別COMP」
- **SwiftUIButton.tox**: base COMP。中身 `UI Widget DAT(button)→ SwiftUI Panel CHOP → out`。
  COMPに Label/Show/Title を露出、`out` に `state`(クリックした瞬間だけ1=モーメンタリ・Button COMP既定と同じ)
- **Toggle の判断**: Count CHOP(output=loop/limitmax=2)でトグル化を試みたが、**モーメンタリ信号
  (1フレーム)を連続cook時以外は取りこぼす**ためフラつく。Button COMP既定もMomentaryなので v1 は
  Momentaryのみに確定。Toggleは将来ヘルパ側でtoggleボタン(押下でmodel値をflip・保持)として堅牢化
- **実測(実操作)**: ネイティブ「Button」ウインドウ→クリック→`state` 1フレームだけ1(次0)を確認。
  palette/sygnal + リポジトリ palette/ に保存、paletteData.json に登録(tox 1.0KB)
- **踏んだ罠**: Count CHOPのラップは `output` パラメータ(off/loop/min/lc/cl)+ limitmin/limitmax。
  モーメンタリ→カウントのトグルは cook 連続性に依存し不安定(単発cook検証では edge を逃す)
- palette/README.md 更新(SwiftUIButton節・できる/できない明記)

### 2026-07-22 CoreWLAN Scan に SSID取得を追加(位置情報ヘルパー.app方式)+ 過去の誤り訂正

- ユーザーが記事(techblog.kayac.com/wifi-analyzer-on-mac)を提示。**SSID取得の再検証**を実施
- **過去の結論「macOS 26では位置情報許可でもSSIDはnil」は誤りだった**。正規Info.plist(NSLocation
  用途文字列)を持つ.appで CLLocationManager 許可→authorizedAlways にすると、**scanForNetworks の
  SSID も接続中SSIDも返る**ことを実測(SYGNAL/SYGNAL_GUEST/SCC_JBFES等18件)。以前の検証は
  authorized に到達できていなかった(プロンプトが出ない=Info.plist用途文字列が無いバイナリ)
- **TDプラグイン固有の壁**: 責任プロセス=TouchDesigner本体のInfo.plistに位置情報用途文字列が無く、
  プラグインから許可要求してもプロンプトが出ない(=SSID nil)。**回避策=独自Info.plist(用途文字列
  +LSUIElement)を持つヘルパー.appを同梱**し、`open -g -j helper.app --args <json>` で起動。ヘルパーが
  Location許可→scanForNetworks→JSONをキャッシュに書き、CHOPが読む(記事のNode.js→python別プロセスと同型)
- **CoreWLAN Scan CHOP**: `Get SSID Names` トグル追加。worker が doScan(混雑度・権限不要)後に
  ヘルパー起動+前回JSON読取→**Info DAT(ssid/bssid/rssi/channel/band)**。ヘルパーパスは dladdr で
  `Contents/Resources/Helpers/wifiscan-helper.app`。混雑度チャンネルは従来どおり(内蔵scan・権限不要)
- **実測**: ヘルパー単体で18 SSID取得を確認。**TD実機でも検証完了**: CoreWLAN Scan の
  `Get SSID Names` オンで Info DAT に SSID+BSSID+RSSI+channel+band が18件(SCC_JBFES/SYGNAL/
  SYGNAL_GUEST/Buffalo-5G-BAE0等)。混雑度チャンネル(権限不要)も同時に動作(28net・best 2.4=ch14)。
  許可済みのため2回目以降はダイアログ無しで即取得
- **踏んだ罠**: ①バイナリ直接実行(open非経由)は責任プロセス=Terminalでアプリ識別が無く SSID空。
  **必ず `open` で.appとして起動**(自前のLocation identity で許可・取得できる)。②ヘルパーは
  scanForNetworksがブロックするので独立プロセスが好適。③初回だけ許可ダイアログ(ヘルパーapp宛)
- README(CoreWLANScan・ルート英日)の「SSID取得不可」記述を訂正。pitfalls追記予定

### 2026-07-22 WifiScanner.tox(CoreWLAN Scan + SSID Info DAT配線済み)を palette に追加

- ユーザー「Get SSIDをONにすると自動でInfo DATが出てくる仕様にできないか」
- **制約(再掲)**: Custom OPは自分の隣に別ノードを自動生成できない(SDK設置時フック無し)。
  → 手でInfo DATを作って op= する手間をなくすには **.tox で CHOP + Info DAT を配線済み**にするのが確実
- **WifiScanner.tox**: base COMP。中身 `scan`(CoreWLAN Scan CHOP)+ `congestion`(null CHOP)+
  `ssid`(Info DAT・op=scan)+ `onpar`(Parameter Execute)。COMPに Get SSID/Scan Interval/Rescan を
  露出し scan にバインド(Rescanは onPulse コールバックで内部scanへ伝播)
- **実測**: WifiScanner を置くと ssid Info DAT に周辺SSID 24行が自動表示(SYGNAL/SCC_JBFES等)。
  palette/sygnal + repo palette/ に保存、paletteData.json 登録
- **踏んだ罠**: Parameter Execute DAT のパルス監視は `onpulse`(pulseではない)+ `pars='Rescan'` で
  対象par限定。appendFloat の範囲は normMin/normMax。COMP par → 内部op は expr で bind
- palette/README.md 更新(WifiScanner節)

### 2026-07-22 CoreWLAN Scan: Get SSID ON で Info DAT を自動生成(pythonCallbacksDAT)

- ユーザー要望「GetSSIDをONにすると自動でinfoDATが出てくる仕様に」→ SDKの
  `customOPInfo.pythonCallbacksDAT` を初採用して実装(リポジトリ初の Python コールバック付き Custom OP)
- **仕組み**: stub 文字列をセットすると Custom ページに「Callbacks DAT」par + `Add` ボタンが付く。
  Add で **onGetSSID 雛形が事前入力された Text DAT が自動生成・接続**される(TD標準機能・実測)。
  C++ 側は execute で Getssid の **off→on 遷移**を検出し、`context->createArgumentsTuple` +
  `callPythonCallback("onGetSSID", ...)` で発火。Python 側が `parent().create(infoDAT, op.name+'_ssid')`
  で隣に Info DAT を生成(`d.par.op` を自ノードに設定・**二重生成ガード** `if p.op(name): return`)
- **ビルド**: `#include <Python.h>`(TD同梱 Python 3.11 ヘッダ)+ `-undefined dynamic_lookup`
  (Py_* は実行時にTD本体から解決)。common/build_plugin.sh に任意の `TD_EXTRA_CFLAGS` を追加
  (既定空=他プラグイン無影響)
- **実測(M2・TD実機)**: Add → callbacks DAT 生成(雛形入り)→ Get SSID ON → `cwtest_ssid`
  (Info DAT)が隣に自動生成され **19 SSID**(Uro_5030336/Buffalo-5G-BAE0等・bssid/rssi/channel/band)
  を自動表示。off→on を繰り返しても1個のまま(ガード動作)。混雑度126chも従来どおり。エラーなし
- Callbacks DAT 未接続なら何も起きない(Py_None が返るだけ・安全)。README(CoreWLANScan/palette)
  更新、pitfalls.md に pythonCallbacksDAT の作法を追加
- sample.toe は未保存のまま(検証ノードは削除済み。今セッション中に `button1` がメモリ上から
  消えた事象があったが原因不明・ディスクの sample.toe は無傷なので保存せず温存)
- 次にやること: 他の「セットで使う」OPへの横展開候補(SwiftUI Panel の Widgets DAT 自動生成等)

### 2026-07-22 CoreWLAN Scan: 配置するだけで Callbacks DAT も自動接続(完全自動化)

- ユーザー「opを配置したら自動でCallbacks DATが接続される仕様にできないか」→ 実装完了。
  **配置(初回cook)で雛形入り Callbacks DAT を自動生成・接続 → Get SSID ON で Info DAT 自動生成**
  の全ステップが無操作になった
- **仕組み**: 初回cookで `PyRun_String`(TD組み込みPython直接実行)により textDAT を生成し
  `par.callbacks` へ接続。成功(=callbacks接続済み)を `__cwlan_ok` グローバルで読み戻し、
  **成功するまで毎cookリトライ**(生成直後はカスタムパラメータ未生成で必ず1回は失敗するため)
- **ハマった2点(pitfalls反映)**: ①`OP_NodeInfo::opPath` が**空**(macOS実測)→ パスで自ノードを
  引けない。`createArgumentsTuple(0)` の args[0](自ノードPyObject)を `__main__` に渡して解決。
  ②`PyRun_SimpleString`/`PyRun_String` の `__main__` には op/textDAT が無い → `import td` で
  `td.op`/`td.textDAT` を明示参照。例外は `__cwlan_err` グローバルに traceback を残す設計
- **実測(M2・TD実機)**: 配置→cookで `cwauto_callbacks` 自動接続、Get SSID ON で `cwauto_ssid`
  自動生成、スキャン後 **17 SSID**(SYGNAL等)表示。ON/OFF繰り返しでも各1個(ガード動作)。
  エラーなし・混雑度126chも従来どおり
- **注意**: TD終了(osascript quit)時に sample.toe が自動保存されることがある(15:09保存を確認)。
  原因不明の button1 消失(14:53)がディスクに固定された可能性 → ユーザーに報告済み

### 2026-07-22 CoreWLAN Scan: Callbacks DAT をホストへドック(既定非表示)

- ユーザー「GLSLの様にcallback DATをノード下部で開閉したい。既定は接続済みだが閉じて非表示が理想」
- bootstrap の自動生成に `d.dock = n`(ホストへドック)+ `d.expose = False`(既定非表示)を追加。
  GLSL TOP の docked シェーダDATと同じ機構(TD標準の dock/expose フラグ)
- MCP実測: 配置→ `_callbacks` が dock=/project1/cwauto・expose=False で生成、ネットワーク上は
  非表示のまま接続・機能(Get SSID ON→ssid DAT生成)正常。GLSL既定は expose=True(チップ表示)、
  本OPは要望どおり expose=False(完全非表示)を既定にした
- ドック展開のUI操作(右クリックメニュー等)の実機確認はユーザーに依頼(以降、TD上の確認操作は
  ユーザーへ指示する方針に変更・memory反映)

### 2026-07-22 CoreWLAN Scan: Callbacks DAT をチップ表示に変更(expose=True)

- ユーザー「チップ表示をつけて」→ ドック生成時の expose を False→True に変更。
  GLSL TOP の docked シェーダDATと同じ「ノード下の小チップ」表示が既定になった
- リビルド・インストール済み。TD再起動後に配置で反映(ユーザー実機確認待ち)

### 2026-07-22 CoreWLAN Scan: チップは既定で閉じる(viewer=False)

- ユーザー「デフォルトでチップ表示のcallbackDATを閉じておきたい」→ ドック生成時に
  `d.viewer = False` を追加(expose=True のチップ表示は維持、ビューアだけ閉じる)。
  リビルド・インストール・TD再起動済み(ユーザー実機確認待ち)

### 2026-07-22 コールバック/ドックチップの知見を skill と CLAUDE.md 本文へ反映

- ユーザー指示でドキュメント整理。skill pitfalls.md「Python コールバック」節に**ドックチップの
  作法**(dock + expose/viewer の組合せ3パターン・nodeX/Y無効・dock解除)を追記
- CLAUDE.md ハマりどころ集「TD本体の挙動」に pythonCallbacksDAT +ノード自動生成+ドックチップの
  要約を追加(詳細はskill参照の導線)

### 2026-07-22 ドックチップの開閉フラグは showDocked と特定(viewer/exposeではない)

- ユーザー実機確認で「viewer=False では閉じない」「expose=False は×チップになり本来の閉じ方と違う」
  と判明。ユーザーにフレッシュ配置してもらった glsl1 の**開いてる pixel と閉じてる compute の
  全プロパティを機械的に差分**し、**開閉の実体は docked側opの `showDocked`**(↑開=True/↓閉=False)
  と特定。expose/viewer/display は開閉と無関係(全て同値)だった
- CoreWLANScan の自動生成を `expose=True + viewer=True + showDocked=False` に修正(=GLSLの
  compute DATと同じ「閉じた↓チップ」が既定)。ライブ適用した cwchk でユーザーが「閉じてます!」を確認。
  リビルド・インストール済み(次回TD起動から新規配置に適用)
- pitfalls.md / CLAUDE.md本文 / README の誤った記述(viewer=Falseで閉じる)を訂正

### 2026-07-23 skill を ~/.claude/skills へシンボリックリンク(全セッション共有)

- ユーザー「skillを~/.claude/skills/に移動してセッションを跨いで汎用的に利用できるようにしたい」
- 実体はリポジトリ(`.claude/skills/td-apple-plugin`・git管理)に残し、
  `~/.claude/skills/td-apple-plugin` → リポジトリ実体 のシンボリックリンクを作成。
  単一ソースのまま、他プロジェクトのセッションからも同スキルが利用可能になる
- スキル更新はリポジトリ側を編集すれば即座に全セッションへ反映(コミットで履歴も残る)

### 2026-07-23 Info DAT 自動生成を Cinematic Video / Spatial Video / PDFKit へ横展開

- ユーザー「Cinematic VideoとSpatial VideoのinfoDATも同じ仕組みでTOP opから出せるように。PDFKitも」
- CoreWLANScan で実証した仕組みを **共有ヘッダ `common/PyCallbacksBootstrap.h`(namespace tdpycb)** に
  切り出し、3 TOP に組み込み: 配置(初回cook)で雛形入り Callbacks DAT を自動生成・ドック接続
  (閉じた↓チップ)→ 新設の **`Info DAT` トグル** off→on で隣に `<node名>_info`(Info DAT・
  Operator=本体)を自動生成(二重生成ガード付き)
- ヘッダの罠: TOP SDK は namespace TD → 引数は `TD::OP_NodeInfo*` で修飾(素の OP_NodeInfo だと
  コンパイルエラー)。各 build.sh に Python include + `-undefined dynamic_lookup` を追加
- **実測(M2・TD実機・MCP HTTP直送で検証)**: 3 TOP とも配置→ `_callbacks` がドック接続
  (dock=host/expose=True/viewer=True/showDocked=False)、Infodat ON→ `_info` 生成・
  Operator=本体、off→on 繰り返しでも1個のまま、エラーなし
- 検証ノード(cvtest/svtest/pdftest)は TD 上に残置(ユーザーのチップ見た目確認用。確認後削除可)
- 今後同じ仕組みを組み込む時は `common/PyCallbacksBootstrap.h` を使う(使い方はヘッダ冒頭コメント)

### 2026-07-23 TDSensor(Multipeer iOSアプリ)の実機インストール失敗を修正

- ユーザーのXcode実機Runが「not a valid bundle / CFBundleIdentifier無し」(CoreDeviceError 3002/3000)で失敗
- **原因**: project.yml(XcodeGen)が `GENERATE_INFOPLIST_FILE=NO` + 同梱 `Info.plist` を使う設定なのに、
  同梱plistが権限キー(LocalNetwork/Bonjour/Motion)のみで **CFBundleIdentifier 等の標準キーが皆無**だった
- **修正**: Info.plist に標準キーを `$(PRODUCT_BUNDLE_IDENTIFIER)` 等のビルド設定プレースホルダで追加
  (CFBundleIdentifier/Executable/Name/PackageType/Version/ShortVersion/UILaunchScreen 等)
- xcodebuild(automatic signing・team設定済み)→ `xcrun devicectl device install app` で
  **ワイヤレス接続の実機iPhone(iPhone18,1)へインストール成功**(bundleID tokyo.sygnal.tdsensor)
- 教訓: GENERATE_INFOPLIST_FILE=NO で独自plistを使う場合、権限キーだけでなく標準キー一式が必須

### 2026-07-23 CoreText TOP 実装(Appleテキストレンダリング・標準Text TOPより自由で美しい文字)

- ユーザー「Appleのテキストレンダリングを使った、標準Text TOPよりも自由で美しいTOP」→
  **CoreText TOP**(opType `Coretext`・icon CTX・CPUMem TOP・純ObjC++)を新規実装
- **機能**: SFシステムフォント/任意フォント名・**可変ウェイト100〜900**(wght軸・Bold近似フォールバック)・
  Italic・トラッキング・行送り・リガチャ・左右中央/両端揃え・上中下・**日本語縦書き**(右→左段組・
  縦用約物対応)・**カラー絵文字**・グラデーション塗り(2色+角度)・**縁取り**・ドロップシャドウ・
  Text DAT参照(複数行)・任意解像度。非同期ワーカー+シグネチャ検知の家族の型
- **実測(M2・TD実機で視認検証)**: SF W750グラデ+シャドウ+縁取り、ヒラギノ明朝縦書き(約物正置)、
  カラー絵文字+縁取り、Helvetica指定、すべて正しくレンダ。エラー/警告なし
- **踏んだ実バグ(pitfalls反映)**: ①**SFフォントのアウトラインがTDプロセス内で汚染**
  (kCGTextStroke再描画もCTFontCreatePathForGlyphも特定グリフにバー/矢印状ゴミ。単体プロセスでは
  再現せず=切り分けharnessで確定)→ 縁取りは**CIMorphologyMaximumのマスク膨張方式**で解決。
  ②属性ストロークで別文字列を2回レイアウトするのも不整合の元→CTFrame 1つを全パスで使い回す。
  ③CGBitmapContextはゼロ初期化を当てにせずClearRect
- ビルド・署名・常設インストール済み。README(新規+ルート英日一覧)更新
- 次にやること: sample.toe への利用例追加、テキストのアニメーション連携(CHOPでWeight/Trackingを
  駆動するデモ)、text-on-path(パス沿い文字)は将来候補

### 2026-07-23 CoreText TOP: フォントプルダウン/ファイル直接指定/palt(自動文字詰め)追加

- ユーザー要望3点を実装: ①**Font を動的プルダウン**(CTFontManagerCopyAvailableFontFamilyNames・
  先頭'.'の隠しフォント除外・ソート済み・M2実測252ファミリー。既定 "system"=SF。動的メニューは
  非空既定値必須の既知の罠に対応)②**Font File パラメータ**(.ttf/.otf/.ttc を CGDataProvider→
  CGFontCreateWithDataProvider→CTFontCreateWithGraphicsFont で直接ロード・未インストール可・Fontより優先)
  ③**Palt トグル** = OpenType 'palt'(kCTFontOpenTypeFeatureTag/Value + kCTFontFeatureSettingsAttribute
  → CTFontCreateCopyWithAttributes。CSSの font-feature-settings:'palt' 相当)
- **実測(M2・TD実機)**: メニュー252件(モリサワ A-OTF Gothic MB101 Pr6N 等のユーザーフォント含む)、
  Futura.ttc の直接ロード視認、palt ON でヒラギノ角ゴの「」・句読点のアキが詰まることを比較画像で確認
- リビルド・インストール・README更新済み

### 2026-07-23 CoreText TOP: 解像度をCommonページ(Output Resolution)に統一

- ユーザー「解像度はoutputではなく他のtopと同じくcommonで設定」→ 独自Outputページ(Width/Height)を
  廃止し、**`TOP_Output::getSuggestedOutputDesc`**(SDK・Commonページの設定を返す)から取得
- 罠: 入力を持たないTOPで既定 "Use Input" は **127×127** になる → builtin par
  `outputresolution` を `getParString` で読み(builtin parも読める・警告なし)、useinput時は
  1280×720 を既定に。実測: 既定1280×720 / custom 1920×1080反映 / 戻しも正常

### 2026-07-23 CoreText TOP: macOS標準フォントパネル(NSFontPanel)からフォント選択

- ユーザー「font選択をmac標準のfontリストAPIから選択したい」→ `Choose Font (macOS Font Panel)`
  パルスを追加。NSFontManager + NSFontPanel を開き、選択(changeFont:)を Font(PostScript名)/
  Font Size パラメータへ自動反映
- **踏んだ罠(pitfalls反映)**: AppKitコールバックから TD オブジェクトに触ると main thread でも
  **THREAD CONFLICT ダイアログ**(createArgumentsTuple も par 代入も不可)。→ changeFont: は
  C++グローバル(名前/サイズ/シリアル)への保存だけにし、**cook 内で保留選択を検知して PyRun で
  par へ書き戻す**2段構えで解決
- **実測(M2・TD実機・E2E)**: パルス→パネル表示→「American Typewriter」クリック→
  Font='AmericanTypewriter' に自動反映→タイプライタ書体でレンダを確認
- ユーザー提案の「FontBook op」(フォント一覧・選択の専用op)は、Font プルダウン+フォントパネルで
  選択経路が揃ったため保留(必要なら一覧DATとして追加可能)

### 2026-07-23 CoreText TOP: フォント選択をフォントパネルに一本化(プルダウン廃止)

- ユーザー「FontPanelで選んだ結果を表示してほしい。元のfontlistはもういらない」→
  Font パラメータを動的メニュー(252ファミリー)から**プレーン文字列(パネル選択結果の表示欄)**に変更。
  buildDynamicMenu を削除。選択経路は「フォントパネル(表示反映)/ Font File 直接指定 / 手入力」に
- PostScript名指定時の誤警告(family名との不一致で常に警告が出ていた)を修正
  (解決フォントの family と PostScript名 の両方と比較してから警告)
- 実測: パネル選択→Font欄に PS名表示→レンダ反映、PS名手入力でも警告なし

### 2026-07-23 CoreText TOP: フォントパネルが開かない退行を修正

- プルダウン廃止の編集で buildDynamicMenu と一緒に **pulsePressed(パネルを開く処理)まで
  誤削除**していた。復元してリビルド・E2E再確認(パネル表示→選択→Font欄反映)

### 2026-07-23 CoreText TOP: オートフィット(描画領域に収まるまで自動縮小)追加

- ユーザー「描画サイズに収めるようにFontを自動でリサイズ。改行するかどうかも選択したい」→
  `Auto Fit Font Size` トグルを追加。Font Size を上限として、描画領域(解像度-余白)に収まる
  最大サイズを **CTFramesetterSuggestFrameSizeWithConstraints の二分探索(14回)** で求める
- **Word Wrap との連動**: On=折り返した全体が収まるサイズ(実測96.7px・6行) /
  Off=1行のまま幅に収まるサイズ(実測19.2px)。縦書きは幅(段数)/高さを入れ替えて判定。
  実際に使われたサイズは Info CHOP `fitted_size` で取得できる(演出連動用)
- 実測(M2・TD実機): 長文200px指定で両モードとも正しくフィット・エラーなし

### 2026-07-23 CoreText TOP: Text Wrap(改行制御・CSS text-wrap相当)追加

- ユーザー要望で Word Wrap トグルを **Text Wrap メニュー**(wrap/nowrap/balance/pretty/stable)に置換
- **balance**: 通常折り返しと同じ行数を保ったまま折り返し幅を二分探索で最小化 → 各行の長さが均等
  (実測: 13/13/4字 → 10/10/9字)。**pretty**: 最終行が最大行幅の30%未満のとき、行数を変えずに
  幅を2%刻みで詰めて孤立を解消(実測: 最終行4字→6字)。実効幅はHorizontal Alignに従って配置
- 実装は `measureWrap`(CTFrameの行数/最終行幅/最大行幅を計測)+ `effectiveWrapWidth`。
  縦書きは balance/pretty 非対応(wrap扱い)。Autofitはnowrap以外を折り返し前提でフィット
- **TD再起動の罠(再確認)**: quit直後に即openすると同一プロセスが継続して旧バイナリのまま
  パラメータが古い、という事象を踏んだ。**quitはプロセス消滅を確認してからopen**する
- 実測(M2・TD実機): 4モードの比較レンダで挙動確認・エラーなし

### 2026-07-23 CoreText TOP: Line Height変更で1行目まで動く問題を修正

- ユーザー指摘「lineheightを変更すると一番上のlineも移動してしまう」。原因は
  `kCTParagraphStyleSpecifierLineHeightMultiple` が**1行目のベースライン位置にも掛かる**ため
- 修正: 1.0以上は **LineSpacingAdjustment**(行間への加算=1行目不動)、1.0未満は
  MaximumLineHeight で行高自体を詰める方式に変更。natural line height は
  CTFontGetAscent+Descent+Leading から算出
- 実測(M2・TD実機): lh 1.0→1.8 で1行目の位置が完全一致・行間のみ拡大

### 2026-07-23 CoreText TOP: リアルタイムテキスト入力(Edit Text→ライブText DAT)

- ユーザー「Text Fieldに入力したらリアルタイムに反映されて欲しい」。TDの文字列パラメータ欄は
  **Enter/フォーカスアウトで確定**のため、パラメータ入力自体のライブ化は不可(TD仕様)。
  代わりに **Text DAT はタイプごとに内容が反映される**(GLSLシェーダのライブ編集と同じ)ことを利用
- `Edit Text (live Text DAT)` パルスを追加: 現在の Text 内容入りの `<node名>_text`(Text DAT)を
  **開いたドックチップ**として自動生成し Textdat パラメータへ接続(cook文脈のPyRun・二重生成ガード)。
  DATへの入力は1文字ごとにシグネチャ検知→再レンダ
- 実測(M2・TD実機): パルス→DAT生成・接続、1文字ずつの追記が全て即レンダ反映

### 2026-07-23 CoreText TOP: Embolden(合成ボールド)+ Tracking/Line Height 下限拡大

- ユーザー要望2点: ①Tracking スライダー -5→**-100**(重なる詰めも可)・Line Height 0.5→**0**
  (行高1px下限ガード付き)②**Embolden(px)**: 縁取りで実証済みのマスク膨張
  (CIMorphologyMaximum)を使い、**フォントの最大ウェイト以上に太らせる**合成ボールド
- 実装: makeDilatedMask / drawGradientFill / fillThroughDilatedMask に共通化。描画順は
  縁取り(embolden+stroke幅で膨張)→ 合成ボールド(embolden幅・単色/グラデ対応)→ 本文。
  マスクのバッキングは NSData 保持(CGDataProviderの生存問題を回避)
- 実測(M2): SF Weight900 + Embolden 6px でウェイト上限超えの極太を視認、Tracking -40 の重なり詰めOK

### 2026-07-23 CoreText TOP: Edit Text が既存の Text DAT 接続を上書きする問題を修正

- ユーザー「EditTextを押すと coretext1_text に強制的に繋がっちゃう」→ 生成スニペットを
  **Textdat パラメータが空のときだけ生成・接続**するよう修正(接続済みなら何もしない)
- 実測: 自前DAT接続中にパルス→接続維持・_text未生成 / 空でパルス→従来どおり自動生成・接続

### 2026-07-23 CoreText TOP: Embolden/縁取りでカウンター(閉じた内側)が潰れる問題を修正

- ユーザー「embolden使うと閉じた内側が潰れちゃう」。原因は膨張(CIMorphologyMaximum)が
  外側だけでなく o・回 などの閉じたカウンター内にも侵食するため
- 修正: makeDilatedMask に**フラッドフィルによるカウンター保護**を追加。元テキストのアルファから
  「画像端から到達できる外側の背景」を求め、**膨張は外側にのみ反映**(final = 元 ∪ (膨張 ∩ 外側))。
  カウンターは元の形・AAエッジのまま残る。縁取りにも同じ保護が効く
- 実測(M2): 'OQea 回国 8go' Embolden 8px+Stroke 4px で全カウンター開存を視認

### 2026-07-23 CoreText TOP: Embolden時に元グリフの輪郭へ暗い縁が出る問題を修正

- ユーザー「emboldenすると黒い縁が元のフォントの周りに入る」。原因はカウンター保護の
  フラッドフィルが**元グリフのAA縁(半透明画素)を「外側」に含めない**ため、その1px帯だけ
  塗りが薄くなり下地が透けて暗い継ぎ目に見えていた
- 修正: 外側マップを**2px膨張**してAA縁を含める(カウンターは閉領域なので影響なし)。
  白文字+グレー背景(最も見えやすい条件)で継ぎ目消失・カウンター開存を確認

### 2026-07-23 バージョン体系を導入(v0.9.0)+ 全プラグインへ焼き込み

- ユーザー「適切なバージョン番号を提案して」→ **0.9.0**(1.0ではない理由: opTypeが公開APIなのに
  開発初期にリネーム/統合/削除を29コミット分行っており、まだAPIを凍結していないため)
- **3層のバージョン**を導入。単一ソースはリポジトリ直下の `VERSION`(=`0.9.0`):
  1. **リポジトリ**: gitタグ `v0.9.0`。op追加=minor / 修正=patch / opType変更=破壊的
  2. **バンドル**: `CFBundleShortVersionString`=VERSION、`CFBundleVersion`=`git rev-list --count`
     (=ビルド番号)。`common/version.sh` の `td_stamp_all` がビルド後に焼き込む
  3. **オペレータ**: `customOPInfo.majorVersion=0 / minorVersion=9` を**全83ソース**に設定
     (従来は未設定=既定0/1で、TDが .toe との互換警告を出せない状態だった)
- **majorVersion は一斉に上げてはいけない**: TDは .toe 保存値と一致することを期待するため、
  無関係なopまで上げると既存プロジェクトが軒並み非互換になる。**破壊的変更をしたopだけ +1**
- 罠: **Info.plist を後から書き換えると署名が壊れる** → `td_stamp_version` は書込後に必ず再署名
- 逐次ビルドは1プラグイン約75秒×81件=100分かかったため、**xargs -P 6 で並列化**して短縮
- README(英日)に「Versioning / バージョン」節(3層の表 + 0.xの理由 + 1.0.0の条件4項)を追加。
  skill build.md にも規約を追記

### 2026-07-23 CoreText TOP: Truncate(領域に収まらない場合の … 省略)追加

- ユーザー「領域に収まらなかった場合、文字の最後を…にして終わらす事はできますか?」→
  **Truncate メニュー**(off / tail / head / middle)+ **Ellipsis**(省略記号・既定「…」)を追加。
  CSS `text-overflow: ellipsis` 相当
- **実装方針**: CTLine の truncation API ではなく、**収まる最大量を二分探索して st.text を差し替える**
  方式。これで縁取り/グラデ/Embolden/縦書きなど**既存の全描画パスがそのまま整合**する
  (全パスが同じ CTFrame を使う設計のため)。判定は `textFitsInArea`(SuggestFrameSize・
  縦書きは軸入替・nowrapは幅のみ)
- **絵文字/結合文字を割らない**: UTF-16 の切り出し位置を
  `CFStringGetRangeOfComposedCharactersAtIndex` で合成文字境界にスナップ
- Info CHOP に `truncated`(0/1)を追加。実測: 3モードとも領域内に収まり、nowrap 1行・
  カスタム省略記号・絵文字連続でも正しく省略
- **Auto Fit との使い分け**をREADMEに明記(Auto Fit=縮小して全文 / Truncate=サイズ固定で省略)

### 2026-07-23 UIラベルの非ASCII文字化けを修正(Truncate メニュー / PointCloud)

- ユーザー「Truncateのメニューの日本語が文字化けしてるので英語のみにして」→ 実体は**日本語ではなく
  `…`(U+2026)**。TDのUIは**ラベル中の非ASCII記号も化ける**(`…` → `â€¦`・実測)
- Truncate のメニューラベルを `Tail (abc...)` 等の**ASCIIのみ**に修正。あわせてリポジトリ全体を走査し、
  ImageIO PointCloud の `Disparity → Depth` も `Disparity to Depth` へ修正(他に混入なし)
- **パラメータの「値」は非ASCIIでも正常**(Text欄の日本語、Ellipsis既定値の `…` は表示・描画とも問題なし)。
  化けるのは**ラベル**(表示名・メニュー項目名)のみ
- skill naming.md に「UIラベルはASCIIのみ(記号含む)」+ 検出用grepを追記

### 2026-07-23 CoreText TOP: リッチテキスト / ルビ / シェイプ組版を追加(要望 1-2-5)

- ユーザー選択の3機能を実装。全てM2実機で視認検証済み
- **① リッチテキスト(Style DAT)**: 1行=1範囲スタイルのテーブル。範囲は `text`(部分文字列の
  全出現)または `start`/`length`(**合成文字単位**なので絵文字も1文字)。列は
  `r g b a / size / weight / italic / font / tracking / underline / ruby / rubysize / upright`。
  実装は `CFAttributedStringCreateMutableCopy` に範囲ごとの属性を上書き
  (フォントは Style をコピーして `makeFont` を再利用)。実測: 「夜景」だけ赤・150px・W900、
  「Neon」だけ青・下線 を1ノードで描画
- **② ルビ(振り仮名)**: `CTRubyAnnotationCreateWithAttributes` + `kCTRubyAnnotationAttributeName`。
  `kCTRubyAnnotationSizeFactorAttributeName` で相対サイズ。実測: 横書き=上、縦書き=右に正しく配置
- **縦中横は非対応と判明**: Core Text に TCY のAPIが無い。`kCTVerticalFormsAttributeName` を
  false にすると期待と逆(数字が90°回転)だったため、列名を `tcy` → **`upright`**(1=縦組み形で
  正立 / 0=横組み形で回転)に改めて意味を正確化。READMEにも非対応と明記
- **③ シェイプ組版**: `CTFramesetterCreateFrame` は**矩形以外の任意 CGPath を受け付ける**。
  `Layout Shape`(rect/ellipse/rounded/polygon/path)+ Path DAT(uv点列)を追加。
  実測: 楕円・六角形・星形で行長が形に追従。矩形以外では Vertical Align の矩形縮小をスキップ
- **TD再起動を避ける検証テク**: 新バイナリを `/tmp/.../ctv2/` にコピーし、素の `cplusplusTOP` の
  Plugin Path で読ませると**再起動なしで新パラメータを検証できる**(同一パスはTDがキャッシュするため)

### 2026-07-23 CoreText 追加機能のデモを sample.toe に追加

- `/project1/coretext_demo`: `rich`(リッチテキスト)/ `ruby`(縦書き+振り仮名)/ `shape`(星形パス組版)
  の3ノード + 各 Style DAT / Path DAT + README DAT。全てエラー・警告なしで視認確認
- **upright は書体依存と判明**: SF+欧文では正立/回転を切り替えられるが、**ヒラギノ等の和文書体は
  数字の縦組み形が横倒しで固定**され `upright` で変わらない。デモは漢数字(令和八年)に変更し、
  READMEにも「縦書きの年号は漢数字が確実」と明記

### 2026-07-23 CoreText: Shape Path を SOP からも使えるように(SOP to DAT 対応)

- ユーザー「ShapePathはSOPも使える?」→ TOPはSOPをワイヤ接続できないため **SOP to DAT 経由**が答え。
  ただし従来のパーサは `u v` 前提だったので、実用できるよう改良:
  ① **ヘッダ行の自動判定**(数値でないセルがあればヘッダ)② **列名で x/y を自動選択**
  (`x/y`・`u/v`・**`P(0)`/`P(1)`**(SOP to DAT)・`tx/ty`)③ **`Normalize Path to Area` トグル**
  (既定On)で点群のbboxを描画領域へ自動フィット → **SOPの座標スケールのまま渡せる**
- 実測: circle SOP(poly・divs=3 の三角形 / divs=12 の楕円)→ SOP to DAT(extract=points)→
  Path DAT で、行長が形に追従することを視認。SOP編集にリアルタイム追従
- 罠: circleSOP の既定 `type` は `prim`(点を持たない・numPoints=1)。**`poly` にしないと
  SOP to DAT に点が出ない**。SOP to DAT も `extract` を `points` にする必要がある
- sample.toe の `/project1/coretext_demo` に4つ目の例 `shape_sop`(sop_shape → sop_dat)を追加

### 2026-07-23 CoreText TOP: シアー(疑似イタリック)+ 可変フォント slnt 軸を追加

- ユーザー「テキストのシアー機能はある?」→ 当時は Italic(書体の本物のイタリック)のみだったため実装
- **Shear X / Shear Y(度)**: `CTFontCreateCopyWithAttributes(font, size, &matrix, nullptr)` の
  **フォント行列にせん断成分**(c=tan(x), b=tan(y))を入れる方式。**書体を問わず**角度指定でき、
  和文書体(ヒラギノ等)も傾く。グリフ形状自体が変形するので**縁取り/Embolden/グラデ/シャドウも
  自動追従**(全描画パスが同じフォントを使う設計のため)
- **Slant Axis(度)**: 可変フォントの `slnt` 軸。既存の `wght` と同じ variation 辞書に統合
  (weight と同時指定できるよう CFMutableDictionary 化)。**軸を持つ書体のみ有効**で、SFは非対応
  =見た目に変化なしを実測確認(誤解を避けるためREADMEに明記)
- 実測(M2): Shear X +15/-15、Shear Y +10 で日本語含め正しく傾斜。Shear 18°+縁取り5px+
  Embolden 4px+グラデでも全て追従することを視認

### 2026-07-23 CoreText TOP: 4辺個別の余白(Padding Left/Right/Top/Bottom)を追加

- ユーザー「Paddingは4辺別々に指定できる?」→ 当時は共通1値のみ。**既存 `.toe` を壊さない加算方式**で実装:
  実効余白 = `Padding`(共通)+ `Padl/Padr/Padt/Padb`(各辺の追加量・既定0)
- Style に `padL/padR/padT/padB` を持たせ、`makeFrame` / `textFitsInArea` / `fitFontSize` の
  利用可能領域計算を全て4辺基準に置換(`st.padding * 2` の残存参照ゼロを grep で確認)。
  **CG座標は下原点**なので rect の原点yは `padB`、alignV の各分岐も padB 基準に修正
- 実測(M2): 共通20のみ(従来どおり)/ 左+200・上+120 / 右+300(折り返しが早まる)/
  下+200かつ Alignv=bottom(テキスト下端が画像下端から220px上)を全て視認確認

### 2026-07-29 CoreText TOP: 行メトリクス出力 + ライン画像(入力0を各行の下に自動で敷く)

- ユーザー「文字のある位置の下に特定の画像を使ったラインを引きたい」→ A(行メトリクス出力)と
  B(入力画像の自動下敷き)の両方を実装
- **A: 行メトリクス**: `CTFrameGetLines`+`CTFrameGetLineOrigins`+`CTLineGetTypographicBounds` で
  行ごとの u/v/w/h/baseline(TDのuv・左下原点)を取得。Info CHOP に `line{i}/u v w h baseline`
  (32行スロット固定・行数変動でch構成が変わらないように)、Info DAT に px 値テーブル
  (`x_px y_px w_px h_px baseline_px`)
- **B: ライン画像**: maxInputs 0→1。入力0のTOPを execute で downloadTexture(BGRA8・verticalFlip=true)
  →ワーカーで CGImage 化→各行の実位置・実幅に合わせて CGContextDrawImage。パラメータは
  Enable / Apply To(all/first/last)/ Width(行幅/領域幅)/ Offset(負値で文字に重ねるマーカー風)/
  Thickness(0=画像アスペクト維持)/ Extend Ends / Draw Over Text。入力TOPの totalCooks 変化で
  再レンダ(動画ライン素材に追従)
- **実測(M2・TD実機・MCP HTTP直送)**: 2行テキストで各行の実幅に追従した下線、マーカー風
  (負オフセット+延長・文字の後ろ)、最終行のみ+領域幅、Info CHOP(line1/u=0.0222≒余白20/900・
  line2/w=0.409)、Info DAT px表 を全て視認/数値確認。エラー・警告なし
- **実装メモ**: TDのBGRAは非事前乗算なので CGImage 化の前に**アルファを事前乗算**する
  (kCGImageAlphaPremultipliedFirst で縁が暗くならないように)。入力ダウンロードは execute 中のみ
  可能なので SmartRef をワーカーへ move で渡し、getData()(ブロック)はワーカー側で呼ぶ
- 本セッションから touchdesigner MCP ツールが未登録 → [[td-mcp-http-direct]] の HTTP 直送
  (port 9988・run ツール)で検証した

### 2026-07-29 CoreText TOP: ライン画像に水平オフセット(Offset X)を追加

- ユーザー「lineImageを左右にオフセットできるようにして」→ Line Image ページに `Offset X (px)`
  (Lineoffsetx・±200スライダー・正=右/負=左)を追加。Extend Ends 適用後の x に加算するだけの
  素直な実装(幅は不変・位置のみ移動)
- 実測(M2・TD実機・MCP HTTP直送): 0/+80/-80 で下線が行位置から左右へ正しくシフト、
  エラー・警告なし。検証ノード削除済み。常設インストール済み(TD再起動で反映)

### 2026-08-07 Developer ID リリース署名パイプライン構築(tools/release.sh)

- SYGNAL INC. の Apple Developer Program 法人アカウント取得を受け、ストア外配布用の
  リリースパイプラインを構築。ユーザーが Developer ID Application 証明書を作成し
  (`Developer ID Application: SYGNAL INC. (2ZSD5ZZLKB)`・秘密鍵ごとキーチェーンに導入済み)、
  Apple Distribution 証明書(App Store用・今回は不使用)と区別することを確認
- **tools/release.sh**: sign(インストール済み86 pluginを dist/ へコピーし深署名)→ verify →
  dmg(INSTALL.txt同梱・署名付きUDZO)→ notarize(notarytool submit --wait + stapler)。
  深署名はネスト内側から: Frameworks/*.dylib → ネスト .app/.framework(wifiscan-helper.app等)→
  Helpers 直下の Mach-O 実行ファイル(mlxllm-helper)→ バンドル本体。全て
  `--timestamp --options runtime`(公証必須要件)。dist/ は gitignore
- **実測**: 86バンドル全て署名・`codesign --verify --deep --strict` 通過・runtime フラグ+
  Developer ID チェーン確認。DMG 19MB 作成・署名済み。spctl は「Unnotarized Developer ID」
  (=公証だけが残り)
- **踏んだ罠**: ①xargs -P + `export -f` は環境サイズ超過(command line too long)→ スクリプト
  自身を `_sign_one` で再入呼び出し。②`set -o pipefail` 下の `codesign -dv 2>&1 | grep -q` は
  grep -q の早期終了 SIGPIPE で codesign が非ゼロ扱い=全件誤検知 → 出力を変数に取って比較
- **未完(ユーザー作業待ち)**: 公証認証情報の登録。App Store Connect の APIキー(App Manager
  以上)か Apple ID の app用パスワードで `xcrun notarytool store-credentials tdappleops` を
  一度実行してもらう → 以後 `./tools/release.sh notarize` で submit→staple まで自動

### 2026-08-07 公証(Notarization)完了 — 配布可能なリリースDMGが完成

- ユーザーが `xcrun notarytool store-credentials tdappleops` を登録 → `./tools/release.sh notarize`
  で `dist/TDAppleOps-v0.9.0.dmg` を提出。**status: Accepted**(submission id
  ace53cd0-916c-4d6f-9a52-e6a28d0321be)→ stapler staple 成功
- **Gatekeeper実測**: quarantine属性を付けたDMG本体・DMGから取り出した .plugin とも
  `spctl` が **accepted / source=Notarized Developer ID**。=ダウンロードした他人のMacでも
  警告なしで使える状態を確認
- README(英日)のバージョン節に「リリースビルドは Developer ID + notarize 済み」を追記、
  1.0.0条件の該当項目を完了に更新
- 配布時の注意(既知): 配布版は署名が変わるためTD初回ロード時にプラグイン承認ダイアログが出る。
  wifiscan-helper.app は位置情報許可の再承認が一度必要
- 残タスク(任意): GitHub Release への DMG 添付(公開操作のためユーザー確認待ち)

### 2026-08-07 未検証17プラグインを develop ブランチへ分離(リリースは検証済み69本のみ)

- ユーザー指示: 未検証プラグインは develop ブランチに移し、リリースは検証済みのみにする
- **develop ブランチを main から作成して push**(全プラグイン入りの完全な状態を保持)。
  未検証プラグインの開発継続は develop で行う
- **main から17フォルダを git rm**: AVAudioMixer / AVAudioSpatial / AudioToolboxMix /
  CaptionAuthor / ColorSync / CoreImageKeystone / GameplayKitAgents / GameplayKitPath /
  ImageCapture / MetalFrameInterp / MetalMPSAnalyze / Phase / Shazam / SpatialVideo /
  SwiftUI / SwiftUIPanel / UIWidget。依存する palette/NativePanel.tox・SwiftUIButton.tox
  (SwiftUIPanel/UIWidget前提)も main から削除。README(英日)の該当17行を削除
- **tools/release.sh に EXCLUDE リスト**(17バンドル名)を追加し、sign 時にコピーから除外
- **リリース再構築**: 69バンドル署名→全数verify OK→DMG 18MB→公証 **Accepted**→staple→
  spctl accepted(Notarized Developer ID)
- 注意: ローカルの常設Pluginsディレクトリは全86本のまま(開発環境は不変)。sample.toe の
  examples には除外17opの利用例が残っている(リリースDMGだけ導入した環境ではその17例が
  Unknown operator type になる)→ リリース用に examples を分けるかは今後の課題

### 2026-08-07 リポジトリを Apple-Frameworks-for-TouchDesigner へ改称(一般公開準備)

- ユーザー「公開時に分かりやすい名前に」「macOSのフレームワーク/ライブラリを使ったpluginと
  伝わる名前」→ 候補比較の結果 **`Apple-Frameworks-for-TouchDesigner`**(表示名
  "Apple Frameworks for TouchDesigner")に決定。「for Mac/for TouchDesigner」形式は
  Apple商標ガイドラインの推奨形でもある
- `gh repo rename` で改称・説明文も更新。**旧URLはGitHubが自動リダイレクト**するため、
  既存81バンドルに焼き込み済みの opHelpURL(旧TDAppleOps URL)もHelpボタンから飛べる
- リポジトリ内の旧URL参照68ファイル(ソースの opHelpURL・README・release.sh)を新URLへ一括置換。
  README(英日)のH1を "Apple Frameworks for TouchDesigner" に変更。ローカル remote URL 更新済み
- release.sh の成果物名も統一: `dist/Apple-Frameworks-for-TouchDesigner-v0.9.0.dmg`。
  新名称DMGを再公証 → **Accepted・staple・spctl accepted** を確認
- **注意(develop運用)**: develop は全プラグイン入りで維持している。main には17フォルダ削除
  コミットがあるため **main→develop の wholesale merge は厳禁**(削除が伝播して未検証
  プラグインが消える)。共通修正は cherry-pick で運ぶこと
- 注意: keychain の notarytool プロファイル名は `tdappleops` のまま(ローカル専用・変更不要)

### 2026-08-07 GitHub Release v0.9.0 作成 + DMG添付

- 既存の v0.9.0 Release(7/25作成・旧コミット・79 operators表記・アセット無し)は develop分離/
  公証/改称より前の陳腐化した状態だったため削除し、タグを現行HEADへ張り直して再作成
- **Release v0.9.0**: 英日リリースノート + `Apple-Frameworks-for-TouchDesigner-v0.9.0.dmg`
  (18MB・検証済み69プラグイン・Notarized Developer ID)を添付
  https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/releases/tag/v0.9.0
- リポジトリはまだ **PRIVATE**。一般公開は Settings → Visibility を Public に切り替えた時点

### 2026-08-07 起動時プラグインエラーの原因究明: OP_CommonAPIVersion 不一致(TDダウングレード)

- 症状: TD起動時に **CoreTextTOP.plugin / ImageIOPointCloudSOP.plugin** だけが
  "provides an invalid opType name" で拒否される。opType 文字列(`Coretext`/`Imageiopointcloud`)は
  規約通りで、バイナリにも正しく埋まっている
- **真因**: TD の `setAPIVersion()` は `apiVersion = version;` の直後に範囲チェックし、
  **不一致なら早期returnする**。その結果 opType が空文字のままになり、TDは
  「invalid opType name」という**原因と無関係に見えるエラー**を出す。
  この2つだけが **OP_CommonAPIVersion = 2**(新しいTD SDK)でビルドされており、
  ユーザーが **TouchDesigner をダウングレード**したため現行TD(2025.32280・common=1)が拒否していた
- **診断ツール `tools/apiscan.c`**: PluginInfo構造体の**先頭int32がapiVersion**で、
  Min/Max=0 のゼロ初期化バッファを渡すと **opTypeポインタに触れる前に早期return**する性質を利用し、
  バンドルが宣言しているAPIバージョンを安全に読み出す。全69本を走査してこの2本だけを特定
- **修正**: 2プラグインを現行SDKで再ビルド(common=1確認)→ 署名・インストール → TD再起動で
  **両方ロード成功・coretext_demo/ImageIOPointCloud例ともエラー0**を確認
- **release.sh を2点修正**:
  1. **配布物の収集元をユーザーの常設Pluginsフォルダ → リポジトリの build/ 成果物に変更**。
     常設フォルダから集めていたため **Azure Kinect(K4ABody/K4ADepth/K4ASelect)** という
     サードパーティ製3本がDMGに混入していた(ユーザー指摘)。`git ls-files '*/build.sh'` から
     収集するので main が追跡するものだけが対象になり、EXCLUDEリストも不要になった(69→**66本**)
  2. **verify に APIバージョン検査を追加**(apiscanで全数 common を現行SDKと突合)。
     同じ事故を出荷前に止められる
- 新DMG(66本)を再公証(Accepted・staple・spctl accepted)し、GitHub Release v0.9.0 の
  アセットを差し替え済み

### 新規ハマりどころ

- **TDの「invalid opType name」エラーは、opType文字列が正しくても出る**。真因が
  `setAPIVersion()` の失敗(SDKバージョン不一致)であることが多い。TDのバージョンを
  上げ下げした環境では、**古い/新しいSDKでビルドされたバンドルが混在**して一部だけ拒否される。
  `tools/apiscan.c` で各バンドルの宣言APIバージョンを読み、現行SDKの
  `OP_CommonAPIVersion`(CPlusPlus_Common.h)と一致するか確認する。直し方は**当該プラグインの再ビルド**
- **リリース物をユーザーの常設Pluginsフォルダから集めてはいけない**(サードパーティ製が混入する)。
  必ずリポジトリのビルド成果物から集める

### 2026-08-07 サンプル映像8本をAI生成して同梱・examplesを全面的に張り直し

- ユーザーが **Adobe Firefly(Google Veo 3.1 Fast)** で提案どおり8本を生成し `Assets/` に追加
  (いずれも 1280x720 / 24fps / 8秒・合計約28MB・**コミット可能**)。従来の実写素材
  (`test_video_1.mp4` 183MB 等)は巨大でgitignoreだったため**リポジトリに存在せず、
  examplesの映像系は全て壊れていた**。これが解消した
- **共有ソースを1本→9本に**: `examples/media_{people,hands,animals,throw,objects,cutout,
  horizon,contours}`(+従来の `media_video` は people を指す汎用)。各例の `src`(Select TOP)を
  用途に応じて張り替え(**28コンテナ**)
- **実測(M2・TD実機)— 全て新素材で検証**:
  - VisionPose **5人**・VisionFace **5顔**(people)
  - VisionHand **2手**(hands)
  - **VisionAnimalPose 2匹**(animals)← **素材が無く未検証だったopの初の実データ検証**
  - **VisionTrajectory 4/4 valid**(throw)← **こちらも初の実データ検証**。AI生成の弾道でも
    `VNDetectTrajectoriesRequest` が成立した
  - CoreML DAT(YOLO)= **apple / laptop / cup**、VisionClassify = coffee / drink / liquid(objects)
  - VisionRect 4矩形(objects)、VisionContours 8プリム/893点(contours)
  - VisionHorizon valid=1・角度3.5°、VisionAesthetics score **0.784**(horizon)
  - VisionSubject: ブリキロボットのカットアウトを**視認確認**、VisionTrack: 再Startで
    u=0.512/v=0.466/conf=1.0 で追従(cutout)
- **踏んだ罠**: ①Vision系CHOPのスロットチャンネル名は **`body1:valid`(コロン)**。
  `body1/valid` では取れず「検出0」と誤診する ②examplesは出力が使われないため
  **毎フレームcookされない**。検証は Execute DAT(onFrameEnd)で駆動する。特に
  VisionTrajectory/VisionTrack は**連続フレーム必須**で、間隔を空けたforce cookでは絶対に成立しない
  ③VisionTrack の `Top` がコンテナを指したままだった(→`src`に修正)。初期bboxは被写体に合わせる
- `afm_describe_demo` が参照していた削除済み `test_image_1.jpg` を sample_people.mp4 へ差し替え
  (classify = people / adult / clothing を確認)。削除済み2素材はgitからも除去
- **ライセンス表記**: README(英日)の License 節に「Sample media / サンプル素材」小節を追加。
  Firefly生成のため第三者の肖像権処理・ロケ許可が不要で、人物は合成、リポジトリと同じMITで配布する旨を明記

### 2026-08-07 Vision系OPに Aspect Correct UVs を追加(Body Track CHOP 互換・Ortho Width=1 対応)

- ユーザー要望「uv を入力画像のアスペクト比に応じて正しい比率で出力したい」→「**Body Track CHOP の
  Aspect Correct 機能と同じように**」→「**インスタンシングして Ortho Width=1 のカメラで
  映像に重ねられる仕様に**」
- TD公式ドキュメントで Body Track CHOP のパラメータを確認: `aspectcorrectuv` / ラベル
  "Aspect Correct UVs" / **Toggle・既定Off**。説明は "Rescales the u and v positions so that
  they have the correct aspect ratio of the input image."
- **共通ヘッダ `common/AspectCoords.h`**(namespace tdaspect)を新設。Mapper + appendAspectCorrect()
  テンプレートで10プラグインに同じ実装を配る
- **変換式(Ortho Width=1 で合う向きを選定)**:
  `u' = u`(0〜1のまま) / `v' = 0.5 + (v-0.5)/aspect` / v方向の距離は 1/aspect・u方向は不変。
  **u を 0〜1 に保つのが要点** — Instance TX=u-0.5 / TY=v-0.5 が
  Ortho Width=1 の画面いっぱいに一致する(縦視野は自動的に 1/aspect になるため)。
  u を aspect 倍する実装も試したが、その場合 Ortho Width を aspect に変える必要があり要件に合わない
- **対応10プラグイン**: VisionPose / VisionHand / VisionFace / VisionAnimalPose / VisionTrack /
  VisionPose3D(u,v のみ。tx,ty,tz はメートルなので不変)/ VisionRect(bbox+四隅)/
  VisionTrajectory(検出点・投影点+放物線係数 a,b は 1/aspect・c は y 変換)/
  CoreML DAT(bbox)/ VisionBarcode DAT(bbox+四隅)。信頼度・角度・IDは非変換
- **実測(M2・1280x720・同一フレームで厳密比較)**: u=0.81578→0.81578(不変)、
  v=0.68205→0.60240(= 0.5+(0.68205-0.5)/1.7778 に厳密一致)、bbox height 0.57449→0.32315
  (=÷1.7778)、width 不変
- **視覚検証**: VisionPose の全uvを Shuffle(Sequence All Channels)で 175サンプルの tx/ty にし、
  Geo インスタンシング → **Ortho Width=1 のカメラ** → Render → 映像に Composite。
  **On で5人全員の関節に赤点が正確に重なる**ことを視認。Off では点が縦に伸びて頭が人物の上に浮く
- 10件とも再ビルド・署名・インストール・**TD再起動後に全10opでパラメータ生成を確認**。各README更新
- **踏んだ罠**: ①python の文字列 replace はアンカーが1文字でも違うと**黙って何もしない**。
  今回コメント行を含むブロックを見落として2回無駄にビルドした → **assert で必ず検証する**。
  ②`replace(..., 1)` は最初の出現に当たる。`const int perHand` のように getChannelName と execute の
  両方にある変数宣言は**別関数側に入ってしまう**(コンパイルエラーで気づけたが要注意)。
  ③Shuffle CHOP で「N個の1サンプルch → 1chのNサンプル」は `seqall`(Sequence All Channels)

### 2026-08-07 v0.9.1 リリース(patch判断の根拠 + 配布時バージョン焼き直し)

- ユーザー提案で **0.10.0 ではなく 0.9.1**(patch)に決定。根拠: 追加した Aspect Correct UVs は
  **既定Offの追加パラメータで後方互換**(既存 .toe の挙動は不変)。このリポジトリでは
  オペレータの `customOPInfo.minorVersion` が .toe との互換判定に使われるため、
  **互換性が変わっていないのに minorVersion を上げると .toe 側へ無用な差分が伝わる**。
  patch なら minorVersion=9 据え置きでリポジトリ版と自然に揃う。差分の大半が実際バグ修正
  (起動エラー・K4A混入)であることも patch 寄り。0.x は「いつでも変わりうる」前提なので許容
- **release.sh に配布時のバージョン焼き直しを追加**: 収集後・**署名前**に全バンドルの
  Info.plist へ現在の VERSION と git コミット数を書き込む。従来は「各プラグインを最後に
  ビルドした時点の版」が残り、VERSION を上げても再ビルドしたものだけ新版になっていた。
  verify にも `CFBundleShortVersionString == VERSION` 検査を追加
- 66バンドル署名・全数verify(署名/Hardened Runtime/APIバージョン/**版一致**)・DMG 18MB・
  公証 Accepted・staple・spctl accepted。**Release v0.9.1 を作成**(英日ノート付き)
- **v0.9.0 のDMGは取り下げた**: 開発中に中身を2度差し替えた結果タグと不一致になっていたため、
  アセットを削除し「v0.9.1 に置き換わった」注記を追加(タグとリリース自体は履歴として残置)

### 2026-08-07 VisionText DAT にも Aspect Correct UVs を追加

- ユーザー指示。これで **uv を出す Vision系OPは全11件**が対応(Pose/Hand/Face/AnimalPose/Track/
  Pose3D/Rect/Trajectory/Text + CoreML DAT + Barcode DAT)
- 出力テーブルの `u,v,width,height`(テキスト領域のbbox)へ適用。text/confidence は非変換
- **実測(M2・TD実機)**: Text TOP に "COFFEE" を描いて入力し OCR。Off で
  u=0.5008 v=0.4931 w=0.4828 h=0.1750 → On で **v=0.4961 / h=0.0984**。
  理論値 `0.5+(0.4931-0.5)/1.7778 = 0.4961` / `0.1750/1.7778 = 0.0984` と完全一致。
  u と width は不変。confidence=1.000 で認識も正常
- **VisionSaliency は意図的に対象外**: あのuv系(オートフレーミングのクロップ矩形)は
  **Crop TOP に直結する前提**で生の0〜1画像座標である必要があるため。補正すると本来の用途が壊れる
- **OCR素材の方針メモ**: 動画生成AIは文字レンダリングが不安定で「OCRが失敗したのか元が
  崩れているのか」を切り分けられない。**答えが既知の素材(Text TOP でレンダした文字列)**を
  正確性検証に使うのが確実(VisionBarcode の利用例が CoreImage Code TOP 生成QRを使うのと同じ考え)。
  日本語検証は特にこの方式が必須(生成AIに漢字・かなを正しく描かせるのは非現実的)
- 注意: この変更でリリース v0.9.1 のDMGは1コミット遅れている。サンプル映像4本(crowd/faces/
  face/ballet)の検証と合わせて次回まとめて配布物を更新する

### 2026-08-07 VisionSimilarity / CoreImageBokeh / CoreImageEnhance を develop へ退避

- ユーザー判断で3件を main から外し、非公開の develop ブランチで開発継続とする
  (2026-08-07 の17件と同じ扱い。公開リリースは検証済みのみ、の方針)
- **手順の要点**: develop は main より前の状態(opHelpURL の旧URLのまま)だったため、
  **先に develop 側を main の最新状態へ同期してから** main で削除した。
  `git worktree add` で develop を別ディレクトリにチェックアウトし、
  `git checkout main -- <3フォルダ>` → コミット → push。作業ツリーを汚さずに済む。
  **main→develop の wholesale merge は厳禁**(main の削除コミットが伝播して develop の
  未検証プラグインが消える)ので、この folder単位の checkout が正しいやり方
- main から3フォルダを git rm、README(英日)の該当3行を削除。release.sh は main 追跡分
  だけを集める仕様なので EXCLUDE の追加は不要(配布は 66 → **63op**)
- 注意: sample.toe の examples には除外した20op(17+3)の利用例が残っている。main だけを
  clone した人が sample.toe を開くとその20例が Unknown operator type になる

### 2026-08-07 VisionAesthetics / CoreLocation Beacon も develop へ退避

- 前エントリと同じ手順(worktree で develop へ `git checkout main -- <folder>` して同期 →
  main で git rm → README英日の行を削除)。**同期を先に行うこと**が要点
- 公開対象は **61op**(main 追跡59フォルダ。Multipeer CHOP/DAT が In/Out で2バンドルずつ)
- develop のみの非公開は計22op

### 2026-08-08 ビルドシステムの重大バグ(6件が無言でビルド不能)+ CoreImageCode の bypass 復帰不良

- ユーザー報告「CoreImageCode を bypass/無効化して戻すと黒画像のまま」
- **原因1(プラグイン側)**: `execute` が `if(myResult.serial==myUploaded) return;` で
  **一度アップロードしたら二度と上げない**構造だった。通常cook中はTDが前回テクスチャを保持
  するので露見しないが、bypass/無効化でそれが破棄され、再有効化しても新規アップロードが
  起きないため黒のまま(パラメータを変えると再生成→serial更新→復帰する症状と一致)。
  → キャッシュ済みの結果を**毎execute アップロード**するよう変更(空のときだけ return)
- **同じ構造が18 TOP にある**(`myUploaded`/`myUploadedSerial` で grep)。動画入力のものは
  次フレームで自己回復するが、**静止画入力や生成系(CoreImageCode)は復帰しない**。
  他TOPへの横展開は次の課題
- **原因2(ビルドシステム・より重大)**: `common/build_plugin.sh` は **zsh専用**
  (`${(%):-%N}`・`arr+="x"` など)なのに、6件の build.sh が `#!/bin/bash` だった。
  bash から source すると `bad substitution` → `set -e` で**何もビルドされないまま無言で終了**。
  終了コードも0に見える出力だったため気づかず、**2026-07-23(version.sh 導入)以降
  CoreImageCode / CoreAudioProcessTap / CoreWLAN / Spotlight / SpeechSynth / VisionHorizon の
  6件はビルドされていなかった**(=リリースDMGのこの6件は07-23以前のバイナリで、
  opHelpURL の新URL等が入っていない)。6件の shebang を zsh に統一し、共通ヘルパ冒頭に
  「このファイルは zsh 専用・呼び出し側も #!/bin/zsh にすること」を明記。6件とも再ビルド済み
- **検証中に TouchDesigner がクラッシュ**(04:37・EXC_BAD_ACCESS)。クラッシュスタックは
  **libOPUI/libUI のみでプラグインのフレームは無し**=TD側UIのnull参照。`CrashAutoSave.sample.toe`
  が生成されている。bypass再検証はTD再起動後に持ち越し

### 2026-08-08 bypass復帰の黒画像を全17 TOPへ横展開修正 + TD実機検証

- CoreImageCode 単体の修正を、同じ構造を持つ **CPUMem TOP 全17件**へ展開:
  CoreImageHDR / CoreImageRAW / CoreML / CoreMLSAM2 / CoreText / ImageIOFileIn /
  MetalDenoise / MetalUpscale / PDFKit / VisionFlow / VisionSegment / VisionSubject /
  VisionSaliency / ScreenCapture / CinematicVideo(以上15件は
  `myResult.serial == myUploaded ||` の条件を機械的に除去)+ **CoreMLImageGen /
  ImagePlayground の2件は構造が違う**(serial一致のときだけ変換+アップロードする形)ため、
  **取り出した画素を `myPixels` にキャッシュし、アップロードだけ毎cook行う**よう書き換えた
  (ヘルパへの `sd_copy_image`/`pg_copy_image` は従来どおり新画像のときだけ呼ぶ)
- **TD実機検証**: CoreImageCode = bypass往復3回でもQRが復帰(パラメータ変更なし)。
  CoreText = bypass解除後にテキスト復帰。いずれも修正前は黒だった
- **検証設計の注意**: VisionSubject を `play=0` の静止入力で試したところ **before も黒**で
  不成立だった(入力が1度も更新されず初回解析が走らないため)。bypass検証は
  **必ず「修正前に生成できていること」を先に確認**してから行う
- 17件とも署名・APIバージョン検査つきでインストール済み
- 注意: この17件+先の6件(ビルド不能だったもの)でリリースDMGは大きく遅れている。
  次回配布時にまとめて更新する

### 2026-08-08 sample.toe → demo.toe に改称 + examples を /project1 直下へフラット化(ユーザー編集)

- ユーザーが利用例を再編。**`/project1/examples` コンテナを廃止し、1オペレータ1コンテナを
  `/project1` 直下へ**(現在54コンテナ)。共有ソースの `media_video` も廃し、**各コンテナ内に
  素材の Movie File In を直接置く**方式(例: CoreML TOP の `sample_crowd_2`)に変わった
- ファイル名は `sample.toe` → **`demo.toe`**(途中経過の `example.toe` はユーザー環境に残置)。
  git は `sample.toe` を削除し `demo.toe` を追跡。README(英日)の参照6箇所を更新し、
  `/project1/examples` の記述も削除。`CrashAutoSave.sample.toe` も削除
- **CoreML CHOP の利用例を新スタイルで作成**: `sample_street(Movie File In) → Coreml1 → out` +
  note。MobileCLIP S0 画像エンコーダで映像を512次元埋め込みに変換。
  実測 valid=1 / count=512 / value0=0.0246。**Max Values を 256→512** に上げてモデルの
  全次元を出す(既定256だと打ち切られる。count はモデル本来の要素数を返すので突き合わせ可)
- 注意: TD の作業中に構成が変わることがあるので、examples を触る前に毎回
  `/project1` の子を確認する(`/project1/examples` はもう無い)

### 2026-08-08 demo.toe をカテゴリ別グリッドへ整理 + 利用例の不足を洗い出し

- `/project1` 直下の46コンテナを **ルート README と同じ10カテゴリ**の行に並べ替え。
  各行の左端に `_cat_01`〜`_cat_10` のラベル Text DAT を置き、旧 `_cat_IO/_cat_Audio/
  _cat_CoreML/_cat_Vision` は撤去。インフラ(_README / media_audio / td_mcp_server)は最下段へ
- `_README` を索引に更新(カテゴリ表・不足14件・外部モデルが要るOP・注意)
- **利用例が無いプラグイン14件**(main の60opに対して): Cinematic Video / CoreImage HDR /
  CoreImage RAW / ImageIO File In / ImageIO PointCloud / ImagePlayground / Vision Document /
  CreateML / CreateML Training Recorder / CoreML Motion / CA Process Tap / CoreWLAN /
  CoreWLAN Scan / Spotlight
  - 素材/権限が要るもの(Cinematic=実Cinematic動画、HDR/RAW/FileIn/PointCloud=実写HEIC・DNG、
    CoreWLAN系=Wi-Fi環境、CA Process Tap=音を出すアプリ)と、すぐ作れるもの
    (Vision Document / CreateML / Spotlight / ImagePlayground)に分かれる
- **MetalFrameInterp の利用例が残っていた**が、これは develop 送りで main には無い。
  公開版では Unknown operator type になるため要削除(ユーザー判断待ち)
- MCP run の癖: **exec のスコープ分離でリスト内包表記から外側の変数が見えない**
  (`NameError: name 'placed' is not defined`)。明示的な for ループで書く

### 2026-08-08 demo.toe: カテゴリ再編(CoreML統合・demo廃止)+ 利用例3件を追加

- ユーザー指示でカテゴリを再編:
  - **CoreML系を1カテゴリに統合**(06 CoreML = CoreML TOP/CHOP/DAT・SAM2・ImageGen)。
    従来 02/03/06 に散っていたものを集約
  - **「Demos」カテゴリを廃止**し、作例を主役OPのカテゴリへ振り分け
    (mlx_vision_demo→08 Language & Text、applescript_demo/shortcuts_demo→10 System)
  - 09 を「3D / Geometry / Document」、10 を「System / Devices / Network」に分割(旧09が13件で長すぎた)
- **利用例3件を追加**:
  - **Vision Document**: `Assets/sample_document.png`(新規・見出し/段落/3列の表/箇条書きを含む
    文書画像・約690KB)→ 31行6列(type/page/index/row/col/text)を抽出。
    **このOPは TOP ではなく File パラメータ(画像ファイルパス)を受ける**のが要点
  - **Spotlight**: Query="CoreText"・Search パルスで **21件**ヒット(Mode=Name)
  - **ImagePlayground**: Prompt+Style(illustration)を設定。Generate はユーザーが押す前提
    (生成は前面GUIアプリ内でのみ動作)
- 素材生成のメモ: `cupsfilter` は **HTML→PDF に非対応**。AppKit の
  `NSAttributedString(html:)` → NSImage → PNG で文書画像を作った(swiftc の小スクリプト)
- 残る未着手は11件(素材・環境・学習が要るもの)。_README に分類して記載

### 2026-08-08 VisionSegment を develop へ退避

- 手順は従来どおり(worktree で develop へ `git checkout main -- VisionSegment` して同期 →
  main で git rm → README英日の一覧行を削除)。今回は **「Nvidia専用OPの macOS 代替」表**にも
  参照があったので併せて削除(この表に残るのは Pose / Upscale / Flow / Face の4件)
- 公開対象は **59オペレータ**(main 追跡57フォルダ)。develop のみの非公開は計25op
- demo.toe には VisionSegment の利用例が残っている(MetalFrameInterp と同じ状態)。
  公開版では Unknown operator type になるため、まとめて削除するかはユーザー判断待ち

### 2026-08-08 LLM AFM の利用例に Tool Calling を追加

- `/project1/LLMAFM` に **ツール呼び出しの往復**を組み込んだ:
  `sensor`(Constant CHOP: temperature/humidity)+ `handler`(Execute DAT)+ `Llmafm1`
  - Enable Tool Calling / Tool Name=`get_sensor` / Tool Parameters=`name:string`
  - handler が `pending_tool_args` を検知 → sensor CHOP から値を引いて Tool Result へ
    JSON を書き → Return Tool Result をパルス
- **実測**: 「Use the get_sensor tool with name "temperature"...」→
  **"The current temperature is 42.0°C."**、humidity に変えると **"The humidity value is 58.0."**。
  LLM が TD のライブ値を読んでいることを確認
- **踏んだ罠(既知の再確認)**: 最初 `datexecuteDAT` の `onTableChange` でハンドラを書いたら
  **pending_tool が出たまま止まった**。非同期な C++ DAT の更新では onTableChange が
  安定して発火しない → **Execute DAT の onFrameEnd で毎フレーム polling** に変更して解決
- **踏んだ罠(新規)**: オンデバイスモデルは小さく、「What is the current temperature?」のような
  曖昧な聞き方だと**ツールを使わず「センサーがありません」と答える**。プロンプトでツール名を
  明示すると確実に呼ぶ。note にも明記した

### 2026-08-08 LLM MLX の利用例が動かない不具合を修正(Model が式モードで SyntaxError)

- ユーザー報告「LLMMLXが動いてない?」→ `Llmmlx1` に
  `Error: SyntaxError: invalid decimal literal` が出ていた
- **原因**: `Model` パラメータが **Expression モード**なのに、式ではなく
  `gemma-3-4b-it-qat-4bit` という**裸の文字列**が入っていた。Python が
  `gemma - 3 - 4b - ...` の数式として解釈して構文エラー(4b が不正な数値リテラル)
- **修正**: `project.folder + '/models/gemma-3-4b-it-qat-4bit'` という正しい式に。
  ローカルフォルダ指定なので完全オフラインで動く
- **検証(M2・TD実機)**: Load → Info DAT の `status=ready`(ヘルパプロセス
  `mlxllm-helper --serve` も起動確認)→ Submit「Name one primary color.」→ **"Red"**
- 例に **`info`(Info DAT)を追加**。status(loading model / ready)が見えないと
  「動いていない」のか「ロード中」なのか判別できないため
- note に**この罠を明記**: リポジトリIDを直接書くなら**クォートで囲む**か
  パラメータを定数モードに戻すこと。VLM は gemma 系4bitでは不可(Qwen2-VL 系を使う)

### 2026-08-08 models/ をREADMEだけ共有・各利用例のnoteにモデル入手先を明記

- ユーザー指摘「models フォルダは git で共有されていない?」→ そのとおりで完全に未追跡だった
  (.gitignore の `models/`)。**フォルダ自体を追跡するため `models/*` + `!models/README.md`** に変更
- **`models/README.md` を新設**(唯一追跡されるファイル)。利用例が期待する**ファイル名 → 用途 →
  入手先URL** の表と、`hf download <repo> --local-dir models/<name>` の手順、
  ライセンスは各モデル固有である旨を記載
  - DepthAnythingV2 / MobileCLIP(image+text)/ YOLOv3 / SAM2.1-tiny /
    Stable Diffusion 2.1 base / gemma-3-4b-it-qat-4bit / Qwen2-VL-2B(VLM用)
- **demo.toe の該当6例(CoreML TOP/CHOP/DAT・SAM2・ImageGen・LLM MLX)の note に
  入手先ブロックを追記**。ファイル名・URL・hf download コマンドをその場で読める
- ついでに note に残っていた**古い共有ソース表記**(`shared via examples/media_*`)を除去。
  examples フラット化で `media_video` 方式は廃止済みのため実態と食い違っていた
- ルート README(英日)のモデル案内を `models/README.md` への導線に更新

### 2026-08-08 demo.toe を9カテゴリへ再編・ノードを色分け

- ユーザー指定のカテゴリで配置し直し、**コンテナの色もカテゴリで統一**:
  01 Vision Pose系(青) / 02 その他Vision(青緑) / 03 LLM(紫) / 04 CoreML(藍) /
  05 画像生成(赤紫) / 06 描画(橙) / 07 Sound(緑) / 08 Text(黄緑) / 09 その他(灰)
- 1行8個で折り返し、超える分は同カテゴリ内の2行目へ(02=11件、09=12件)。
  ラベル `_cat_01`〜`_cat_09` も同じ色にして行頭に配置
- 分類の判断: **01 は「ポーズ/キーポイント推定」**として VisionPose / Pose3D / Hand /
  Face / AnimalPose を入れた(VisionFace は検出+ランドマークなので境界。02へ移したい場合は
  1行変えるだけ)。08 Text は NLP 系(TextAnalyze / Translate)で、OCR の VisionText と
  文書構造の VisionDocument は Vision なので 02 に置いた
- ユーザー側で VisionSegment / MetalFrameInterp / mlx_vision_demo / shortcuts_demo の
  各コンテナは削除済み、applescript_demo → applescript にリネーム済みだったので、
  develop送りopの参照切れは demo.toe から解消された
- _README を新カテゴリ表+色の対応+外部モデルが要るOP+未着手11件の索引に更新

### 2026-08-08 VisionPose 利用例: 骨格線の生成を追加(データは完成・描画は未解決)

- ユーザー要望「点だけでなく関節を繋いで描画したい」
- **`geo2/skeleton`(Script SOP)を追加**。Vision Pose CHOP を読んで骨(19本)の線分を生成:
  骨盤→胴→首→鼻、目・耳、肩→肘→手首、腰→膝→足首。**両端の confidence が
  Minconf 未満なら描かない**(Vision に無い つま先/かかと/指 は confidence=0 なので自動的に除外)
  - 実測: 5人分で **95プリム / 190点**。座標も検証済み(x≈0.25, y≈-0.04..0.1 と妥当)
  - Aspect Correct UVs = On 前提で `-0.5` するだけで Ortho Width=1 のカメラに載る設計
- **踏んだ罠**:
  ① Script SOP のポリゴンは `appendPoly(2, addPoints=False)` → `poly[0].point = pa` が正しい。
     最初 `appendPoly(0,...)` + `line.append()` と書いて **1本しか生成されなかった**
  ② Script SOP は入力が無いと毎フレーム cook しない。custom par `Trigger` に
     `op('../Visionpose1').totalCooks` の式を入れて dirty にする
  ③ **script で作った Geometry COMP には既定の `torus1` が入る**。消し忘れると
     画面いっぱいの塗りになる(実際に踏んだ)
- **未解決**: geo2 が描画されない。`soptoPOP` で POP 化(190点/93プリム)し、render/display
  フラグも立て、Constant/Wireframe 双方の MAT を試したが表示されない。**この TD は POP 世代**で、
  動いている geo1 は「1点のPOP + インスタンシング」構成。**同じくインスタンシングで
  骨1本ごとに単位線分を配置する方式**に切り替えるのが確実だと思われる(次の手)
- 例自体は壊していない(点の描画・映像の合成は従来どおり動作)。render1 の解像度は
  Resolution Multiplier を切って 1280x720 にした(128x128 では合成が破綻していたため)

### 2026-08-08 VisionHand / VisionFace にも線描画を追加(3例とも描画確認)

- VisionPose の骨格線は**描画できていた**(前エントリの「未解決」は誤り)。原因は
  `.save()` のキャプチャが POP パイプラインの落ち着く前だったため。数フレーム置くと
  5人ぶんのスティックフィギュアが正しく描かれる
- **VisionHand**: `geo2/bones`(Script SOP)で指5本(wrist→cmc/mcp→…→tip)＋手のひら
  (index/middle/ring/little の mcp を連結)。実測 2手で **46本**
- **VisionFace**: `geo2/contour`(Script SOP)で p0..p75 を領域ごとに連結。並びは Apple の
  76点コンステレーション順(0-10輪郭 / 11-18左目 / 19-26右目 / 27-32左眉 / 33-38右眉 /
  39-47鼻 / 48-52鼻筋 / 56-69外唇 / 70-75内唇)。目と唇は閉ループ。
  実測 **12顔で816本**、全員の顔に正しく描かれることを視認
- **描画に必要だった手順(3例共通・pitfalls級)**:
  ① Script SOP → `soptoPOP` → `outPOP` と繋ぐ(このTDは POP 世代で、Geometry COMP は
     POP を描く)。② **outPOP の render/display フラグを立てる**(立てないと何も出ない)。
  ③ script で作った Geometry COMP には既定の `torus1` が入るので消す
  ④ Script SOP は入力が無いと毎フレーム cook しない → custom par `Trigger` に
     元CHOPの `totalCooks` を式で入れて dirty にする
  ⑤ ポリゴンは `appendPoly(2, addPoints=False)` → `poly[0].point = pa`
- 3例とも render1 の Resolution Multiplier を切って 1280x720 に(128x128 では合成が破綻)
- Face のランドマーク領域範囲は Apple の並び順に依存する。ある領域だけ崩れて見える場合は
  スクリプト先頭の REGIONS を直す旨を note に明記

### 2026-08-08 VisionFace: ランドマークの並びを領域順に詰め直し(描画できる並びへ)

- ユーザー指摘「landmark の繋ぎ方が変」「顔の輪郭が片側途中まで」→ 2段階の実バグを修正
- **原因1**: `VNFaceLandmarks2D.allPoints` の並びは**輪郭順ではない**(目の領域内でも
  座標が -0.25→-0.11→-0.21 と飛ぶ)。連番で結んでも綺麗にならない。
  → プラグインで **faceContour / leftEye / … と領域ごとに、領域内の正しい順序**で
  `face.points[]` に詰め直すよう変更(`lm.faceContour` 等を直接読む)
- **原因2**: 領域ごとの枠を Apple の一般的な数(11/8/8/…)で固定したら、**輪郭が11点に
  truncate されて顎の片側が途中で切れた**。TD上で「各枠の未使用スロット数」を数えて
  **実際の点数を実測**: 輪郭16 / 目6・6 / 眉6・6 / nose8 / crest5 / median3 /
  outerLips14 / innerLips6 = ちょうど76。これに合わせて配分を修正
- **未使用スロットは u=v=-1 の番兵**にした(0 のままだと bbox 隅の実在しない点に見え、
  線が画面外へ飛ぶ。実際に画面左下へ集まる線が出た)。描画側はこれをスキップする
- 実測: 12顔・780プリムで、輪郭が顎の両側まで通り、目/眉/鼻/唇が参考画像どおりに描かれる
- VisionFace README に「ランドマークの並び」節(範囲・点数・開閉・番兵)を追加。
  demo.toe の note も同内容に更新
- **教訓**: Vision の領域点数は constellation により変わる。固定長で切ると**エラーも警告も
  出ずに形だけ壊れる**。実データで枠の使用数を数えて確かめること

### 2026-08-08 VisionAnimalPose にも骨格線を追加 + 4例の線を見やすく調整

- `geo2/bones`(Script SOP)で25関節を接続: 耳(上→中→下)/ 目-鼻 / 鼻→首 / 首→尾(3点) /
  前脚(首→肘→膝→足) / 後脚(尾の付け根→肘→膝→足)。実測 **2匹で41本**、犬と猫それぞれの
  骨格が正しく描かれることを視認
- **4例すべてで `lineMAT` の Wire Width を 3 に**(既定1pxだと線が細くて見えにくかった)。
  色も分けた: Pose=緑 / Hand=橙 / Face=水色 / AnimalPose=黄
- 線描画の型が4例で揃った(Script SOP → soptoPOP → outPOP + render/display フラグ + Trigger)

### 2026-08-08 VisionAnimalPose の骨格接続を修正(top/bottom は「先端/付け根」だった)

ユーザー指摘「AnimalPoseの繋ぎ方が不自然」+ WWDC23 のスケルトン画像。実データを読んで原因を特定。

- **真因**: Apple の関節名の `top` / `bottom` は**画面の上下ではなく、その部位の先端 / 付け根**。
  猫(高信頼度・実測)で確定: `tail_top`=(856,240) **尻尾の先端** / `tail_bottom`=(865,389) **腰の付け根**。
  耳も同じで `ear_top`=先端 / `ear_bottom`=頭に付く付け根(垂れ耳の犬では ear_top が画面下に来る)
- 背骨を `neck → tail_top` で結んでいたため、**尻尾を立てた猫で首から尻尾の先まで空中を横切る線**に
  なっていた。後脚も尻尾の先から生えていた
- **修正**: 胴 `nose → neck → tail_bottom`(腰)/ 尾 `tail_bottom → tail_middle → tail_top` /
  後脚は `tail_bottom` から。耳は**閉じた三角形**、頭部は `ear_bottom → eye → nose`。
  接続は Apple の joint group(head / trunk / tail / 各脚)に沿わせた
- **実測(M2・frame 40 で静止して検証)**: 修正後、猫は背骨が背中に沿い尻尾が腰から立ち上がる、
  犬も背骨・四肢とも自然。2匹で52本。再生に戻した動画でも視認確認
- VisionAnimalPose/README.md に「関節名の top / bottom は先端 / 付け根」の表と、
  骨格を引くときの注意を追記。demo.toe の note も同内容に更新

- **検証手順のメモ**: アスペクト補正の影響を外して生 uv を読むために一時的に
  `Aspectcorrectuv` を Off にしたら、**インスタンシングの overlay が画面外へ飛んだ**
  (例は補正 On + Ortho Width=1 前提のため)。解析が終わったら必ず On に戻すこと。
  静止フレームでの検証は `moviefilein.play=False` + `index` 固定 + CHOP を force cook
- 検証中に TD が落ちたが、**落ちる直前の project.save() は成功していた**(demo.toe は無事)。
  再起動して note・接続・プリム数がディスク版に入っていることを確認済み

### 2026-08-08 デモGIFをREADMEに掲載(demo_capture の画面収録 → docs/demo/*.gif)

- ユーザーが `demo_capture/` に5本の画面収録(1280x720・60fps・5〜9.4秒)を追加。
  VisionPose / VisionHand / VisionFace / VisionText / CoreMLDAT(yolo)
- **`tools/make_demo_gifs.sh`**(zsh)で GIF 化して `docs/demo/*.gif` へ。README(英日)の冒頭に
  「Demos / デモ」節を新設し2列テーブルで掲載、目次にも追加
- **GIFはフレーム間差分でしか縮まない**ので、単に色数やディザを削っても効かない(実測: 64色・
  ディザ無しにしても 520w/12fps で 3.3MB のまま)。効いた順に:
  ① **hqdn3d で軽くノイズ除去**(変化しない画素が増えて差分が効く)② 幅を480pxへ ③ 12fps
  ④ **尺を4秒前後に切る**。これで1本1.0〜1.9MB・計約6.8MB
  - 人混みの街路(CoreMLDAT)はほぼ全画素が毎フレーム変わるので、440w/10fps+強めの hqdn3d が必要
- **元動画が終わって背景だけになる区間を落とす**: VisionFace は4.0秒以降が輪郭のみ、
  VisionText は認識枠が出るのが3.4秒から。`signalstats` の YAVG を 2Hz でサンプルして
  切れ目を機械的に見つけた(`ffmpeg -vf "fps=2,signalstats,metadata=print:key=lavfi.signalstats.YAVG"`)
- `demo_capture/`(27MB)は **.gitignore**。GIFだけコミットする
- **zshの罠**: `"...max_colors=$3:stats_mode=diff..."` のように `$N:s` が続くと **zsh の履歴修飾子
  `:s` と解釈されて文字列が食われる**(ffmpeg が "64teuse=dither=none" を受け取って失敗)。
  `${3}` と波括弧で囲む
- GitHub の README は **mp4 を埋め込めない**(markdown内の `<video>` はサニタイズされる)ので GIF 一択

### 2026-08-08 デモGIFに VisionAnimalPose を追加 + サンプル映像9本をコミット

- ユーザーが `demo_capture/VisionAnimalPose.mp4` を追加。**冒頭2.6秒は骨格だけで元動画が出ない**
  ため 2.6s から3秒を切り出し(切れ目は YAVG が 18→146 に変わる点で判定)。1.5MB
- README(英日)のデモ表がこれで **3行×2列** に揃った(Pose / Hand / Face / CoreML(YOLO) /
  Text / AnimalPose の6本・計約8.4MB)
- **`Assets/sample_*.mp4` 9本(計41MB)をコミット**。demo.toe の Vision系利用例が参照しているのに
  未追跡で、clone しただけでは映像系の例が全部空になっていた(最大は sample_street.mp4 の15MBで
  GitHub の100MB制限内)

### 2026-08-08 VisionFace のデモGIFを撮り直し版に差し替え

- ユーザーが `demo_capture/VisionFace.mp4` を撮り直し(5.8秒・**元動画が終わる無駄な区間なし**、
  ランドマークの輪郭線が青でしっかり出ている)
- **細い線のオーバーレイは 480px / 64色だと潰れる**(顔のランドマークが読めず、背景の壁も縞になる)。
  この clip だけ **560px / 128色** に上げ、尺を 3.2秒に詰めて 2.0MB に収めた。
  `make_demo_gifs.sh` の CLIPS に色数の列を追加して clip ごとに指定できるようにした
- デモGIF計6本・約9.1MB

### 2026-08-08 td_mcp_server(第三者コンポーネント)の出典を明記

- ユーザー質問「td-mcp を .toe に含めているが問題ないか」を調査。
  [johnsabath/touchdesigner-mcp](https://github.com/johnsabath/touchdesigner-mcp) は
  **README に MIT と明記**されており使用・再配布とも可。ただし:
  - **LICENSE ファイルが無い**(`gh api` でも `license: null`)。MIT は著作権表示と許諾表示の
    同梱が条件だが、複製すべき著作権行が公開されていない。上流に LICENSE 追加を依頼するのが確実
  - こちらは `Assets/td_mcp_server.tox` を追跡し、**demo.toe にも埋め込んでいる**
    (`externaltox` はローカル絶対パスを指すが実ファイルは無く、内容は .toe 側に保存されている)
  - にもかかわらず README / THIRD_PARTY_NOTICES.md が「**自作コードのみ・第三者ライブラリは
    同梱していない**」と**事実と異なる記述**になっていた
- LICENSE 末尾に第三者コンポーネントへの導線、THIRD_PARTY_NOTICES.md に専用節(出典・MIT・
  LICENSE不在の但し書き)、README(英日)のライセンス節に要約を追記。誤記も訂正
- **セキュリティの実測**: この COMP は Web Server DAT をポート9988で起動するが、
  **Web Server DAT に bind アドレスの指定が無く 0.0.0.0 で待ち受ける**。自機のLAN IP
  (`10.59.224.215:9988`)へ MCP の initialize を POST して **HTTP 200** を確認。
  エンドポイントは**認証なしで TD 内の任意 Python を実行できる**(`run` ツール)ので、
  同一LAN上の誰でも TD とマシンを操作できる。この旨を notices と README に明記した
- **未決**: demo.toe から `td_mcp_server` を外すかどうかはユーザー判断待ち(今回は表記のみ)

### 2026-08-08 Assets/td_mcp_server.tox を削除(demo.toe への影響なしを確認)

- 削除前に無参照を確認: ①`demo.toe` のバイナリに "Assets/td_mcp_server" の文字列は0件
  ②ロード中の demo.toe で `externaltox` を持つ COMP が1つも無い(=サーバの中身は .toe に
  埋め込み済みで、外部 tox に依存していない)③リポジトリ内の言及はドキュメントのみ
- `git rm` して、LICENSE / THIRD_PARTY_NOTICES.md / README(英日)の所在表記を
  「`demo.toe` に `/project1/td_mcp_server` として埋め込み」へ更新。出典表記自体は維持
- 注意: **同梱をやめたわけではない**(demo.toe の中に本体がある)ので、出典表記は引き続き必要

### 2026-08-08 Non-Commercial 版の解像度制限について未検証である旨を明記

- ユーザー指示「NonCommercial での検証が不十分なので解像度制限による問題が出る可能性を記載したい」
- **NC の上限は 1280x1280**(https://derivative.ca/download で確認)。開発・実測はすべて
  ライセンス版(2025.32280)で行っており、NC 環境での確認はしていない
- 各READMEの実測解像度を機械的に走査して**上限超えのOPを特定**し、ルートREADME(英日)の
  必要環境に節を新設して表で列挙 + 該当8プラグインの「注意」節に1行ずつ追記:
  - Metal Upscale(2x/4x は必ず超える=OPの用途そのもの)/ Cinematic Video(3840x2160)/
    ImageIO File In・CoreImage RAW・CoreImage HDR(実機写真 3024x4032 級)/
    Screen Capture(1710x1112)/ PDFKit(1275x1650)/ CoreText(指定解像度しだい)
  - 回避策は出力解像度を下げること、直らなければ Issue を、と案内
- **次にやるなら**: `app.addNonCommercialLimit()` / `app.removeNonCommercialLimit()` が
  TD の Python API に存在する(`dir(app)` で確認)。ライセンス版のまま NC の制限を再現できる
  可能性があるので、実際に掛けて上記8件の挙動を確認すれば「未検証」を解消できる(今回は
  ユーザーが作業中のTDに影響するため実行していない)

### 2026-08-08 利用者向けスキル td-apple-ops を追加

- 既存の `td-apple-plugin` は**作る側**のスキルなので、**使う側**(既存OPでTDプロジェクトを組む)の
  スキルを新設。`.claude/skills/td-apple-ops/` に実体を置き、`~/.claude/skills/` へシンボリックリンク
  (td-apple-plugin と同じ運用。単一ソースのままセッションを跨いで使える)
- 構成: `SKILL.md`(導入・OPの選び方・外さない5つのルール・チャンネル名の書式・NC制限)/
  `wiring.md`(cookを回す・Info CHOP・Flip・Aspect Correct UVs→Ortho Width=1・骨格線・
  マスク合成・VisionFlow可視化・音声/LLMの注意)/ `troubleshooting.md`(症状別)
- **OP一覧はスキルに転記しない**(必ず陳腐化する)。ルートREADMEを正として参照させる方針

### 2026-08-08 ops_catalog.json の追跡をやめた(生成物・黙って腐る)

- ユーザー質問「ops_catalog.json はもういらない?」→ 調べたところ**誰も参照しておらず、
  内容も大きく古かった**ので追跡をやめた
  - 最終更新は 7/22。その後の develop 分離・CoreMLDetect→CoreMLDAT 改名・Aspect Correct UVs 追加を
    一切反映しておらず、`_count: 82` に対し **main に存在しない 24 op**(Visiontrack / Visionsegment /
    Swiftui / Phase 等)を載せたままだった
  - 参照は `tools/gen_ops_catalog.py`(生成元)と CLAUDE.md の履歴行のみ。README からのリンクも無し
- `git rm --cached` + `.gitignore` へ追加。**生成スクリプトは残す**(実行して 59 ops を正しく出力する
  ことを確認済み)。必要になった時点で `python3 tools/gen_ops_catalog.py` で作り直す
- 教訓: **一覧は1箇所だけを正にする**。人間向けはルート README、機械可読が要るときだけ生成。
  同じ理由で新スキル td-apple-ops にも OP 一覧を転記していない

### 2026-08-08 利用者向けスキルの案内を README に追記

- 「使い方 / Getting started」に **3. AIコーディングエージェントと組む場合** を新設し、
  `td-apple-ops` の中身(導入・OPの選び方・配線ルール・レシピ・症状別)と、他プロジェクトから
  使うためのシンボリックリンク手順を記載(英日)
- 既存の「プラグインを自作する人へ」の `td-apple-plugin` の行にも、**使う側は td-apple-ops** と
  相互リンクを追加。作る側/使う側のどちらから入っても辿り着ける

### 2026-08-08 v0.9.2 リリース

- VERSION を 0.9.2 へ。**57プラグインを全て再ビルド**(並列 `xargs -P 6`・全件成功)してから
  `tools/release.sh sign → verify → dmg → notarize`。59バンドル(Multipeer は In/Out で2つずつ)
- verify は署名・Hardened Runtime・Developer ID・**OP_CommonAPIVersion=1**・**版一致**を全数検査して通過。
  DMG 18MB → 公証 **Accepted** → staple → `spctl` accepted(Notarized Developer ID)
- v0.9.1 からの中身(なぜ patch でなく必要だったか): **bypass/無効化から戻すと黒画像になる不具合を
  全17 TOP で修正**、**ビルド不能だった6件を修復**(共通ヘルパが zsh 専用なのに shebang が bash
  → 7/23以降ずっとビルドされていなかった)、VisionFace のランドマーク並び修正、
  VisionAnimalPose の骨格接続修正、VisionText への Aspect Correct UVs 追加
- 公開対象は 0.9.1 の66 → **59オペレータ**(VisionSimilarity / CoreImageBokeh / CoreImageEnhance /
  VisionAesthetics / CoreLocation Beacon / VisionTrack / VisionSegment を develop へ退避したため)

### 2026-08-08 README の「使い方」をリリースDMG優先の順序に変更

- ユーザー指示「まずリリースビルドをダウンロードして使う方法を案内して」。従来は
  **1. プラグインをビルド** から始まっており、Xcode が要る前提に見えていた
- 新しい順序(英日): **1. 導入(リリースDMG・ビルド不要)** → **2. 利用例を動かす(demo.toe)** →
  **3. ソースからビルド(任意)** → **4. AIエージェントと組む場合**。
  1 に公証済みで Gatekeeper 警告が出ないこと、プラグインは起動時にしか走査されないこと、
  多数入れ替え直後の初回起動が数分かかることを明記
- **踏んだ罠**: 最初 `cp -R /Volumes/Apple*Frameworks*/*.plugin ...` と書いたが、
  **古いバージョンのDMGが同時にマウントされているとグロブが両方に一致する**
  (実機で v0.9.0 が残っており 59個のはずが128個に一致した)。バージョンを明示する
  `"/Volumes/Apple Frameworks for TouchDesigner v0.9.2/"*.plugin` に修正し、
  実際にコピーして59個・コピー後も `codesign --verify --deep --strict` が通ることを確認

### 2026-08-08 README の Versioning にリリース履歴表を追加

- 「現在のリリース」を 0.9.2 へ更新し、あわせて**バージョン / 日付 / OP数 / 主な内容**の
  履歴表を新設(英日)。0.9.0 は DMG を取り下げ済みである旨も1行で残した
- OP数の推移が見えるようにした(0.9.1=66 → 0.9.2=59。develop へ7件退避したため)。
  0.9.1 の Aspect Correct UVs は10op、VisionText を足した0.9.2で11op全対応、という差も表に反映

### 2026-08-08 導入手順に「プラグイン数ぶん許可ダイアログが出る」注意を追加

- ユーザー指摘: Plugins フォルダに入れると**初回起動時にプラグインの数だけ New Plugin の
  許可ダイアログが出る**(TDは許可結果を `Plugins.json` に記録する)。59個入れると
  ネットワークに辿り着く前に59回閉じることになる
- README(英日)の「1. 導入」を **まず使いたいものだけコピーするのを推奨**する書き方に変更。
  全部入れるコマンドは残しつつ、その前に注意を置いた。許可はプラグインごとに記憶され、
  あとから足せることも明記
- skill `td-apple-ops` にも反映: SKILL.md の導入手順に同じ推奨、troubleshooting.md の
  「Create Dialog に出ない」の**最初のチェック項目**に「許可ダイアログを閉じてしまっていないか」を追加

### 2026-08-08 CoreText TOP: Line Height を1.0未満にすると1行目が動く問題を修正

- ユーザー報告「LineHeight を一定以上小さくすると1行目も動く」。**既知の未修正ブランチ**で、
  ソースのコメントにも「1.0未満は MaximumLineHeight。この場合のみ1行目もわずかに動く」と残っていた
- **単体ハーネスで定量化**(Helvetica 72pt・natural=72):
  - 現行(MaximumLineHeight): 1行目が lh=1.0→62.00 / 0.95→61.00 / 0.60→48.00 / 0.20→34.00 と動く
  - さらに実際のプラグインは lh>=1.0 で別ブランチ(LineSpacingAdjustment)なので、
    **1.00→0.95 の瞬間に1行目が 70→61 へ9px飛び**、行送りも 87→68 へ不連続に変わっていた
    (ユーザーの言う「一定以上小さくすると」はこの段差)
- **修正: 分岐を廃止し常に LineSpacingAdjustment(負値可)**。1行目のベースラインは全ての値で不動。
  lh>=1.0 の挙動は従来と完全に同一(同じコードパス)なので既存 .toe の見た目は変わらない
- **実測(ハーネス)**: 提案方式は Helvetica で 1行目=70.00 固定・行送り 87→51→22.2→15、
  和文(ヒラギノ角ゴ W3・natural=108)では 1行目=63.00 固定・行送りが 108→54→0 と**完全に線形**
- **TD実機**: lh=1.00 と 0.40 でレンダしたPNGを比較し、**1行目の上端が両方とも row 39 で一致**
  (行間だけが詰まる)。修正前は動いていた
- **使ってはいけないもの**(いずれも1行目まで動く・コメントに明記): `LineHeightMultiple` /
  `MaximumLineHeight`。行送りは **LineSpacingAdjustment 一択**
- CoreText/README.md のパラメータ説明を「どの値でも1行目のベースラインは動かない」に更新。
  リビルド・常設インストール済み
- **注意**: リリース v0.9.2 の DMG はこの修正の1コミット前。次回配布時に取り込む

### 2026-08-08 CoreText デモにタイプライター表示(一文字ずつ)を追加

- `/project1/coretext` に4ノード追加:
  `type_source`(全文・Text DAT)→ `typer`(Execute DAT・onFrameEnd)→ `type_out`(Text DAT)
  → `typewriter`(CoreText TOP の Text DAT に接続)。書き換えるたびに CoreText が再レンダする
- typer は `absTime.seconds` で進めるので **fps が落ちても表示速度が変わらない**。
  `CPS`(1秒あたりの文字数)と `HOLD`(全部出てから先頭へ戻るまでの秒数)で調整。
  文字数は Python の文字列長なので日本語もそのまま1文字ずつ進む(バイト数ではない)。
  カーソルは 2Hz で点滅、消灯時は空白にして行幅が揺れないようにした
- **サンプル文は夏目漱石『吾輩は猫である』(1905) 冒頭**(126文字)。漱石は1916年没で
  日本・米国とも保護期間満了=パブリックドメイン。青空文庫収録
- **踏んだ罠**:
  ① **Text Wrap が `balance` / `pretty` だとタイプ中に行が組み直されてガタガタ動く** →
     `wrap` にする(README にも明記)
  ② **Vertical=True / ヒラギノ明朝 / 32px になっていたのはユーザーの手編集**だった。
     「create() が同型の既存ノードから値を引き継いだのでは」と推測して False に上書きしてしまい、
     ユーザーの指摘で復元した。**TD上でユーザーが同時に編集していることがある**ので、
     パラメータが想定と違っても勝手に直さず、まず確認すること
  ③ Execute DAT のフレーム末コールバックのパラメータ名は **`frameend`**(`framiend` ではない)
- 実機で 126文字が5行に組まれ、先頭から1文字ずつ増えることを視認確認。エラーなし。demo.toe 保存済み

### 2026-08-08 タイプライター例の本文を長文化(272文字・縦書き)

- ユーザー要望で本文を『吾輩は猫である』冒頭**1段落まるごと(272文字)**へ。CPS=24・HOLD=2.0 で
  1周約13秒。縦書き13段に収まり truncated=0(Info CHOP で確認)
- **Text Wrap を `balance` → `wrap` に変更**。balance / pretty は文字が増えるたびに行を
  組み直すため、タイプ中に行がガタガタ動く(README にも明記)
- 表示はユーザーが縦書き(Vertical=On・ヒラギノ明朝)に設定したものを採用。検証中に一度
  横書きへ上書きしてしまったので復元済み。私が触った Lineheight / Padding / Alignh / Alignv /
  背景色・文字色はユーザーの意図と異なる可能性があるため申し送りした

### 2026-08-08 デモを4件追加(深度 / 被写体切り抜き / タイプライター / ImagePlayground)

- ユーザーが `demo_capture/` に3動画+1静止画を追加。README(英日)のデモを **5行×2列=10件**へ
  - `coreml-depth`(Depth Anything V2 の単眼深度・480w/12fps/4s = 1.09MB)
  - `visionsubject`(被写体切り抜き・480w/12fps/**6.4s 全尺** = 378KB)
  - `coretext`(縦組みタイプライター・640w/10fps/**10s** = 274KB)
  - `imageplayground`(**静止画**・顔写真→イラストの入出力比較)
- **背景が動かない素材は GIF が桁違いに軽い**: 単色グリーンの切り抜きは6.4秒で378KB、
  紙面に文字が増えるだけのタイプライターは10秒・640px・96色でも274KB。逆に人混みの街路は
  4秒で1.9MB。**尺や解像度を削る前に「毎フレーム何割の画素が変わるか」を見ること**
- タイプライターは**冒頭が真っ白**なので 1.5s から切り出した(GIFの先頭フレームが空だと
  スクロール中に何も見えない)
- **動きが無いものは静止画で足りる**。`make_demo_gifs.sh` に STILLS セクションを追加し、
  レターボックスの黒帯を crop して JPEG 化(1280x720 の黒帯付き 1.0MB PNG → 800x400 43KB)。
  黒帯の位置は行ごとの最大輝度を見て機械的に決めた(content rows 40-679)
- docs/demo 合計 約12MB

### 2026-08-08 README のデモGIFが左右で違うサイズに見える問題を修正

- ユーザー指摘。原因は**clip ごとに書き出し解像度を変えていた**こと(440/480/560/640/800px)。
  GitHub は画像を実寸で並べるのでそのまま差が出る。幅を変えていたのは意図的で、
  人混みは軽くするため440、細線のランドマークや縦組み明朝は潰れるため560/640、静止画は800
- **エンコード解像度はそのままに、README側で `<img width="400">` に統一**(英日10件)。
  markdown の `![]()` を HTML の img に置換。GitHub は表セル内の img と width 属性を通す
- これで表示は 400x225 に揃う(imageplayground だけ黒帯を切った 2:1 なので 400x200)
- `make_demo_gifs.sh` の冒頭に「ここの幅はバラバラでよい・表示幅はREADME側で固定している」
  と明記。あとから「揃えよう」として再エンコードしないための注意

### 2026-08-08 デモ素材を全て 480x270 に統一(前エントリの方針を変更)

- ユーザー指示「全てサイズは揃えて」。前は「幅は clip ごとにバラバラでよい・READMEの
  `<img width>` で見た目だけ揃える」としたが、**書き出し自体を 480x270(16:9)に統一**した
- 幅で軽くしていたぶんは **fps・色数・尺・ノイズ除去の強さ**に振り替えた:
  - visionface: 560→**480 + 色数128**(幅を戻しても線が潰れない。2022→1525KB と逆に軽くなった)
  - coreml-yolo: 440→**480 + 10fps・3.2s・hqdn3d=16:16:28:28**(1946→1764KB)
  - coretext: 640→**480**(274→165KB)
- **静止画も 16:9 に**: 2:1 の内容を 480 幅で描いて上下に `pad` で余白(0xF0F0F0)を足し 480x270 に。
  黒帯のまま使うと他と並べたとき浮くので、明るい中間色にした(20KB)
- 全10件が 480x270 であることを `sips` で確認。合計 約12MB。README の `<img width="400">` は
  そのまま残す(将来サイズ違いが混ざっても崩れないため)

### 2026-08-08 Non-Commercial の実バグを再現・原因特定(修正は未実施)

- ユーザー要望「NCで使ってもバグが出ないようにしたい」。`app.addNonCommercialLimit(password=...)`
  で**ライセンス版のまま NC 制限を再現**できる(パスワード付きなら `removeNonCommercialLimit` で
  戻せる。**パスワード無しだとセッション中は解除不能**なので必ず付けること)
- **実際に壊れることを確認した**(検証用に `_nctest` を作り、上限超えの5 TOP を比較):

  | OP | 通常 | NC | 結果 |
  |---|---|---|---|
  | Metal Upscale | 2560x1440 | 1280x720 | **斜めに歪んだガベージ** |
  | Screen Capture | 1710x1112 | 1280x832 | **斜めに歪んだガベージ** |
  | ImageIO File In | 3024x4032 | 960x1280 | **RGB縞のガベージ** |
  | CoreText | 2000x2000 | 1280x1280 | 背景のみ・**文字が出ない** |
  | PDFKit | 1275x1650 | 989x1280 | **真っ白** |

- **原因**: TD は上限超えの宣言に対し **テクスチャをクランプしたサイズで確保し、こちらのバッファを
  その幅で読む**(リサンプルはしない)。プラグインは 2560 幅でバイトを並べているので行がずれ、
  典型的な斜めシアーになる。**エラーにはならず静かに壊れる**
- **計測で確定**(MetalUpscale に一時的なプローブを入れて実測):
  - ライセンス版: `want=2560x1440 / suggested=1280x720` → **出力は 2560x1440**(要求が通る)
  - NC: `suggested` は **1280x720 のまま変わらない**(= Common ページの値であって上限ではない)。
    TD 側が勝手に 1280x720 で確保する
  - つまり **`getSuggestedOutputDesc` では上限を知れない**。SDK に上限を問い合わせるAPIも無い
- **上限の検出手段**: TD の Python に **`licenses.isNonCommercial`** がある(NC適用中 True /
  解除後 False を実測)。`licenses.type` も "TouchDesigner Non-Commercial" / "Commercial" と変わる。
  プラグインからは CoreWLANScan と同じ埋め込み Python(`PyRun_String` + `-undefined dynamic_lookup`)
  で引ける
- **修正方針(未実装)**: 共有ヘッダ `common/NonCommercialLimit.h` を作り、
  ① `licenses.isNonCommercial` をキャッシュ付きで判定 ② 超えていたら**アップロード直前に
  1280x1280 以内へ縮小(アスペクト維持のボックスフィルタ)して textureDesc も揃える**
  ③ 縮小したことを warning で知らせる。これを各 CPUMem TOP のアップロード箇所に入れる。
  Upscale のように「拡大が目的」のOPでも、壊れた絵よりは上限で頭打ちの正しい絵のほうがよい
- 検証コンテナと計測コードは撤去済み。TD は Commercial に復帰済み

### 2026-08-08 NC の解像度上限バグを修正(共通ヘッダ + 10 TOP)

- 前エントリで特定した「上限超えの宣言 → TD がクランプ後の幅でバッファを読む → 斜めシアー」を修正
- **`common/NonCommercialLimit.h` を新設**:
  - `tdnc::active()` … TD の Python `licenses.isNonCommercial` を引く(GIL を取って
    `PyImport_ImportModule("td")`)。結果は 120 cook キャッシュ。**上限内なら Python に触らない**
  - `tdnc::fit(vector, w, h, fmt)` … 上限超え時だけアスペクト維持で縮小。8bit/32bit float は
    ボックス平均、16F 等は成分を解釈できないので最近傍。**要素型テンプレート**にして
    `vector<uint8_t>` と `vector<uint16_t>`(RGBA16Float)の両方を受ける
  - `tdnc::kWarning` … 縮小したことを利用者に伝える文言
- **適用した10 TOP**: Metal Upscale / Screen Capture / ImageIO File In / PDFKit / CoreText /
  CoreImage HDR / CoreImage RAW / CoreML / CoreImage Code / Cinematic Video。
  各 build.sh に Python.h と `-undefined dynamic_lookup` を追加(既にあるものはそのまま)
- **未適用4件は構造上超えない**: Metal Denoise / Vision Flow / Vision Subject は入力解像度を
  そのまま出すが、入力側は TD が既にクランプ済み。CoreML SAM2(256px)/ ImageGen(≤1024)/
  ImagePlayground(~1024)も上限未満
- **検証(NC制限を再現して実測)**: 5件とも**警告が TD のクランプ警告から自作の縮小警告に変わり**、
  絵が正しく出た(街路 / 画面収録 / テストパターン / PDF本文 / テキスト)。CoreImage Code は
  2400x2400 指定 → 1280x1280 の**読み取り可能なQR**を確認。ライセンス版では従来どおり
  フル解像度・警告なしで、縮小経路に入らないことも確認
- **踏んだ罠**:
  ① **キャッシュのせいで判定が遅れる**。NC を途中で適用すると 120 cook(約2秒)経つまで
     気づかない。実運用では起動時から NC なので初回判定で当たるが、検証時はここで
     「修正が効いていない」と誤診した
  ② Cinematic は `cn_copy_*` で TD のバッファへ直接書いていたので、上限超えのときだけ
     一時バッファ経由にした(**上限内では従来どおり直接コピーで、余計なコピーを増やさない**)
  ③ 警告メンバ名がプラグインごとに違う(`myWarning` / 状態から組み立て)。CoreML と Cinematic は
     専用の `myNCScaled` フラグを足した
- README(ルート英日 + 該当8プラグイン)の「未検証」記述を「自動で縮小する」へ更新。
  10 TOP を常設インストール済み

### 2026-08-08 Vision Contours SOP に Aspect Correct UVs を追加(uv系OPは全12件対応)

- ユーザー指示。CHOP/DAT で使っている `common/AspectCoords.h` をそのまま SOP に流用
  (`tdaspect::appendAspectCorrect` + `Mapper`)。既定Off で既存 .toe は従来動作のまま
- SOP は点座標が Vision の 0〜1(左下原点)なので、**そのままだと 0〜1 の正方形**に入り、
  16:9 の映像に重ねると輪郭が縦に間延びする。On で `P.y' = 0.5+(P.y-0.5)/aspect`
- **踏んだ罠**: `emitGeometry` には**座標を書く箇所が2つ**ある。輪郭を閉じるための
  **先頭点の複製** `positions.emplace_back(line.points.front().x, ...)` を変換し忘れ、
  各輪郭の1点だけ元座標に残っていた。数値で y の**上端(0.7812)は理論値と一致するのに
  下端(0.0017)が合わない**という形で出た。上端だけ合っているときは「一部の点が未変換」を疑う
- **実測(1280x720・同一フレーム655点で比較)**: Off は `y 0.0000..1.0000`、
  On は `y 0.2188..0.7812` で理論値 `0.5±0.5/1.7778` と完全一致。x は不変
- **視認**: Geo を -0.5 寄せ + Ortho Width=1 のカメラで元映像に合成し、
  Off は輪郭がシルエットからはみ出す / On はぴったり重なる、を確認
- **検証時の注意**: SOP to POP は**ワイヤでなく `sop` パラメータ**でSOPを指す。
  POP は **Geometry COMP の内側**に置かないと描画されない(外に置くと何も出ない)
- リビルド・署名・常設インストール済み。README にパラメータ行と解説節を追加

### 2026-08-08 VisionFace のランドマークが左右非対称に見える件を再調査(原因は鼻の並び順)

- ユーザー報告「landmarks が左右非対称に見える」。**再確認した結果、プラグインのパッキングは正しく、
  原因は Vision が返す鼻まわりの点の並び順**だった
- **確認手順**: 静止フレームで76点を全部ダンプし、領域ごとに左右の中心・範囲を比較
  - 顔の中心(輪郭 mid 0.511)に対し 目 0.462/0.557、眉 0.455/0.562、唇 0.511 と**左右バランスは正常**
  - 目は左右とも「外側→上まぶた→内側→下まぶた」の同じ順序で、**閉ループも対称**
  - `noseCrest` だけ mid 0.497 と中心から外れていた → 個別にダンプして原因特定
- **判明した実データ**(12顔中4顔で同じ構造を確認・一過性ではない):
  - `noseCrest` 48-52 は **48→51 が鼻筋の直線、5点目 p52 だけ稜線から左へ外れる**
  - `nose` 40-47 は **p40 が鼻筋の上端(正中)で、p41 でいきなり左の小鼻へ飛ぶ**
  - `medianLine` 53-55 は **noseCrest の先頭3点と完全に同一座標**(重複)
  - → 連番で結ぶと「正中から左小鼻への長い斜線」「鼻筋から左への突起」「鼻筋の二重線」が出る
- **パッキングのズレではないことの確認**: 固定スロット方式なので、点数が足りなければ番兵(-1)が
  残るだけで隣の領域へずれ込まない。実際 medianLine の3点が crest の先頭3点と一致しており、
  オフバイワンでもない
- **修正は描画側**(demo.toe の `VisionFace/geo2/contour`): 小鼻の掃引は **p41 から**、
  鼻筋は **48-51 のみ**、`medianLine` は**描かない**。修正前後を並べて視認確認済み
- VisionFace/README.md に「鼻は連番で結ぶと非対称に見える」の症状→実データ→描き方の表を追加

### 2026-08-08 VisionFace 輪郭の左右非対称の真因: 領域の確保数が実測より少なく切り捨てていた

- ユーザー指摘「顔の輪郭も左右対称ではない」。前エントリで鼻の並び順は説明できたが、
  **輪郭の非対称は別原因**だった
- **切り分け**: `roll = 0 / yaw = 0`、目の高さ差 0.0024 で**頭は傾いていない**のに、
  輪郭の上端で左右差 0.035(下の顎に近いほど小さい=片側が途中で終わっている形)
- **プラグインに一時プローブを入れて `region.pointCount` を直接計測**したところ:

  | 領域 | 実際 | 旧確保 | |
  |---|---|---|---|
  | faceContour | **17** | 16 | 切り捨て |
  | noseCrest | **6** | 5 | 切り捨て |
  | medianLine | **10** | 3 | 切り捨て |
  | 他 | 一致 | | |

  12顔×複数フレーム(288サンプル)で**点数は常に一定**。合計 **85点**
- **`allPoints` が 76 しか返さないのは medianLine が他領域と重複しているため**。
  76 を信じて配分したのが誤りだった
- **以前の検証方法の盲点**: 「使用スロット数を数える」やり方では**不足しか検出できず、
  超過(切り捨て)は見えない**。領域の `pointCount` を直接測ること
- **修正**: `kNumLandmarks` 76→**85**、`counts` を実測値
  `{17,6,6,6,6,8,6,10,14,6}` に。新レイアウト:
  `0-16 輪郭 / 17-22 左目 / 23-28 右目 / 29-34 左眉 / 35-40 右眉 / 41-48 鼻 /
  49-54 鼻筋 / 55-64 正中線 / 65-78 外唇 / 79-84 内唇`
- **実測(修正後)**: 輪郭は顎 p8 を挟んで**左右8点ずつ**の均等配置になり、上端の左右差は
  **0.035 → 0.011**(残りは実際の顔の非対称)
- **鼻の件も真因が判明**: `noseCrest` は 6点で「49-52 が鼻筋 + p53/p54 が**左右の小鼻**」。
  以前 5 点で切っていたため**左の小鼻だけ残って**非対称に見えていた。分けて描けば対称になる
- **後方非互換**(p インデックスがずれ、チャンネル数が 152→170/顔)なので、
  ルールどおり**この op だけ majorVersion を 0→1**(minor 9→0)に上げた
- demo.toe の描画(`geo2/contour`)を新レイアウトへ更新。README(該当+ルート英日)も更新
- **注意**: 実行中のTDはプラグインをプロセス内キャッシュしているため、**TD再起動まで
  例は旧76点のまま**。再起動後に見た目を再確認すること

### 2026-08-09 v0.9.3 リリース

- 当初 0.10.0 で切ったが、**ユーザー判断で 0.9.3(patch)へ変更**。v0.10.0 のタグと
  GitHub Release は削除し、DMG を v0.9.3 で作り直して公証し直した
- (0.10.0 を提案した理由は VisionFace のランドマーク 76→85 が後方非互換だから。
  op 単位の majorVersion は 0→1 のまま据え置き、リポジトリ版だけ patch にしている)
- 57プラグインを全て再ビルド(並列・全件成功)→ `release.sh sign → verify → dmg → notarize`。
  59バンドル・全数verify通過(署名/Hardened Runtime/Developer ID/APIバージョン/版一致)。
  DMG 18MB → 公証 **Accepted** → staple → spctl accepted
- v0.9.2 からの中身: **NC の解像度上限で絵が崩れる不具合を10 TOPで修正**(最大の成果。
  上限超えの宣言に対し TD がクランプ後の幅でバッファを読むため斜めシアーになっていた)、
  **VisionFace のランドマーク切り捨てを解消**(76→85・輪郭17点目など)、
  Vision Contours に Aspect Correct UVs、CoreText の行送りで1行目が動く問題を修正

### 2026-08-09 VisionRect 利用例: 検出した四隅に映像を貼り込む(corner pin)

- ユーザーが VisionRect 用の素材2本を追加(`Assets/sample_laptops.mp4`(白画面のノートPC2台)
  `sample_gallery.mp4`(壁の絵画3枚)・各2〜3MB・**コミットした**)。これに合わせて
  `/project1/VisionRect` を「四隅を数値で見るだけ」から**実際に画像を合わせる例**へ拡張
- 構成: `null4(元映像) → Visionrect1 → rectdata(Shuffle: Sequence All Channels) → warp(GLSL TOP)`。
  GLSL の入力0=元映像 / 入力1=`art`(sample_ballet.mp4)。出力 `out1`
- シェーダは **単位正方形→四隅 の射影変換(Heckbert)を作り `inverse(M)` で逆写像**し、
  貼り込む画像側の st が 0〜1 の内側の画素だけ合成する。矩形数は
  `textureSize(uRects)/14` から自分で求めるので Max Rectangles を変えても壊れない
- **実測(M2・TD実機で視認)**: ノートPC2台の画面に同時にバレエ映像が**遠近つきで**貼り付く。
  静止フレームでは画面枠とほぼ完全一致。gallery に差し替えると大きな絵画が映像に置き換わる
- **踏んだ罠**:
  ① **GLSL TOP の Array に CHOP を直結すると texel 数 = サンプル数**。70ch×1sample の CHOP は
     **1 texel しか渡らない**(`textureSize` が 1)。**Shuffle CHOP の `Sequence All Channels`**
     で `1ch×70sample` にしてから渡す
  ② TOP空間のワープには**生の 0〜1 画像座標**が必要 → `Aspect Correct UVs` は **Off**
     (On だと v が縮んで貼り込みが上下にずれる)
  ③ `w.par.array = 1` では**シーケンスのブロックが増えない**。`w.seq.array.numBlocks = 1`
     (ヘッダ par の値は「追加ブロック数」なので 0 のまま表示される)
  ④ `par.pixeldat` / `par.array0chop` に **OPオブジェクトを代入すると効かないことがある**
     (パス文字列で入れる)。glslmultiTOP を Python で create すると
     `<name>_pixel/_info/_compute` が**自動でドック生成される**ので、自分で作った同名DATは
     `_pixel1` にリネームされる(自動生成された方に書く)
  ⑤ キーボード面が矩形として拾われていたので **Maximum Aspect Ratio を 0.8** に(画面は 0.66〜0.69)
- 検出は非同期なのでカメラが速く動くと貼り込みが1〜2フレーム遅れる(note と README に明記)
- VisionRect/README.md に「四隅に画像を貼り込む」節、skill `td-apple-ops/wiring.md` に
  同名のレシピを追加。demo.toe 保存済み

### 2026-08-09 各opのREADMEを英日併記に統一(57件)

- ユーザー指示「それぞれのopのREADMEを英語と日本語の併記にして」
- **1ファイルに英語セクション + 日本語セクション**の形にした(`README.md` は各opの
  `opHelpURL` の参照先なので、ルートのように `README.ja.md` へ分けるとHelpボタンから
  英語版しか開けなくなる)。構成は `# タイトル` → `**English** | [日本語](#日本語)` →
  `## English` → `## 日本語`。元のH2/H3は1段下げて格納
- **ついでに直した実害のある古い記述**:
  - タイトルが opLabel とずれていた: CoreAudioProcessTap(CoreAudio Tap → **CA Process Tap**)、
    SpeechActivity(Voice Activity → **Speech Activity**)、CoreMLImageGen(Image Gen →
    **CoreML ImageGen**)
  - **ビルド手順の cd 先がリネーム前のフォルダ**: CoreAudioProcessTap(ProcessAudio)、
    CoreWLAN(WiFiMonitor)、Spotlight(SemanticIndex)、MultipeerDAT(Multipeer)
  - **成果物名が実際の build.sh と不一致**: CreateMLTrainingRecorder / LLMAFM / CoreMLDAT
  - **消えたopへのリンク**: CoreMLCHOP→CoreMLDetect、CoreMLMotion→CreateMLMotion、
    TextAnalyze→VisionSimilarity(develop送り)、VisionSubject→VisionSegment(同)
  - VisionFace の見出しが `p0..p75` のまま(実体は85点)、VisionPose に存在しない
    VisionPoseOSC アプリの節、CoreText の利用例パスが `sample.toe`
- 補足を足した箇所: VisionPose3D は Aspect Correct が **u,v のみ**に効く(tx,ty,tz は
  メートルなので不変)、VisionSaliency は **意図的に Aspect Correct を持たない**
  (Crop TOP へ直接渡す前提で生uvが要る)、VisionTrajectory は放物線係数も補正される、
  LLMMLX の Model が式モードだと裸のリポジトリIDで SyntaxError、
  SpeechSynth の timeslice 修正、LLMAFM のツール呼び出しはプロンプトでツール名を明示する
- 検証: 57件すべてで `## English` / `## 日本語` / ナビ行が各1個であることを機械チェック
- **palette/README.md・models/README.md・Assets/ml_examples/README.md は対象外**
  (opのREADMEではないため)。ルート README(英日)は従来どおり別ファイル

### 2026-08-09 palette/README.md を現状に合わせて訂正

- ユーザー質問「Paletteフォルダの中身はすでに古い?」→ **古かった**。README が主役として
  説明していた `NativePanel.tox` / `SwiftUIButton.tox` は、依存する SwiftUI Panel CHOP と
  UI Widget DAT を 2026-08-07 に develop へ移した際に main から削除済みで、
  **main に残っているのは `WifiScanner.tox` だけ**だった(登録手順も NativePanel を置く指示のまま)
- WifiScanner のみの内容に書き直し、登録手順を `WifiScanner.tox` に修正。
  develop へ移した2件は「どこへ行ったか」を1節にして残した(消えた理由が分かるように)
- ついでに op の README と同じ**英日併記**にした(CoreWLANScan の README からリンクされており、
  そちらは併記済みのため)
- **ローカルの TD palette フォルダには3つとも残っている**
  (`~/Library/.../palette/sygnal/`)。開発機には全プラグインが入っているので動作はする。
  リポジトリと揃えたい場合はユーザー側で削除する(今回は触っていない)

### 2026-08-09 palette/ を main から外して develop 側のみに

- ユーザー指示「WifiScannerも不要なので一旦Paletteもmainから外してdevelopへ」
- **develop 側は同期不要だった**: develop には既に3つの .tox(NativePanel / SwiftUIButton /
  WifiScanner)と、3つとも説明した README が入っている。`WifiScanner.tox` は main と
  **バイト一致**(sha256 0763e6c2…)を確認したうえで main から `git rm -r palette`
- CoreWLANScan/README.md の `palette/WifiScanner.tox` へのリンク2箇所(英日)を削除。
  リポジトリ内に palette への参照は履歴ログ(CLAUDE.md)以外に残っていないことを確認
- ローカルの TD palette フォルダ(`~/Library/.../palette/sygnal/`)には3つとも残したまま。
  開発機では引き続き使える(消すかはユーザー判断)

### 2026-08-09 VisionFace の素材を10人版に差し替え + デモGIF更新

- ユーザーがカメラ固定・各人が個別に喋る/動く10人の映像を生成(2行×5人・正面向き)。
  旧素材(12人・横顔と重なりが多く一部の顔でランドマークが崩れていた)を置き換え
- ユーザーが置いた `Assets/smple_faces2.mp4` は**ファイル名のタイポ**だったので
  `Assets/sample_faces.mp4` へリネーム(旧12人版を上書き)。TD側も
  `/project1/VisionFace/smple_faces2` → `sample_faces` にリネームし file par を更新。
  **旧 sample_faces.mp4 を参照するノードが他に無いことを全27 moviefilein の走査で確認**してから実施
- **実測**: `Max Faces = 10` で **valid = 10**(全員検出)。コンテナ内エラー・警告なし
- デモGIF を `demo_capture/VisionFace2.mp4` から作り直し(`make_demo_gifs.sh` の
  visionface 行を VisionFace2.mp4 / 4.0秒に変更)。**2.0MB → 1.2MB と尺を伸ばして軽くなった**
  — カメラ固定+無地背景で毎フレームの変化画素が減ったため(GIFはフレーム間差分でしか縮まない)
- 素材自体も 5.3MB → 3.5MB
- **demo.toe の利用例コンテナは既定で `allowCooking = False`**(43/47コンテナ。常時ONだと
  全例のML推論が同時に走るため)。そのため中の moviefilein は 128x128 のまま=非ロードで、
  MCPから `cook(force=True)` しても**中身は cook されない**。
  検証するときは **一時的に `comp.allowCooking = True` にして cook → 確認 → False に戻す**
  (この手順で src 1280x720・out1 1280x720・valid=10 を実測。戻し済み)

### 2026-08-09 Metal Denoise: 非対応ハードをエラーから「警告+素通し」に変更

- ユーザー報告「MetalDenoiseのdemoがエラーで動いてない」。原因は既知の
  **M2 が VTTemporalNoiseFilter 非対応**(`isSupported=false`)。バグではないが、
  デモとしては赤いエラーノードで壊れて見える
- **挙動を変更**: 非対応ハード / macOS 26 未満は `getErrorString` ではなく
  **`getWarningString` + 入力の素通し**(`passthrough()` を追加)。非対応マシンで
  開いただけのネットワークが下流ごと止まらないようにする
- **検証(TD再起動なし)**: 新バイナリを `/private/tmp/.../dn_<epoch>/` にコピーして
  素の `cplusplusTOP` の Plugin Path で読ませ、**errors 空 / warning のみ /
  出力 1280x720 が入力と同一**を視認確認(同一パスはプロセス内キャッシュで旧コードのまま)
- demo.toe の note を書き換え。**当初「このMacでは」と書いたが、demo.toe は配布物で
  実行環境は人それぞれなのでその書き方は無意味**(ユーザー指摘)。
  「対応ハードでのみ効果がある / 非対応なら警告+素通し / 警告が出ていなければ効いている /
  判定は vtprobe で」という**環境に依存しない書き方**に修正した。
  MetalDenoise コンテナの allowCooking も他と揃えて False に戻した
- README(MetalDenoise 英日 + ルート英日一覧)を「エラー」→「警告+素通し」に更新
- **注意**: 稼働中のTDは常設パスの旧バイナリをキャッシュしているため、
  `/project1/MetalDenoise` は**TD再起動までエラー表示のまま**

### 2026-08-09 Metal Upscale の PROBE 警告 = 私のデバッグコードの消し忘れ(インストール済みのみ)

- ユーザー報告「Metalupscaleでもwarningが出てる」。中身は
  `Warning: PROBE init=1 step=3 val=0 active=0 w=1280` で、**NC解像度上限の調査(08-08)で
  MetalUpscale に一時的に入れたプローブ**がそのままインストールされていた
- **範囲を確定**: ソース(.mm)・リポジトリの `build/`・`dist/`・**リリースDMG v0.9.3 とも PROBE は 0件**。
  汚れていたのは `~/Library/.../Plugins/` の**インストール済みバイナリ1つだけ**(08-08 22:19)。
  インストール済み全66バンドルを strings で走査して他に無いことも確認
- リポジトリの build 成果物(=v0.9.3 リリースビルド)を再インストールして解消。
  バージョン付きパス方式で検証し **errors/warnings とも空・640x360→1280x720** を確認
- **教訓**: 調査用のプローブを入れたら、**ソースから消すだけでなく常設Pluginsへ再インストールし直す**。
  ソースはきれいなのにインストール済みだけ汚れている、という状態は気づきにくい。
  `strings <installed>/Contents/MacOS/<exe> | grep PROBE` で一括確認できる
- 参考: インストール済みの他62バンドルは 08-07〜08-08 のビルドで、リポジトリの
  v0.9.3 ビルド(08-09 07:46)とバイナリが異なる。ほとんどは同一ソースの焼き直しだが、
  開発環境をリリースと完全に揃えたい場合は全件再インストールする

### 2026-08-09 LLM AFM の利用例に LINE 風チャットUIを追加(英語)

- ユーザー要望。`/project1/LLMAFM/chat`(base COMP・720x1280 の縦画面)を新設し、
  会話テーブルを吹き出しで描く。コンテナ直下に `out1` を追加してデモ一覧にも出るようにした
- **構成**: 吹き出し1個 = `t{i}`(CoreText TOP・本文)+ `r{i}`(Rectangle TOP・角丸)を
  `o{i}`(Over)で重ね、`comp1`(Composite・over)で全部を背景+ヘッダーに載せる。8スロット固定。
  レイアウトは `chatui`(Execute DAT / **onFrameEnd**)が毎フレーム計算
  (非同期な C++ DAT は onTableChange が安定して発火しないため。既存 handler と同じ理由)
- **各吹き出しは画面全体(720x1280)のキャンバス**にして、位置は CoreText の
  **Padl/Padr/Padt/Padb** と Rectangle の centerx/centery(pixels)で決める。
  こうすると Transform TOP を挟まずに済み、ノード数が 1吹き出し=3個で収まる
- 幅は文字数からの見積り(**34pt で 1文字≒15px・行送り 42px** が実測)。ずれても
  CoreText の **Auto Fit** が縮めて収めるので破綻しない
- **踏んだ罠**: ①`create(coretextTOP,…)` は不可 → カスタムOPは **`create('CoretextTOP', …)`**
  (先頭大文字opType + FAMILY大文字)②base COMP を Out TOP に繋ぐのは
  `connect(comp)` ではなく **`connect(comp.outputConnectors[0])`**
  ③MCPの `run` は exec スコープなので、**全部を1つの関数に入れて呼ぶ**と変数が見える
- **構造化出力(Schema)は解除した**。JSON が返るとチャットとして読めないため。
  ツール呼び出しはそのまま
- **実測(M2・実会話)**: 「What is the temperature on stage?」→ **ツールを使わず**
  「取得できません」/「Use the get_sensor tool with name "temperature".」→ **ツールを呼び 42.0**。
  ツール名を明示すべき、という既知の癖がそのままデモになった
- **新しく分かった制約**: オンデバイスモデルは**コンテキスト窓が小さい**。40語程度の
  Instructions + 3ターンで `error: Exceeded model context window size` になる。
  Instructions を短くし、出たら Clear Conversation。LLMAFM/README(英日)に追記

### 2026-08-09 今セッションの罠を skill へ反映

ユーザー指示「踏んだ罠はskillsにも反映できる事はしておいて」。4ファイルへ振り分け:

- **td-apple-plugin/verification.md**: ①`run` の exec スコープ回避は「インラインで書く」だけ
  でなく**処理全体を1関数に入れて呼ぶ**のが確実、と追記(今回何度も効いた)
  ②TDノード操作の節を新設(カスタムOPは `create('<OpType>TOP', name)` / base COMP は
  `connect(comp.outputConnectors[0])` / シーケンスは `seq.<name>.numBlocks` /
  OP参照parはパス文字列 / glslmultiTOP は `_pixel` 等が自動ドック生成)
  ③**demo.toe の利用例は `allowCooking = False`** で、force cook しても中は cook されず
  読めた値は残留値、という節を新設
- **td-apple-plugin/build.md**: ①調査用デバッグコードは**ソースから消すだけでなく再インストール**
  が要る(strings で一括監査するワンライナー付き)②リリース物は**リポジトリの build/ から集める**
  (インストール済みフォルダから集めると第三者製が混入する)
- **td-apple-plugin/pitfalls.md**: ①VT系は**対応チップ一覧が非公開**で `tools/vtprobe.m` で実測
  ②**非対応ハードはエラーではなく警告+素通し**にする設計指針 ③Core Text の実測値
  (英字34ptで1文字≒15px・行送り42px)と `Padl/Padr/Padt/Padb` で Transform 無しに配置できること
- **td-apple-ops/wiring.md**: ①LLM節に**コンテキスト窓が小さい / ツール名を明示 /
  Schema とチャット表示は両立しない**を追加(末尾の重複bulletは統合して削除)
  ②「会話をチャット画面として描く」レシピを新設 ③Vision Face のランドマークを
  **p0..p75 → p0..p84(85点)** に訂正し、鼻の描き方を追記
- **td-apple-ops/troubleshooting.md**: ①「demo.toe の利用例が動かない/値が更新されない」=
  allowCooking ②「警告は出るが映像は流れている(Metal Denoise)」を追加
- リポジトリ外の個人skill **~/.claude/skills/touchdesigner-dev** にも、TD汎用の4点
  (exec スコープ・カスタムOPのcreate・outputConnectors・allowCooking)を反映

### 2026-08-09 LLM AFM の例を2ノードに分離(Llmafm1=ツール / Llmafm2=チャット)

- ユーザーが `Llmafm2` を追加。**Llmafm1 はツール呼び出しのデモのまま**、
  **Llmafm2 を LINE 風チャットの表示元**にする、という分担にした
- `chatui` の先頭に **`SRC = 'Llmafm2'`** を置いて描画対象を切り替えられるようにした
  (以前は Llmafm1 をハードコードしていた)
- Llmafm2: **1文で答えられる質問7往復**に差し替え(ユーザー指示「長い返答が必要のない質問で」)。
  Instructions = `Answer in English in one short sentence.` / Max Tokens = **40**。
  bit / GPU / Python の immutable 型 / FPS / API / TDの拡張子 / 色の混色。
  **7往復通って status=ready のまま**(短い返答はコンテキストの伸びが遅い)
- 吹き出しは下から積むので、**入り切らない古い往復は自然に画面外へ流れる**(実チャットと同じ挙動)
- **傾向がはっきり出た: 一般的な用語は全問正解、TouchDesigner 固有の知識だけ誤答**。
  拡張子を「.td」と答える(正しくは .toe)。前回の会話でも CHOP の説明と
  `str.reverse()` のでっち上げで同じ傾向だった。ユーザー判断で**そのまま残し**、
  note に「どれが誤りか」と「知識に依存しない用途向き / 事実はツール呼び出しで渡す」を明記
- **Max Tokens を増やす必要はない**という結論: コンテキスト超過は Max Tokens ではなく
  「Instructions + 履歴 + 生成」の合計で起きる。長く続けたいなら
  **Instructions を短く・Max Tokens を小さく**が正解(40語+512で3往復 → 7語+40で7往復)
- Llmafm1: Instructions をツール用に戻し、`get_sensor` の往復を1回実行して
  「42.0 degrees」が出る状態にした
- ユーザー側の調整はそのまま活かした: 背景を灰(0.7)に変更、`chat/out1 -> fit1 -> out1` で
  720x1280 の縦画面を 1280x720 に収めてデモ一覧に載るようにしている
- note を2ノードの役割分担で書き直し。**チャット表示側は Schema を空にする**
  (JSON が返ると会話として読めない)ことも明記

### 2026-08-09 チャットデモに日本語版を追加(英日を並べて表示)

- ユーザー「日本語版もお願い」。`Llmafm3`(日本語)+ `chat_ja` を追加し、英日を横並びで出す
  - `Llmafm2 → chat → pad_en` / `Llmafm3 → chat_ja → pad_ja` → `both`(Over)→ `fit1` → `out1`
  - `chatui` を **`PAIRS = [(DAT名, chatコンテナ名), ...]`** にして1つの Execute DAT で両方描く
- **日本語対応で `chatui` の折り返しを書き直した**(ここが本題):
  - **日本語は分かち書きしない**ので、単語単位の折り返しだと1行が伸びきってしまう。
    **全角は1文字ずつ・半角の連なりは1単語**としてトークン化してから詰める
  - 文字幅も別 — **全角 34px / 半角 15px**(34pt 時)。`cols`(文字数)ではなく
    **ピクセル幅**で折り返すよう変更した。混在文でも破綻しない
  - `chat_ja` の CoreText は Font を `HiraginoSans-W3` に明示(SFでもフォールバックはするが確実に)
- **横並びは Layout TOP をやめた**。`align` の値が `horizltr` ではなく `horizlr` で、
  無効値を入れても**黙って none のまま**になる。さらに fit/解像度の組合せで結果が安定しなかったので、
  **Fit TOP(1440x1280・fit=nativeres・justifyh=left/right)×2 → Over** の手組みにした。確実
- **日本語は英語より精度が落ちるのが実測で出た**(そのまま残す):
  - 「赤と青を混ぜると?」→ **「青」(誤り)**。英語の同じ質問では purple と正答
  - FPS を「Frame **Per** Second」(正しくは Frames)
  - 一方 1バイト=8ビット / GPU の略 / Python のイミュータブル型 は正答
- note を3ノード構成に書き直し、**どれが誤答か**と「知識に依存しない用途向き」を明記

### 2026-08-09 英日チャットを同時再生するドライバを追加(キャプチャ用)

- ユーザーがレイアウトを修正(`chat` + `chat_ja` → `layout1` → `fit1` → `out1` + `moviefileout1`)。
  「同時に二つの会話をしてみて」を受けて、**英日へ同じ内容の質問を同時に投げるドライバ**を追加
- **`chatdrive`(Execute DAT / onFrameEnd)+ COMP の `Play Conversation` パルス**:
  Clear → 質問を Llmafm2/Llmafm3 へ**同時 Submit** → **両方の busy が下りるまで待つ** → 次へ。
  質問リストは `PAIRS`、読む間合いは `SETTLE`(既定100フレーム≒1.7秒。キャプチャ向けに緩め)
- 完了判定は **Info CHOP の `busy`**(`info_llmafm2` / `info_llmafm3` を新設)。
  行数の増加で判定するより確実
- **2つの LLM AFM は同時に生成できる**(実測)。6往復×2=12生成が約20秒で完了し、
  12件すべて完全な文で返った。セッションはインスタンスごとに独立している
- **同じ質問セットでの英日の差(実測)**: 英語 6/6 正解、日本語 5/6。
  外したのは「赤と青を混ぜると?」→「青」(英語では purple と正答)。
  今回は FPS も日本語で "Frames Per Second" と正答した(前回は Frame)
- note に再生手順を追記
- **踏んだ罠**: `c.customPars` は**プロパティ**(`customPars()` と呼ぶと
  `'list' object is not callable`)。ただしこのエラーが出た時点で
  ノード生成自体は完了しているので、作り直す前に状態を確認する

### 2026-08-09 英日チャットのデモGIFを追加 + READMEにモデル名と誤答の注記

- ユーザーが `demo_capture/LLMAFM_chat.mp4`(1280x720・16.1秒)をキャプチャ。
  空の状態から英日の会話が同時に育っていく流れがそのまま撮れている
- GIF 化して `docs/demo/llmafm-chat.gif`(480x270・12fps・128色・**648KB**)。
  **文字が主役なので色数を上げたが、背景が動かないので16秒の長尺でも軽い**
  (人混みの街路が4秒で1.8MBだったのと対照的)。README(英日)のデモ表に6行目として追加
- ユーザー指示「どのモデルで出力しているのか、間違いが含まれている事など簡単にREADMEには示して」:
  - デモ節の導入に、**外部Core MLモデルはキャプションに名前を書いている(Depth Anything V2 /
    YOLOv3)/ LLM は Apple Intelligence 内蔵の ~3B / 出力は加工せずそのままなので
    モデルの誤りもそのまま映る / ~3B は固有知識が当てにならないので下書き扱い**、を追記
  - LLM AFM のキャプションに **「日本語側の『赤と青を混ぜると青』は誤答(英語側は purple と正答)」**
    を明記。誤答を残していることが README だけで分かるようにした

### 2026-08-09 VisionPose3D の高速化(リクエスト使い回し)+ 古い性能値の訂正

- ユーザー「VisionPose3Dのfpsは改善できないか?」。**まず何が効くかを単体harnessで実測**してから着手
  (`scratchpad/pose3dbench.m`。VNDetectHumanBodyPose3DRequest を条件別に測る)
- **効いた: リクエストオブジェクトの使い回し**。実装は**毎フレーム
  `[[VNDetectHumanBodyPose3DRequest alloc] init]` していた**ので、ワーカーが1個持って再利用するよう変更
  (ハンドラは画像ごとに必要なので毎回作る)
- **TD実機のA/B(同一入力で並走させて公平に比較)**: 新 **165ms / 307解析** 対
  旧 **323ms / 141解析** → **約2倍**。単独で走らせた新ビルドは **111ms・毎秒8.5回**
- **効かなかった手も実測して README に残した**(同じ質問が再燃しないように):
  - 入力縮小 1280x720→480x270: 182→159ms。Vision が内部でリサイズするので割に合わない
  - `setComputeDevice:forComputeStage:` で ANE/GPU 明示: 166/163ms 対 指定なし166ms = **差なし**
  - IOSurface 付きバッファ: 差なし(158ms)。**revision は 1 しか無い**
- **README の「約0.5秒/フレーム(≒2fps)」は古かった**(7月の値)。現行は 110〜170ms(毎秒6〜9回)。
  ルートREADME(英日)の一覧も「約2fpsのじっくり系」→「毎秒6〜9回」に修正
- **教訓**: 「遅い」と書いてある実測値は OS 更新で変わる。高速化を頼まれたら
  **まず現状を測り直す**(今回は半分が OS 側の改善、半分がコード側だった)

### 2026-08-09 VisionPose の骨格線を「線」から「リボン(四角形)」へ + Wire Width は効かないと判明

- ユーザー「VisionPoseの体の関節をlineで繋いで」。**骨格線自体は 2026-08-08 に実装済み**
  (`geo2/skeleton` Script SOP・19本)で、5人ぶん92本が正しく生成されていた。見えなかった原因は
  **① lineMAT が白のまま**(Hand=橙/Face=青/AnimalPose=黄 は色を付けたのに Pose だけ白が残っていた。
  白い studio 背景+白い点スプライトに完全に埋もれる)**② 線が 1px**
- **`Wire Width` はまったく効かないと実測で確定**: Constant MAT の Wire Width を **1 と 12** で
  レンダして緑画素を数えたところ **どちらも 4171px で完全一致**。macOS/Metal は
  ライン primitive の太さが常に 1px(Wireframe の on/off も無関係)。
  2026-08-08 のログの「4例すべてで Wire Width を 3 に(見えにくかったので)」は**効果が無かった**
- **修正**: skeleton を 2点の線ではなく **細長い四角形(リボン)** を出すよう書き換え。
  進行方向に垂直なオフセット `n = (-dy, dx)/len * half` で4点を作り
  `appendPoly(4, addPoints=False, closed=True)`。`Width` custom par(uv単位・既定 0.005)を追加。
  **Aspect Correct UVs = On + Ortho Width = 1 では uv の1単位が縦横とも同じピクセル数**になるので、
  太さを uv 単位で素直に指定できる(0.005 ≒ 1280px 幅で 6px)。四角形の継ぎ目は関節の点スプライトが隠す
- lineMAT を緑(0.1, 1.0, 0.35)に。**実測**: 5人×19本=95プリム/380点、エラー・警告なし。
  レンダを視認して全員の骨格がはっきり出ることを確認
- skill `td-apple-ops/wiring.md` の「線が細いときは Wire Width を上げる」という**誤った助言を削除**し、
  リボン方式のコード片に差し替え。demo.toe の note も更新(allowCooking は False に戻して保存)
- **未着手**: VisionHand / VisionFace / VisionAnimalPose も同じ 1px のままなので、同じリボン方式に
  するかはユーザー判断待ち(色は付いているので Pose ほど見えないわけではない)

### 2026-08-09 VisionPose3D にも骨格線(3Dビルボードリボン)

- ユーザー「VisionPose3DもLineで繋いで」。VisionPose(2D)と違い、こちらの例は
  **メートル単位の実3D座標**(`{joint}:tx,ty,tz`・腰が原点)を perspective カメラで見る構成
  (映像への重ね合わせではない)。なので骨も3D空間に置く
- `geo2/skeleton`(Script SOP)→ `sop2pop` → `out1`(render/display On)を新設し、
  `lineMAT`(Constant・シアン 0.2/0.9/1.0)を geo2 に。render1 は `geometry='*'` なので自動で拾う。
  17関節を **16本**の骨で接続(root→spine→center_shoulder→center_head→top_head、両腕、両脚)
- **3Dリボンはビルボードにする**: 平面リボンだと横から見たとき紙のように消える。
  `cross(骨ベクトル, 骨の中点→カメラ位置)` の向きへ広げれば常にカメラを向く。
  カメラ位置は `cam.worldTransform` の最終列(取れなければ par.tx/ty/tz へフォールバック)。
  骨が視線と平行(外積≈0)のときは描かない
- そのため **Trigger は totalCooks ではなく `absTime.frame`**。ポーズ更新は毎秒6〜9回だが、
  カメラを動かしたらビルボードを向け直す必要があるので毎フレーム cook させる
- **実測**: 16プリム/64点・エラー警告なし。正面と **カメラを55°回した状態**の両方でレンダを視認し、
  回しても骨の太さが変わらない(ビルボードが効いている)ことを確認。Width は메ートル単位・既定0.02
- note の「約2fps」も実測値(毎秒6〜9回)に修正
- **検証時の注意**: `.save()` した PNG を白背景で見ると、白い点スプライトが骨の上に乗って
  **骨が途切れて見える**。レンダ背景は透明なので、暗色に合成して確認すること(実際に一瞬誤診した)
- **CHOPチャンネルの存在判定に真偽値を使わない**: `if vp['root:tx']` は値が 0.0 だと False になる
  (root は原点なので必ず踏む)。`is None` で判定する

### 2026-08-09 ループ区間探索ツール(tools/find_loop.py)

- ユーザー「ダンスでループ可能な素材にできればしたい」。生成AIの動画は素で貼ると必ず
  継ぎ目で飛ぶので、**一番よく繋がるフレーム対を探して切り出す**ツールを用意
  (Schödl らの Video Textures と同じ考え方)
- 動画を 160x90 グレースケールに落とし、候補 (i, j)=「フレーム i..j-1 を再生して i に戻る」
  について継ぎ目の段差を測る。**連続フレーム間の差分の中央値を基準**にして比で出すので、
  「何倍なら見えるか」が素材によらず判断できる(実測: 3倍を超えると厳しい)
- **踏んだ罠(合成データで捕まえた)**: 継ぎ目のコストを `d(f[j-1], f[i])` にすると
  **末尾と先頭が同じ絵になり1フレーム重複する**。正しくは「本来 j-1 の次に来るはずの
  フレーム j」と先頭 i の差 `d(f[j], f[i])`。周期ちょうど48フレームの合成ループで検証したら
  修正前は 2.04秒(49フレーム)、修正後は **2.00秒(48フレーム)** と正しい周期を返した。
  実素材だけで試していたら気づけなかった
- 動きの向きが逆の点を掴まないよう、前後1フレーム `d(j-1,i-1)` `d(j+1,i+1)` も 0.5 の重みで加算
- 動きの少ない素材で基準値が 0 になり 0除算で落ちるのも合成テストで発見 → 下限を入れた
- **現行 `Assets/sample_ballet.mp4` の実測**: 最良でも継ぎ目が基準の **5.84倍**。
  = この素材はどこで切ってもループしない(開始と終了のポーズが揃っていないため)
- 使い方: `python3 tools/find_loop.py <video> --min 4.0 [--out <cut.mp4>]`
- **注意**: `sample_ballet.mp4` は VisionPose3D だけでなく **VisionRect の `art`**
  (ノートPC画面に貼り込む映像)でも使っている。差し替えではなく新規ファイルにすること

### 2026-08-09 VisionPose3D に Coordinate Space(root / camera)を追加

- ユーザー「VisionPose3Dにはカメラを原点にそこからの相対座標にする機能はない?」→ **無かった**ので追加。
  `Coordinate Space` メニュー(root=既定・従来どおり / camera)。既定が従来値なので後方互換
- 実装: 観測時に `out.toCamera = simd_inverse(obs.cameraOriginMatrix)` を保存し、cook で
  Space=camera のとき各関節に掛ける。**cookでの切替なので再解析不要**(同じフレームで両モードを
  厳密比較できる)
- ~~**TD側の引き算では代用できないことを実測で確認**~~ **← この段落は誤り。次のエントリで訂正**: `camera:tx,ty,tz` はプラグインが
  `cameraOriginMatrix` の**平行移動列だけ**を出しており、回転は落ちている。同一フレームで比較すると
  引き算だと腰が `(0.006, -0.144, 2.420)`、正しい `inverse(matrix)` では `(-0.434, -0.573, 2.315)`。
  **0.62m ずれる**(カメラからの距離はどちらも 2.424m で一致 = 純粋に回転ぶんの向き違い)。
  これが「TDでやらずプラグインに入れる」根拠
- `camera:tx,ty,tz` は両モードとも root 基準のまま(カメラ基準では定義上ゼロで情報が無い)。
  カメラ空間では被写体が **+Z 側**に来る
- **TD再起動なしで検証**: 新バンドルを `/tmp/.../vp3_<epoch>/` にコピー(cp -R 後は要再署名)し、
  素の cplusplusCHOP の Plugin Path で読ませた。稼働中のTDを止めずに新パラメータを確認できる
- README(英日)にモードの表と 0.62m の実測を追記。バンドルはインストール済み
  (**demo.toe の `Visionpose3d1` に Space par が出るのは TD再起動後**。既定=root なので
  それまでの挙動は変わらない)
- 未着手: demo をカメラ空間に切り替えるかは新素材(前後移動あり)が来てから。切り替えると図が
  z≈+2.3・中心から 0.4〜0.6m ずれた位置に出るので、表示カメラの再フレーミングが要る

### 2026-08-09 【訂正】cameraOriginMatrix は逆行列ではなく「そのもの」を掛ける

- 直前のエントリで「Space=camera は `inverse(cameraOriginMatrix)` を掛ける」「TD側の引き算だと
  0.62m ずれる」と書いたが、**どちらも誤り**。ユーザーが実機で「camera at origin は上手く
  動いてなさそう」と気づいて発覚(図が画面外へ飛んでいた)
- **切り分け**: 静止したカメラなのに腰のカメラ基準位置が
  `(-0.43,-0.57, 2.32)`(ほぼ+Z)→`(-2.40,-0.07, 0.16)`(ほぼ-X)と 90° 振れた。
  距離だけは 2.41m で一致 = 回転の掛け方が違う、と当たりを付けた
- **決め方(推測せず実測)**: 候補ごとにカメラ空間の点を射影(`x/z`, `y/z`)し、焦点距離を最小二乗で
  当てはめて **Vision 自身の `pointInImage` との再投影残差**を8フレームで測った
  (`scratchpad/projtest2.m`):

  | 候補 | 平均残差(正規化画像座標) |
  |---|---|
  | **`M * p`** | **0.00000**(全フレーム厳密一致) |
  | `p - t` | 0.01309 |
  | `inverse(M) * p` | 0.02663 |

- **結論**: `cameraOriginMatrix` は名前に反して **model → camera** の変換。カメラ基準は `M * p`。
  カメラ空間は **-Z 前方**(TDのカメラと同じ規約)で、被写体は -Z 側に来る。
  既存の `camera:tx,ty,tz`(= M の平行移動列)も「カメラの位置」ではなく
  **「腰のカメラ基準位置」**が実体だった(README の説明も訂正)
- **教訓**: 行列の向きは名前から推測しない。**Vision が別途返している 2D 投影 (`pointInImage`) が
  ground truth になる**ので、再投影残差で決めれば一発で分かる。相関係数だけだとどの候補も
  0.98 超で差が出ず、判定できなかった(最小二乗フィット後の残差にして初めて 0.00000 が見えた)
- 修正版をビルド・インストールし **TD再起動して実機確認**: 腰が `(0.014, 0.064, -2.510)`
  = 画面中央のダンサーがカメラの 2.5m 前、頭 +0.845 / 足首 -0.884 で身長 1.73m。妥当
- demo の `cam1` は原点だと**見切れる**(TD の FOV Angle は**水平**なので 16:9 だと縦が足りない)。
  `tz = 2.5` に引いて全身が収まることを視認確認

### 2026-08-09 VisionPose3D の camera:* を cam:* 一式へ作り直し(破壊的変更)

- ユーザー「互換性は無視して破壊的変更をしても構わないので、camera:tx,ty,tz を使いやすい様にして」
- 旧 `camera:tx,ty,tz`(3ch)は名前と実体がずれていた(実体は「腰のカメラ基準位置」)。
  **9ch の `cam:*` 一式に置換**(91ch → 97ch):

  | チャンネル | 内容 |
  |---|---|
  | `cam:tx,ty,tz` | カメラ位置(人物 root 基準) |
  | `cam:rx,ry,rz` | カメラ回転(度・**TD Camera COMP にそのまま挿せる**) |
  | `cam:distance` | レンズ〜腰の距離(m) |
  | `cam:azimuth` / `cam:elevation` | 腰が光軸から何度ずれているか(+右 / +上) |

- **接頭辞を `cam:` に統一したのが要点**。関節だけ欲しいときは Select CHOP の `^*cam*` 一発で
  落とせる(demo の select4 がまさにそれで、`^*camera*` → `^*cam*` の1文字修正で済んだ)
- **TD の Rotate Order は実測で確定**: カメラに rx20/ry30/rz40 を入れて `worldTransform` を読み、
  候補行列と突き合わせた結果 **`R = Rz·Ry·Rx`**(小数5桁一致)。分解は
  `ry=asin(-r20) / rx=atan2(r21,r22) / rz=atan2(r10,r00)`
- **検証(ピクセル一致)**: ①root 空間 + カメラを `cam:t*`/`cam:r*` で駆動 ②camera 空間 +
  カメラ原点 ——この2つのレンダが **平均絶対差 0.0000・インク画素数も 22284 で完全一致**。
  Euler 抽出と回転順が正しいことの決定的な確認になった(動画は play=False で固定して比較)
- **踏んだバグ**: 固定チャンネルを 6→12 に増やしたのに、**関節側の書き込みが
  `channels[6 + j*5 + c]` のままだった**ため cam系の後半を上書きして全体がずれた。
  症状は `cam:distance` が 0.525 なのに `|root(camera space)|` は 2.52、という不整合。
  **チャンネル数を変えるときは getChannelName と execute の両方のオフセットを直す**
  (定数 `kFixedChans` に集約して再発を防いだ)
- README(英日)を新チャンネル表+検証結果に更新。demo の note にも cam:* の説明を追加。
  Space の説明に残っていた「被写体は +Z」の誤りも -Z に訂正

### 2026-08-09 VisionPose3D 評価ツール(tools/pose3d_eval.m)+ 骨の長さは固定モデルと判明

- ユーザー「ダンス以外の、関節の動きの正しさを評価できる素材を作りたい」→ 先に**測る手段**を用意
- **最初の案は外れだった**: 「人体は剛体なので骨の長さは一定のはず。その揺れ=推定誤差」で
  実装したら、**上腕 0.3165 / 前腕 0.2475 / 腿 0.4705 / 脛 0.4849m が全フレーム完全一定**、
  しかも **sample_ballet と sample_pose3d(別人・別動画)で1桁まで同一**だった。
  → **Vision は固定プロポーションの人体モデルを角度だけ合わせている**。長さの一定性は
  構造上の定数であって品質と無関係。同じ理由で**人物の体格は測れない**
  (肩幅だけ CV 0.8%、脊椎 0.1% とわずかに動く。他は完全固定)
- `pointInImage` との再投影誤差も 0(3Dから導出された値なので独立でない)ため指標にならない
- **採用した指標: 2D姿勢推定(`VNDetectHumanBodyPoseRequest`)との食い違い**。別モデルなので
  独立した比較対象になる。3D関節を画像に投影して 2D検出の位置と px で比較する
- **ベースライン(1280x720・6fps サンプリング・48フレーム)**:

  | | sample_pose3d | sample_ballet |
  |---|---|---|
  | 全関節平均 | **21.3 px** | 21.6 px |
  | neck | 13.6 | 18.4 |
  | 肩 | 15〜16 | 18〜20 |
  | 肘 | 16〜17 | 15〜20 |
  | 手首 | 20〜24 | 23 |
  | 膝 | 22〜29 | 20〜34 |
  | 足首 | **31〜37** | **30** |

  **末端ほど誤差が大きい**(neck 13.6 → 足首 37)という素直な傾向。最悪値は足首 296px /
  手首 314px と跳ねるので、そのフレームを見に行けば苦手なポーズが分かる
- **ビルドの罠(再発)**: `clang ... 2>&1 | head -5` は **head がパイプを閉じて clang が SIGPIPE
  で死ぬ**ためリンクまで到達せず、警告だけ出て**バイナリができない**。
  CLAUDE.md 既出の `codesign | grep -q` と同じ型。パイプで切るなら `| tail` か変数に取る

### 2026-08-09 GT付きデータセットは使えず → 幾何的不変量で評価する方式に

- ユーザー「同梱しないので、正解データのわかるデータと動画をダウンロードして使ってみて」
- **調べた結論: 動画+3D正解が揃うデータセットは軒並み非商用・要申請で、法人では使えない**
  - **AIST Dance Video DB**: 学術研究限定・**商用不可**・再配布禁止・**申請フォーム必須**
    (AIST++ の**アノテーションだけ**は GitHub Releases から直接落とせて CC BY 4.0 だが、
    対になる動画が上記なので意味がない。落としかけて中断・削除した)
  - **MoVi / BML**: 「非商用・学術研究目的のみ。商用利用は禁止」と明記
  - Human3.6M / MPI-INF-3DHP / 3DPW / BEDLAM も登録必須・研究ライセンス
  - **Pexels / Pixabay / Mixkit** は利用自体は自由だが**再配布禁止**なのでリポジトリ同梱は不可
    (ローカル評価だけなら可)
  - **Wikimedia Commons の CC BY** が唯一「同梱もできる」選択肢
- **方針転換**: 正解データセットを探すのをやめ、**幾何的に正解が分かる不変量**を測る方式に。
  `tools/pose3d_eval.m` に追加: `torso_pitch`(体幹が鉛直から何度)/ `head_tilt`(体幹に対する頭)/
  `arm_elev_L/R`(腕が水平から何度)/ `knee_flex_L/R`。**T-pose なら arm_elev が 0 で左右一致**、
  **お辞儀なら torso_pitch が 0→90 に振れる**、というように正解が事前に分かる
- **踏んだ罠(自分のツールのバグ)**: 最初 model 空間で角度を測ったら、スクワットなのに
  `torso_pitch` の range が **10.9°** しか出なかった。**model 空間の +Y は体幹軸に沿っている**ため、
  体幹の傾きは定義上ほぼ 0 になる。**カメラ空間(`M * p`)で測り直すと 8.8→38.1°(range 29.2°)** と
  実際のバックスクワットの前傾に一致した。**「人が前に倒れているか」を知りたいなら Space=camera**
- 実測(Wikimedia CC BY のスクワット映像・[FitnessScape](https://commons.wikimedia.org/wiki/File:Squat_-_exercise_demonstration_video.webm)):
  膝の曲げ 40→158°(正しい)・体幹 8.8→38.1°(正しい)。2D比較スコアは 34.6px
  (ダンス素材 21.3px より悪い = 後ろ姿+バーベル遮蔽の難しさが数字に出ている)

### 2026-08-09 モーション評価用素材の置き場を eval/ に決定(git 同期しない)

- ユーザー「gitに同期しないモーション評価用動画を入れるフォルダを決めて」
- **`eval/`** を新設。`models/` と同じ「中身は除外・README だけ共有」方式
  (`.gitignore` に `eval/*` + `!eval/README.md`)
- **分離する理由は容量ではなくライセンス**。評価に使いたい素材は再配布できないものが多く
  (Pexels/Pixabay/Mixkit は再配布禁止、研究用データセットは商用不可)、**コミットされる
  `Assets/` に置いてしまう事故**を防ぐのが目的。README に「ここに置いてよい/`Assets/` に
  置いてよい」の対応表を書いた
- README には評価の手順(ffmpeg で 6fps 展開 → `tools/pose3d_eval.m`)、**比較用ベースライン**
  (sample_pose3d 21.3px / sample_ballet 21.6px / Wikimediaスクワット 34.6px)、
  撮るべきポーズと「そのポーズで何の正解が分かるか」の対応、既知の落とし穴
  (角度はカメラ空間で測る・骨の長さは使えない・メートルは1.8m仮定)をまとめた
- 手元の Wikimedia CC BY スクワット映像を
  `eval/wikimedia_squat_CC-BY_FitnessScape.webm` として配置(**ファイル名に出典と
  ライセンスを入れる**運用にした。後から素性が分からなくなるのを防ぐ)。
  `git check-ignore` で除外されていることを確認済み

### 2026-08-10 eval/ の実素材7本で VisionPose3D を評価(Tポーズ/お辞儀の正解チェック含む)

- ユーザーが `eval/` に7本投入(モーションアクター社の Tポーズ/お辞儀/やったー/不屈、
  コンテンポラリーダンス、モデルのポージング、Wikimediaスクワット)。ユーザー指示で
  **`eval/` は README も含めて丸ごと gitignore**(`eval/*`+`!README` → `eval/`)に変更
- **指標の欠陥を1つ修正**: ズレを px で出していたが、それだと **1920幅の映像が 1280幅より
  不利**になり、被写体が小さく写っているだけで良く見える。**2D検出点の縦の広がり(=人物の
  身長)に対する % に正規化**した(`VNHumanBodyPoseObservation` に boundingBox は無いので自前算出)
- `tools/eval_video.sh` を追加(eval/ の全動画をまとめて評価。既定 3fps・150フレーム上限)

**結果(身長比%・小さいほど画像と整合)**

| クリップ | スコア | 検出率 | 備考 |
|---|---|---|---|
| **Tポーズ** | **4.79%** | 84.4% | 最良 |
| モデルのポージング | 6.20% | 95.3% | 直立中心 |
| スクワット(Wikimedia) | 7.81% | 95.2% | 後ろ姿+遮蔽 |
| コンテンポラリーダンス | 8.35% | 92.7% | |
| **お辞儀** | **8.56%** | 98.0% | |
| やったー(跳ぶ) | 10.84% | 90.6% | |
| **不屈(倒れる/起き上がる)** | **18.81%** | 84.7% | **最悪・Tポーズの約4倍** |

- **正解チェックは合格**: Tポーズで `arm_elev` が **L=-3.1° / R=-0.3°**(水平からのずれ)、
  **左右差 2.8°**。お辞儀は `torso_pitch` が 0.4→**51.4°** と正しく振れた
- **床/寝そべり系が明確に弱い**。不屈は右膝 31.4%(最悪 315%)・右足首 27.3%(最悪 417%)と
  桁違いに崩れる。倒れた姿勢では**下半身がほぼ当てにならない**
- Tポーズでも **左手首だけ 11.7%** と他(3〜5%)から浮く。左右非対称な崩れ方をする傾向は
  スクワット(後ろ姿)でも見えており、**片側だけ壊れる**のがこのモデルの典型的な失敗
- 検出率は Tポーズ 84.4% / 不屈 84.7% と低め。全身が画面内にあるかどうかに素直に効く

### 2026-08-10 bodyheight/heightestimation 削除 + Camera FOV パラメータ追加(intrinsics を渡せる)

- ユーザー「iPhoneならLiDARのdepthが取れるがMacには無い。bodyheightは意味のない数字では?
  不要なパラメーターは非表示にしたい」
- **削除(98ch → 96ch)**: `bodyheight` / `heightestimation`。**7クリップ・44検出で
  measured=0・bodyHeight=1.8000 固定**を実測。1つの値しか取り得ないチャンネルは出さない
- **ただし「Macだから無理」は不正確**。深度は `initWithCVPixelBuffer:depthData:orientation:options:`
  で渡すもので、これは **API_AVAILABLE(macos 14.0)**。正しくは「**TOP は色しか運ばないから無理**」。
  深度とカメラ内部パラメータを運ぶ入力経路を足せば measured にできる(将来の選択肢として記録)

- **副産物として重要な発見**: ユーザーの「cam:fov は映像素材ごとに計算している?」という質問を
  実測したら、**8クリップ(1280x720/1920x1080・被写体も画角もばらばら)すべてで 98.823〜98.824°**。
  = Vision は実カメラの画角を推定しておらず、**水平98.8°の広角を固定で仮定**していた
- **`VNImageOptionCameraIntrinsics` は macOS でも効く**(実測)。そこで **Camera FOV パラメータ**
  (既定0=Vision既定)を追加し、>1 なら intrinsics を組んで渡すようにした。TD実測(同一フレーム):

  | Camera FOV | cam:distance |
  |---|---|
  | 0(98.8°仮定) | 2.8 m |
  | 120° | 2.05 m |
  | 70° | 5.14 m |
  | 40° | 8.54 m |

- **姿勢そのものは画角に依存しない**(model空間の関節座標は全FOVでビット一致)。効くのは
  **カメラとの位置関係**だけ = `cam:distance` / `cam:t*` / `cam:r*` / camera空間の座標。
  骨格の形しか使わないなら 0 のままでよい、と README に明記
- 罠: `VNImageOptionCameraIntrinsics` の値は **NSData**(`NSValue valueWithBytes:objCType:` だと
  nil になり辞書生成で例外)。intrinsics は列優先 `simd_matrix(col0,col1,col2)` で
  `[[fx,0,0],[0,fy,0],[cx,cy,1]]`
- パラメータ変更時は `myLastCookSeen = -1` で静止画入力でも再解析させる

### 2026-08-10 cam:* の使い道を実測で確定(cam:ry = 演者の向き)

- ユーザー「cam:distance / cam:tx,ty,tz / cam:rx,ry,rz の使い道は?」→ 設計した本人として
  推測で答えず実測した
- **`cam:ry` は「演者がカメラに対してどちらを向いているか」**。独立指標(カメラ空間での
  左右肩の奥行き差 = どちらの肩がレンズに近いか)と**符号・大きさが完全に一致**し、
  `cam:ry` が ±65〜79° のとき画像上の肩幅が 0.004〜0.017 まで潰れる(=ほぼ真横)。
  0=正面 / ±90=真横。**向きをこれだけ直接取れるチャンネルは他に無い**
- **重要な性質**: `cam:*` は**演者自身の座標系から見たカメラ**なので、**三脚で固定していても
  `cam:ry` は振れる**(体と一緒に座標系が回るため)。「自分のカメラの姿勢」だと思うと混乱する。
  README に相対量である旨を明記
- `cam:distance` は近接演出用(Camera FOV 未設定でも単調なので相対値としては使える)。
  `cam:rx` は難フレームで暴れる(168°/-155°/-87° の外れ値はジャンプ中のフレーム)。
  `cam:tx,ty,tz` は `root` 空間でTDカメラを実カメラに合わせる用途に限られ、
  **`camera` 空間+カメラ原点と同じ絵**になる冗長性がある(体を原点に固定して回り込みたいときだけ有効)
- README(英日)に「どのチャンネルで何が分かるか/何に使うか」の表を追加

### 2026-08-10 cam:* を3chへ整理(cam:facing 新設)+ 前回の説明を訂正

- ユーザー「root空間でTDカメラを合わせる使い方はしない」「cam:ryが演者の向きというのがピンと
  こない、名前を変えたほうがいい」「cam:distance がわかれば fov も計算できる?」
- **前回の「cam:ry = 演者の向き」は不正確だった**。**全編ずっと後ろ姿**のスクワット映像で検証すると
  **ry は -35° 付近のまま動かず、代わりに rx が ±178° に振れる**。Euler 分解(ry=asin(...) は
  ±90° 頭打ち)のせいで向きの情報が2軸に分裂しており、**ry 単体では正面/背面を区別できない**。
  最初にダンス素材(ほぼ正面)だけで確認したのが甘かった
- **`cam:facing` を新設**: カメラ空間で「右肩→左肩」と上方向の外積=胸の法線を求め `atan2`。
  **±180° の全周**を1本で表せる。実測: 後ろ姿 +125〜138° / 正面 +5〜10° / 真横 ±74〜81°
- **削除**: `cam:tx,ty,tz`(root空間でTDカメラを合わせる用途専用・ユーザーが使わないと明言。
  camera空間+カメラ原点と同じ絵)、`cam:rx,ry,rz`(facing に置換)、
  `cam:azimuth`/`cam:elevation`(**`root:u,v` を角度にしただけ**。u から fov 経由で復元した値が
  +11.179 で azimuth と完全一致することを実測)。**96ch → 89ch**、cam系は 10 → 3
- **`cam:distance` は `cam:tz` ではない**(質問への回答)。ベクトル全体の長さで、実測では
  体のZ方向 2.16m に対し総距離 2.52m と 16% 違う
- **distance から fov は逆算できない**(循環)。同一フレームで `distance × tan(fov/2)` を測ると
  2.55〜2.62 とほぼ一定 = この積はショット固有の定数(演者の写る大きさ)であって情報が増えない。
  **ただし実距離をメジャーで1回測れば較正できる**: `K = distance_auto × tan(98.824°/2)`、
  `FOV = 2·atan(K/実距離)`。K=2.59 なら実距離5mで55°、3mで82°
- TD実機で 89ch・`cam:facing` が +76→-84 と振れること・errors なしを確認

### 2026-08-10 body:facing/pitch/roll に改名・拡張 + 関節回転は取得できないと確認

- ユーザー「camより人体の回転情報として分かる命名がいい」「rootや各関節の回転情報は取得できない?」
- **関節の回転は Vision から取れない**(実測で確定)。`VNHumanBodyRecognizedPoint3D.position` と
  `localPosition` は `simd_float4x4` なので期待したが、**3x3部分は全関節で完全に単位行列**
  (非対角の合計 0.0000・det 1.0)。中身は平行移動だけ。骨の**向き**は位置から作れるが、
  骨まわりのひねり(前腕の回内など)は点からは原理的に復元不可
- **`cam:facing` → `body:facing` に改名し、`body:pitch` / `body:roll` を追加**(91ch)。
  体幹の3自由度が揃った。`right`=肩ベクトル / `fwd`=胸の法線 / `up`=世界の上 で体の枠を作り、
  pitch・roll を**演者自身の枠**で測るので、どちらを向いていても「前に曲げた」が同じ意味になる
- **検証中に自分が素材を読み違えた**: Tポーズ素材で facing が ±90 と -6 を行き来するのを
  「不安定」と誤解したが、フレームを見たら**正面と横向きを実演している映像**で、値は正しかった。
  数値がおかしいと思ったら**まず素材を見る**
- お辞儀素材(モーションアクター)は**後ろ姿・小さい・マーカースーツ**で推定自体が不安定。
  指標の検証には向かない素材だった(スコア 8.56% だったのも納得)
- 実測: 直立で pitch/roll とも ±3° 以内、お辞儀で pitch +31°、
  facing は 後ろ姿 +125〜138° / 正面 -6° / 真横 ±89〜91°

### 2026-08-10 深度入力の検証は失敗(Vision が落ちる)+ 深度で何が変わるかの整理

- ユーザー「depthデータがあったら精度が上がる?」→ 手元に深度付き素材が残っていないので
  **人物セグメンテーションから合成深度を作って**比較しようとしたが、**Vision 内部で落ちた**:
  `Assertion failed: ... "Algebra after the logarithm map does not require normalization."`
  `function enforce, file se3.hpp, line 270`
- 階段状(2m→7m)が原因かと思い**3回ボックスぼかしで滑らかに**しても同じアサート。
  原因はおそらく **`AVDepthData` に `cameraCalibrationData`(内部パラメータ)が無い**こと。
  実機の深度は必ず持っているが、`depthDataFromDictionaryRepresentation:` で自作したものには無い
- **これは実装上の地雷**: 将来 depth 入力を足すなら、**不正な AVDepthData で TD ごと落ちる**。
  `getCameraRelativePosition:` のクラッシュと合わせ、**Vision の3D姿勢APIはクラッシュ経路が複数ある**
- 合成では精度を測れないので、**深度で何が変わるかは未検証のまま**。分かっているのは:
  - ドキュメント上 `heightEstimation` が `measured` になり `bodyHeight` が実身長になる
    = **1.8m仮定が消えて絶対スケールが正しくなる**(Camera FOV と同じ種類の改善)
  - 姿勢そのものが良くなるかは**不明**。FOV実験で「幾何的なカメラ情報を与えても model空間の
    関節はビット一致」だったこと、固定プロポーションのモデルを角度だけ合わせていることから、
    **スケールと配置が主で、関節角度への効果は限定的**と推測されるが**実測していない**
- 実測するには iPhone のポートレート HEIC か深度付き動画が要る。`eval/` に置いてもらえれば検証可能

### 2026-08-10 demo に向き矢印を追加 + body:facing は横向きで180度反転すると判明

- ユーザー「body:facing pitch roll から向いている向きを矢印で描画して」
- `/project1/VisionPose3D/geo3`(arrow Script SOP → sop2pop → outPOP + arrowMAT マゼンタ)を追加。
  胸(center_shoulder)から出る**板ポリゴンの矢印**。facing=水平の向き / pitch=上下の傾き /
  **roll=板のバンク**。矢印の「向き」は2自由度しか持てないので、roll は板の傾きに割り当てた
- **実装より重要な発見**: 実機で矢印が**逆を向いた**。人物は明らかに左を向いているのに
  `facing=+89.6`。オフラインでは 左向き -90.2 / 右向き +90.7 と正しかったので符号規約は正しい。
  → **Vision の facing 推定が横向き付近で約180度反転している**
- **定量化**(10fps・隣接フレームの角度差で測定。人は 0.1秒で180度回れない):

  | クリップ | 90度超の飛び | 最大 |
  |---|---|---|
  | Tポーズ | 10/56 (**18%**) | 179.4° |
  | Model posing | 9/59 (**16%**) | 179.6° |
  | sample_pose3d | 10/57 (**18%**) | 152.9° |

  **約6フレームに1回、ほぼ180度**。真横のシルエットは前後でほぼ同形なので単眼では原理的に曖昧
- **矢印は値に忠実**で、プラグイン側で反転を隠す補正は入れていない(本当の挙動を見せるため)。
  演出で使うなら「飛んだら180度足して連続にする」後処理を入れる、と note と README に明記
- **教訓**: 見た目がおかしいとき、描画側を疑う前に**値と素材を突き合わせる**。今回は
  頭部を拡大して顔の向きを確認 → 値のほうが誤りと確定できた

### 2026-08-10 VNSequenceRequestHandler で安定性が大幅改善(ただし intrinsics と両立しない)

- ユーザー「Swift の Mac アプリとして実装しても同じ精度?」→ モデルは同じなので基本は同じ、
  ただし**入力の与え方**で差が出る。調べる過程で**プラグイン側の改善点が見つかった**
- **連続フレームとして渡すと劇的に安定する**(3クリップ・10fps・60フレームで実測):

  | | 検出率 | body:facing の180度反転 | 最大の飛び |
  |---|---|---|---|
  | 1枚ずつ `VNImageRequestHandler`(従来) | 56〜59/60 | 16〜18% | 179.6° |
  | **`VNSequenceRequestHandler`** | **60/60** | **0〜8%** | 69.8〜176° |

  単眼では真横の前後が原理的に曖昧なので、時間方向の文脈が効く。値の一致率は 3〜7% しかなく、
  **別物の結果**が返る
- **ただし intrinsics と両立しない**。実測で確定:

  | 経路 | 40度/90度を渡したときの復元値 |
  |---|---|
  | `VNImageRequestHandler` + `options:VNImageOptionCameraIntrinsics` | **40.000 / 90.000**(効く) |
  | `VNSequenceRequestHandler` + CMSampleBuffer attachment | 98.824 / 98.824(**無視**) |
  | `VNImageRequestHandler` + CMSampleBuffer attachment | 98.824 / 98.824(**無視**) |

  `VNSequenceRequestHandler` に `options:` 版は無い。**intrinsics を受け付けるのは
  VNImageRequestHandler の options だけ**
- **実装**: Camera FOV = 0 なら sequence(既定・安定重視)、> 0 なら image+intrinsics(距離重視)に
  自動で切り替える。TD実測で Fov=0→cam:fov 98.824/dist 2.20、Fov=50→50.000/4.99 を確認
- **Swift アプリとの比較の結論**: モデルもOSも同じなので**推定精度そのものは同じ**。差が出るのは
  ①深度を渡せるか(AVDepthData・TOPには無い)②intrinsics をライブ撮影から自動取得できるか
  ③入力画像がTDのチェーンで加工されていないか。**連続フレーム処理は今回プラグイン側にも入れた**ので
  この点の差は解消した

### 2026-08-10 顔の向きは VisionFace に既存。ただし ±45〜50度で頭打ち

- ユーザー「顔の向いている向きは取れない?」→ **VisionPose3D では取れない**(頭の関節が
  `center_head`/`top_head` の2点で同一直線上。その軸まわりの回転は原理的に表現されない)。
  **VisionFace CHOP が `face{i}/roll,yaw,pitch`(ラジアン)を既に出している**
- **実測(向きを目視で確認したフレームと突き合わせ)**:

  | 被写体 | face yaw | body:facing |
  |---|---|---|
  | 正面 | −4.2° | −5.8° |
  | 右へ90度 | **+48.0°** | +90.7° |
  | 右へ90度 | **+41.1°** | +89.4° |
  | 左へ90度 | **顔検出なし** | −90.2° |
  | 背面 | **顔検出なし** | +136.9° |

- **2つの限界**: ①`yaw` は **±45〜50度で頭打ち**。真横でも 90度にならないので「絶対方位」ではなく
  「頭のひねり具合」として扱う ②真横は当たり外れ、背面は何も返らない。**角度を使う前に顔側の
  valid で門番する**
- **組み合わせが本命**: `body:facing`(全周の体の向き)と `face yaw`(カメラに対する頭の向き)で、
  **「体は正対したまま顔だけ横」と「体ごと向きを変えた」を区別できる**
- なお **顔検出が失敗するのは真横〜背面**で、これは body:facing の180度反転が起きる領域と重なる。
  つまり**顔で反転を解消する用途には期待しすぎない**ほうがよい
- VisionFace/README(英日)に実測表と使い方の注意を追記

### 2026-08-10 v0.9.4 リリース

- ユーザー指示でリリース。**57プラグインを全て再ビルド**(並列・全件成功)してから
  `tools/release.sh sign → verify → dmg → notarize`。59バンドル・全数verify通過
  (署名/Hardened Runtime/Developer ID/APIバージョン/版一致)。DMG 18MB →
  公証 **Accepted**(c8be18e9-5dca-4f61-bed5-c39deed44464)→ staple → spctl accepted
- 0.9.3 からの中身は **VisionPose3D の全面的な見直し**が中心:
  連続フレーム処理(検出率 56〜59/60 → 60/60・向きの反転 16〜18% → 0〜8%)、
  リクエスト使い回しで約2倍速、`Coordinate Space`(root/camera)・`Camera FOV`・
  `body:facing/pitch/roll`・`cam:distance/fov` を追加、`bodyheight`/`heightestimation` と
  旧 `camera:*` 6ch を削除(**このopに関して後方非互換**)。
  ほかに Metal Denoise の警告+素通し化、**07-23 から黙ってビルドされていなかった6プラグインの修復**、
  READMEの英日併記化、評価ツール2本(`tools/pose3d_eval.m` / `tools/eval_video.sh`)、
  ループ探索(`tools/find_loop.py`)、VisionPose/3D の骨格線と向き矢印
- **patch にした理由**: `opType` の追加・削除・リネームは無く、影響は VisionPose3D の
  チャンネル構成のみ。op 単位の `majorVersion` も据え置き
- **申し送り**: demo.toe はユーザーが作業中の状態でコミットした。VisionPose3D コンテナに
  `eval/`(gitignore)の映像を参照する Movie File In が4本残っている可能性がある。
  clone しただけの人はその4ノードがファイル無しになる。次回整理する

### 2026-08-10 SoundClass のクラスID全一覧を README に収録(303件)

- ユーザー「SoundClass の Class 名一覧はどこにある?」→ **リポジトリには無かった**。
  Info DAT は「今鳴っている音の上位10件」しか出しておらず、全体を知る手段が無かった
- 正は API の `SNClassifySoundRequest.knownClassifications`。macOS 26.6 の
  `com.apple.SoundAnalysis.classifier.v1` で **303件**
- `tools/sound_classes.m` を追加(この一覧を吐くだけの小さなCLI)。**一覧は OS バージョンに
  紐づく**ので、README に貼ったのはスナップショットである旨を明記し、再生成手順も併記
- SoundClass/README(英日)に `<details>` で全303件を収録

### 2026-08-10 SoundClass デモに Info DAT が無く「上位10件が出ていない」ように見えていた

- ユーザー「infoDATが自動で上位10件を出している様には見えない。Classes に書いたものしか出ていない」
- **プラグインは正常。デモに Info DAT ノードが無かっただけ**。`/project1/SoundClass` にあったのは
  `chopto1`(CHOP to DAT)で、これは**チャンネル**=`Classes` に列挙したIDしか表にしない
- 一時的に Info DAT を繋いで確認すると、`Classes`(applause/cheering/laughter/music/speech)に
  無い **synthesizer 0.739 / keyboard_musical 0.725 / disc_scratching 0.285** 等がちゃんと出た。
  SDK も `classifications` は「sorted with highest confidence first」と保証しており、実装は
  先頭から `kRankRows = 10` 件を取るので確かに上位10件
- デモに **`top10`(Info DAT・Operator=Soundclass1)** を追加し、両方にノードコメントを付けた。
  note と README(英日)にも「Info DAT ノードのことであって CHOP to DAT とは別物」と明記
- **教訓**: 機能を実装しても**利用例に置いていないと存在しないのと同じ**。今回は
  「Classes を知らなくても探せる」という設計意図そのものが見えなくなっていた

### 2026-08-10 SoundClass CHOP に Info DAT 自動生成を追加(pythonCallbacksDAT の横展開)

- ユーザー「soundclass chop から infoDAT を出せる様にして」
- `common/PyCallbacksBootstrap.h` を使い、CoreWLANScan / Cinematic Video / Spatial Video / PDFKit と
  同じ仕組みを SoundClass CHOP へ横展開。**配置しただけで Callbacks DAT が閉じたチップとして
  ドック接続**され、**`Info DAT (top 10)` トグル off→on で `<node名>_info` を自動生成**
- build.sh に `TD_EXTRA_CFLAGS`(Python.h + `-undefined dynamic_lookup`)を追加。
  共通ヘルパは `TD_EXTRA_CFLAGS` を読むので1行足すだけで済む
- **検証で一度ハマった**: 生成直後は `sc_callbacks` も `sc_info` も出ず「効いていない」と見えたが、
  原因は**CHOP が cook されていなかった**だけ(bootstrap も callback 発火も execute の中にある)。
  `out.cook(force=True)` を数回回したら両方生成された。実測 sc_info 11x2、
  synthesizer 0.846 / keyboard_musical 0.781 / music 0.748、callbacks は
  dock=sc / expose=True / viewer=True / showDocked=False

### 2026-08-10 social preview 画像を作成(docs/social-preview.jpg)

- ユーザー「この動画を social preview にできない?」→ **動画は不可**。GitHub の social preview は
  **PNG / JPG / GIF・1MB未満**(推奨 1280×640)。しかも GIF にしても X は静止画にするので労力に見合わない
- **1MB制限が厳しい**のは尺ではなく「毎フレーム何割の画素が変わるか」。手元の GIF は
  llmafm-chat(16秒)が 648KB、visionface(4秒)が 1.5MB。1280×640 に上げると実写の動きものは無理
- 静止画で作成。素材は `AfterEffects/AppleFrameworksForTD_demos.mp4`(gitignore・24秒/1280x720)の
  **t=2.4s**(5人の骨格オーバーレイが一番読める)。1280×720 → 上80pxを落として 1280×640。
  下に指数 0.75 のグラデーションスクリムを敷いて可読性を確保し、Helvetica Bold 58 / Regular 32 で
  「Apple Frameworks for TouchDesigner」「50+ native operators · macOS」。**115KB**
- **social preview は API から設定できない**(Settings → General → Social preview の Web UI のみ)。
  画像は `docs/social-preview.jpg` に置いたのでユーザーがアップロードする
- あわせて調査した結果: リポジトリは **PUBLIC・星4・説明文あり**だが **Topics が空**。
  `touchdesigner` トピックには 426リポジトリあり、そこの導線から完全に外れている(要 Topics 設定)。
  awesome-touchdesigner(163★)への PR も有効

### 2026-08-10 SpeechText の Locale をプルダウン化(実行時に supportedLocales から生成)

- ユーザー「SpeechText の locale をプルダウンからの選択にしたい」
- **対応ロケールは OS のバージョンで変わる**ので静的メニューにせず、helper に
  `sp_locales()`(C ABI)を足して `SpeechTranscriber.supportedLocales` から実行時に取る。
  **macOS 26.6 実測で 30件**、うち **10件がこの Mac にインストール済み**
- ラベルは `en-US - English (United States) (installed)` の形。**インストール済みかを出す**のは、
  未インストールだと初回に数分のダウンロードが走るため(選ぶ前に分かるようにした)。
  **UIラベルは ASCII のみ**の規約があるので、英語名から非ASCIIを落としている
- **文字列パラメータ + `appendDynamicStringMenu` なので、一覧に無いコードも打ち込める**
  (実測: `sv-SE` を代入でき、値として保持された)。WhisperKit は99言語対応なので、
  30件のリストに縛られないこの挙動が要る
- macOS 26 未満で一覧が空になる場合に備え、en-US/ja-JP など7件のフォールバックを持たせた
- helper のキャッシュは初回だけ semaphore で待つ(5秒上限)。`supportedLocales` は静的な
  一覧なので実測では即返る

### 2026-08-10 Speech Text → Speech Transcribe に改名(破壊的変更)

- ユーザー「SpeechText という名前が機能をわかりづらくしている」→ 確かに紛らわしい。
  リポジトリには **Speech Synth(テキスト→音声)** があり、**Speech Text(音声→テキスト)** と
  並ぶと**どちらの向きか名前から読めない**
- ユーザー選択で **Speech Transcribe**(opType `Speechtranscribe` / icon `STR`)に。
  「フレームワーク名 + 機能」の規約に合い、Speech Synth と *transcribe / synth* の動詞ペアになる
- 手順は既存の改名と同じ: `git mv` でフォルダ・ソース → opType/opLabel/opIcon/クラス名/
  バンドル名を置換 → README(各 + ルート英日)・THIRD_PARTY_NOTICES・Translate/TextAnalyze の
  相互参照・skill 2ファイルを更新 → 旧バンドル削除 → 新バンドル設置
- **Swiftヘルパは内部名を保持**(module `SpeechHelper` / C ABI `sp_` / `libSpeechHelper`)。規約どおり
- **opType 変更は破壊的**なので、このopの `majorVersion` を 0→1(minor 9→0)に上げた
- **SPM の罠を再度踏んだ**: フォルダ移動で `whisper/.build` の ModuleCache パスがずれて
  `could not build module '_DarwinFoundation1'`。`rm -rf whisper/.build` してから再ビルドで解決
  (ImageGen で同じことを踏んでおり、CLAUDE.md にも既出)
- TD再起動後、demo の該当ノードは **`Speechtranscribe1` として型もパラメータも正常に復帰**し
  errors なし。コンテナ名も `SpeechTranscribe` に変更して保存

### 2026-08-10 デモ用の英語音声を追加(Assets/sample_speech_en.aiff)

- ユーザー「demo用に英語の音声ファイルがほしい」。`say -v Samantha` で生成(19秒・818KB・
  合成音声なので第三者の権利なし)。既存の日本語は `sample_speech.aiff` → **`sample_speech_ja.aiff`**
  に改名して対を明示
- **デモの既定を英語に変更**。`en-*` のモデルは多くの Mac に最初から入っているが `ja-JP` は
  初回にダウンロードが走るため、初見の体験がよい。`repeat=on` でループ再生
- **原稿を2回書き直した**: 最初の版は `on-device` が **`undevised`** に、`in TouchDesigner` が
  `and touch designer` に化けた(合成音声の発音と相性が悪い)。**素直な英文に書き換えたら
  誤りゼロ**になった。デモに載せる音声は、認識器が転ぶ語を避けたほうがよい
- **先頭に 0.8 秒の無音を足した**。無いと再生開始と同時に認識が始まるので **冒頭の "This is" を
  取りこぼす**。無音を入れたら拾えるようになった
- 検証の注意: `Clear` パルス直後や `reloadpulse` 直後は数秒空振りする。**audio CHOP の peak と
  Info DAT の status を見てから**表を読むこと(空を見て「動いていない」と誤診しかけた)

### 2026-08-10 SpeechSynth の Voice もプルダウン化(こちらはDL不要)

- ユーザー「SpeechSynth の VoiceIdentifier は何？これも選択式にできるならしたい」
  「locale を選ぶ必要はない?」「この音声モデルはダウンロードが必要?」
- `Voice` は `com.apple.voice.compact.en-US.Samantha` のような **AVSpeechSynthesisVoice の識別子**を
  手打ちする欄だった。`AVSpeechSynthesisVoice.speechVoices()` から実行時にプルダウンを組むよう変更。
  **この Mac で 180音声 / 49言語**。言語→名前でソートし `en-US  Samantha  (Default)` 形式のラベル
- **Locale パラメータは不要**(ユーザー質問への回答): 識別子が言語を内包している
  (`com.apple.voice.compact.ja-JP.Kyoko` は日本語)。認識と違い、合成は声を決めれば言語も決まる
- **ダウンロードも不要**(同): `speechVoices()` は**インストール済みのものしか返さない**ので、
  一覧に出ている時点で全部使える(3件を `voiceWithIdentifier` で実際にインスタンス化して確認)。
  **SpeechTranscribe の Locale とは逆の性質** — あちらは未インストールも並ぶので `(installed)` を
  付けている。この Mac は 180件すべて Default(compact)で、Enhanced/Premium は0件だった
  (欲しい場合はシステム設定 > アクセシビリティ > 読み上げコンテンツ > 声を管理 でDL。
  実行時に組み直すので自動で一覧に加わる)
- **罠**: 動的メニューは**空文字の既定値だとパラメータ自体が生成されない**(既出)。
  「空欄=既定音声」の挙動を保つため、`default` という番兵値を既定にして
  speak 側で「空 or default なら音声指定なし」と解釈するようにした
- demo の Voice が `Trinoids`(ネタ音声)だったので Samantha に変更。実際に発話して peak 0.36〜0.63 を確認

### 2026-08-10 Speech Synth: 未インストール音声のDLは不可と確定 → 設定への導線+自動再取得を追加

- ユーザー「Voice で未インストールも表示して、選択時にダウンロードする挙動は可能?」→ **SDKを実測して
  結論: ダウンロードの起動は不可能、列挙も公開APIでは不可能**
  - `AVSpeechSynthesisVoice` のクラスメソッドは **`speechVoices` / `currentLanguageCode` /
    `voiceWithLanguage` / `voiceWithIdentifier` の4つだけ**(ヘッダを全走査)。DL系は皆無
  - ヘッダのコメントに「`voiceWithIdentifier:` は識別子が正しくても**まだユーザーがDLしていない場合は
    nil**」と明記 = フレームワークは未DL音声の存在を認識しているが取得手段を出していない
  - `AVSpeechSynthesisProvider.h` にも download 系0件。`MobileAssetCLI` 相当のCLIも無い
  - **列挙だけなら抜け道はあるが採用しない**: `/System/Library/AssetsV2/
    com_apple_MobileAsset_VoiceServices_CombinedVocalizerVoices/*.xml`(43件)と
    `MacinTalkVoiceAssets`(22件)に Name/VoiceId/Languages/DLサイズが載っている。ただし
    **これは `/System/Volumes/Data` 上にあり assetd が更新するキャッシュ**(OS同梱ではない)で、
    識別子も `com.apple.ttsbundle.Allison` 形式で AV 側の `com.apple.voice.enhanced.*` と別体系。
    列挙できてもDLできない以上、選べない項目が並ぶだけなので見送った
- **実装した現実解**(SpeechSynth CHOP):
  - **`Open Voice Settings` パルス**: `x-apple.systempreferences:
    com.apple.Accessibility-Settings.extension?SpokenContent` を NSWorkspace で開く。
    **実測でシステム設定の「リーダーと読み上げ」に直行**(声を管理 がある画面)。
    旧アンカー `com.apple.preference.universalaccess?Speech` はアクセシビリティのトップ止まりだった
  - **`AVSpeechSynthesisAvailableVoicesDidChangeNotification` を監視**してメニューを自動再取得。
    DL後にTD再起動もノード作り直しも不要。手動用に **`Refresh Voice List`** パルスも用意
  - AppKit をリンク追加(NSWorkspace のため)
- **前回の「Enhanced 0件」は誤り。訂正**: 設定画面が「システムの声 = Kyoko(拡張)」と表示していたので
  測り直したところ **183音声・うち Enhanced 2件**(`com.apple.voice.enhanced.ja-JP.Kyoko` /
  `.Otoya`・quality=2)。Premium は0。**DL済み音声は speechVoices に自動で出る**ことの実証でもある
- ラベルの `(Enhanced)` 重複を修正(`v.name` が既に "Kyoko (Enhanced)" なので品質を足すと二重になる)
- **検証(TD再起動なし・バージョン付きパス方式)**: `Refreshvoices`/`Voicesettings` の両パルス生成、
  メニュー184件(System Default + 183)、Refresh後も184、TDからのパルスで設定が
  「リーダーと読み上げ」で開くことを確認。errors/warnings なし。検証ノードは削除済み
- **罠**: cplusplusCHOP のプラグインパラメータは **`customPars` / `isCustom` では取れない**(0件)。
  `n.pars('*')` で名前を見ること。これで一度「パラメータが生成されていない」と誤診した

### 2026-08-10 Speech Activity CHOP は動作しないと判明(SpeechDetector が結果を返さない)

- ユーザー「SpeechActivity の使い道を教えて」→ README に「実発話での onset/offset は未検証」と
  残っていたので、答える前に `Assets/sample_speech_en.aiff`(Speech Transcribe で誤りゼロだった
  19秒の英語ナレーション)で検証したところ、**このオペレータは全く動いていなかった**
- **TD実測**: Execute DAT の onFrameEnd で毎フレーム駆動して729フレーム観測し、
  `speaking` が一度も1にならない。22050Hz / 48000Hz、感度 medium / high の4通りとも0。
  Info DAT は `listening`、errors/warnings なし(=静かに死んでいる)
- **単体Swiftハーネスで原因を特定**:
  1. `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:[detector])` が
     **0 Hz / 0 ch** を返す(`availableCompatibleAudioFormats` もこの1件だけ)
  2. helper はこれを変換先にするので `AVAudioConverter` が **nil** → `feed()` が早期return
     → **音声が1サンプルも解析器へ届かない**
  3. `status="listening"` は `analyzer.start()` の**前**にセットしているので起動の証拠にならない
  4. detector 単体で `prepareToAnalyze` すると Apple自身の致命的エラー
     **"Cannot create SpeechDetector-only worker; use with a transcriber module"**
  5. `SpeechTranscriber` と組み合わせると format は 16kHz になり19秒投入できるが、
     **`detector.results` は0件**(同じ実行で transcriber は正しい認識結果を4件返すので音声経路は正常)
- **結論**: `SpeechDetector` はユーザー向けVADではなく transcriber の内部ゲート用モジュールとして
  振る舞う。macOS 26.6 では「単体VAD CHOP」という設計自体が成立しない
- **代替**: 発話ゲートは **Sound Class CHOP**(303クラスに `speech` がある)を閾値処理する。
  レベルだけでよければ SoundFeatures の RMS(ただし物音でも立つ)。字幕の区切りは
  Speech Transcribe が無音で確定行に落とす仕組みを既に持っている
- README(SpeechActivity 英日 + ルート英日一覧)を実測に合わせて訂正。**develop へ退避するかは
  ユーザー判断待ち**(公開は検証済みのみ、という方針からは退避が筋)
- **教訓**: 「実測」と書く対象を間違えていた。正弦波で `speaking=0` を確認して「非音声として正しい」
  と読んでいたが、**実際は入力が何であれ0**だった。**陰性の確認は、陽性が出ることを先に示してから**
- **教訓**: 状態文字列は**処理が実際に始まってから**立てる。開始前に立てると、失敗しても
  「動いているように見える」表示が残る

### 2026-08-10 Speech Activity CHOP を develop へ退避(動作しないため)

- 直前の調査で「`SpeechDetector` は結果を返さず、単体VADという設計自体が現行APIで成立しない」と
  確定したため、ユーザー判断で main から外した。「公開は検証済みのみ」の方針どおり
- 手順は従来どおり: worktree で develop をチェックアウト → `git checkout main -- SpeechActivity`
  で **先に develop を main の最新(診断入りREADME)へ同期**(56ad1c0)→ main で `git rm -r`。
  **main→develop の wholesale merge は厳禁**(main の削除コミットが伝播する)
- ルートREADME(英日)の該当行を削除。**公開は 56フォルダ / 58オペレータ**
  (Multipeer と PDFKit/Cinematic 等で1フォルダ複数バンドルがあるため数が一致しない)
- **skill 側の参照も付け替えた**(退避すると死んだポインタになるため):
  SKILL.md の「Swiftヘルパが要る → `SpeechActivity/`」→ **`VisionDocument/`**(swiftc直の単一
  ヘルパ + epoch名dylib で、スキルが推奨する形そのもの)、build.md の手書きbuild.sh骨格も
  VisionDocument ベースに差し替え、naming.md の opLabel 例は `Speech Transcribe` に
- ローカルの常設Pluginsには SpeechActivityCHOP.plugin を残置(開発環境は不変・従来と同じ扱い)
- demo.toe の利用例削除はユーザーが実施

### 2026-08-10 Cinematic Video TOP を Movie File In 相当の自動再生に + Info DAT → Info CHOP

- ユーザー「CinematicVideo を MovieFileIn の様に自動で再生可能な仕様にしたい」。従来は
  `Position`(0..1)を外から動かさないと止まったままだった
- **`OP_Inputs::getTimeInfo()->deltaMS` でタイムライン駆動**にした(Movie File In と同じ考え方。
  TDのタイムラインを止めれば再生も止まる)。追加パラメータ: `Play`(既定On)/ `Speed`(負値で逆再生)/
  `Loop`(既定On)/ `Cue` / `Cue Point` / `Cue Pulse`。`Position` は **Play が Off のときだけ**
  効く手動スクラブ(Movie File In の Index と同じ役割)に。Info CHOP へ `position`(秒)と
  `playing` を追加(kFixedChans 8→10)
- **要求時刻はソースのfpsでフレーム量子化**する。しないと同じ絵を何度もデコードし直す
- **実測(M2・実Cinematic動画 57.1秒)**: Depth 512x288 で **実時間の 0.98倍・59描画/秒**、
  Speed=0.5 → 0.50x、Speed=-1 → -1.00x(逆再生)、Rendered 1920x1080 でも **1.00x・59.8描画/秒**。
  Loop On=先頭へ折り返し / Off=終端で停止、Cue On=キュー点で保持、Cue Pulse=ジャンプ、
  Play Off + Position=0.5 → 28.55秒(=dur×0.5)を全て確認
- **ユーザー指摘「infoDATよりinfoCHOPの方が良いのでは」→ そのとおりだった**: このOPには
  **`getInfoDATSize` の実装がそもそも無く**、出しているデータは全て数値。`Info DAT` トグルは
  中身の無いDATを作るだけだった(demo.toe にも自動生成された空の `_info`(infoDAT)と、
  ユーザーが手で置いた `info1`(infoCHOP)が並んでいた)。トグルを **`Info CHOP`** に変更し、
  stub も `onInfoCHOP` → `p.create(infoCHOP, ...)` に。**PDFKit(本文/アウトライン)と
  Spatial Video(codec/hero_eye 等の文字列)は DAT のままが正しい**
- **検証の制約**: `pythonCallbacksDAT` は **Plugin Path で読ませた素の cplusplusTOP では効かない**
  (`callbacks` パラメータ自体が生成されない)ため、バージョン付きパス方式では bootstrap を検証
  できない。stub 関数を取り出して直接実行し、`_info` が **infoCHOP** として生成され op が
  自ノードを指し二重生成もしないことを確認した。トグル経由の一連の流れは**TD再起動後に要確認**
- **罠(再確認)**: TD内Pythonで `time.sleep` を呼ぶと **TD本体が止まる**ので、再生の経過を測る
  ときはシェル側で待つ。これで一度「Loopが折り返さない」と誤診した
- 常設インストール済み。**TD再起動で `Play` 等の新パラメータと `Info CHOP` トグルが出る**。
  demo.toe に残っている `Cinematicvideo1_info`(infoDAT)は用済みになる(ユーザー側で整理)

### 2026-08-10 Cinematic Video に Both モード(色+深度を2色バッファ同時出力)

- ユーザー「同じ動画ファイルから color と depth を同時に出したい」
- **C++ TOP は複数の色バッファへ出せる**(SDK の `TOP_UploadInfo::colorBufferIndex`。
  ヘッダに「**色バッファごとに解像度もピクセル形式も別でよい**」「0以降は Render Select TOP で取る」
  と明記)。これを使い `Mode = Both` を追加: **バッファ0=Rendered(RGBA16Float) / バッファ1=Depth
  (Mono32Float)**。同じジョブから両方を出すので**構造上フレームがずれない**
- 実装: アップロードを `uploadPlane(out, depth, bufIndex)` に切り出し、Both は2回呼ぶ。
  worker は `if(mode!=1) cn_depth; if(mode!=0) cn_render;`
- **実測(M2・実素材)**: 色 1920x1080 RGBA16F + 深度 512x288 Mono32F を**同時取得**、
  **実時間1.00倍・60組/秒**。両バッファの絵が同一フレーム(キッチンの色と対応する視差)であることを視認
- **重要な使い方の罠**: **Render Select TOP は参照で読むので、参照元の cook を引っ張らない**。
  下流が Render Select だけだと参照元がほとんど cook されず再生が這う
  (実測: Render Select 4408 cook に対し参照元 29 cook)。**バッファ0はワイヤで下流に繋ぐ**
  (Null TOP で十分)。READMEに明記
- **検証中に TD がクラッシュ**(EXC_BAD_ACCESS)。**クラッシュスタックに自作プラグインのフレームは
  1つも無く**、Python からのパラメータ設定 → libOP → libPRM → libC_TOP → libUT で落ちていた。
  状況(常設の旧ビルド=Mode 2項目 と 一時パスの新ビルド=3項目 が**同じ opType `Cinematic` で
  同時にロード**されており、そこへ `Mode='Both'` を設定した)から、**古いメニュー定義に無い値を
  入れたのが原因**と考えられる。新ビルドを常設へ入れ、一時パスのコピーを消して TD を再起動したら
  同じ操作でクラッシュせず動いた
- **教訓**: バージョン付きパス方式は「パラメータの追加」までは安全だが、**メニュー項目の増減など
  定義そのものが変わる変更には使えない**(同じ opType の定義が2つ同時に存在するため)。
  そういう変更は常設インストール+TD再起動で検証する
- TD再起動時に「New Plugin Detected」ダイアログが出るので computer-use で承認して起動を完了させた。
  クラッシュ時の `CrashAutoSave.demo.toe`(17:24)がリポジトリ直下に残っている(demo.toe 本体は無事)

### 2026-08-10 Cinematic Video: 再生中のメモリ暴走を修正(TDが固まる)+ Play Mode 追加

- ユーザー報告「再生していると動画が止まる」→「TDがメモリを極端に使って固まったので強制終了した」
  →「ループ再生でまた固まった」。**自動再生化(前エントリ)で初めて毎秒数十回デコードするように
  なり、元からあった資源リークが表面化した**。自分が入れた退行なので最優先で修正
- **原因3つ(単体ハーネス `scratchpad/mem.c` で RSS を測って特定。TDを巻き込まずに測れる)**:
  1. **`AVAssetReader` を毎回作って `cancelReading()` せずに捨てていた**。`startReading()` した
     readerはデコードパイプラインを抱えたままで、毎秒数十本作ると解放が追いつかない。
     **変換が終わってから** `defer { frames.reader.cancelReading() }` で解放(変換**前**に
     cancel すると読み出したバッファが無効になるので順序が重要)
  2. **再レンダ先の `CVPixelBuffer`(IOSurface付き)を毎フレーム新規作成**していた →
     `CNState` に持って使い回す
  3. **ワーカースレッドに autorelease プールが無い**。AVFoundation/CoreVideo の autorelease
     オブジェクトが永久に溜まる。**これが最大**で、helper の `cn_render`/`cn_depth`/`cn_meta` を
     `autoreleasepool { }` で包み、C++ 側 worker のジョブ1件ごとにも `@autoreleasepool` を入れた
- **実測**: 単体ハーネス 修正前 400回で RSS 23→324MB(増加中) / 修正後 **1000回で 93MB 横ばい**。
  TD実機で Speed=8 のループ再生を2分(5451フレーム描画)して **RSS 1575MB のまま完全に横ばい**
- **Play Mode 追加**(Movie File In と同じ3種): `Sequential`(既定・自前の時計)/
  `Locked to Timeline`(タイムライン秒×Speed+Cue Point。スクラブに追従しフレーム単位で再現するので
  書き出し向き)/ `Specify Index`(Position のみ)。実測: Locked でタイムライン 2.00/5.00/9.00秒 →
  position 2.02/5.02/9.02秒、Specify で Position 0.25/0.75 → 14.28/42.83秒(=尺×比)
- **教訓**: **常駐ワーカースレッドから ObjC/Swift のフレームワークを叩くなら autorelease プールを
  必ず張る**。1回あたりは小さくても、毎フレーム呼ぶ設計にした瞬間に破綻する。
  「今まで動いていたコード」でも、**呼ぶ頻度を上げる変更は資源管理の前提を壊す**
- **教訓**: メモリの増え方は **TD の外の小さなハーネスで測る**のが速くて安全(TDを固めずに済む)。
  `mach_task_basic_info` の resident_size を数十回ごとに出すだけでよい

### 2026-08-10 Cinematic Video に Color モード + Both を廃して All(3枚同時)へ

- ユーザー「出力できる映像は rendered と depth 以外に color は無い?」→ **素材の映像トラック
  (ボケを付ける前の原版)は読んでいたが、再レンダの入力に使うだけで出す口が無かった**。
  `cn_color` を追加して出せるようにした
- 続けてユーザー提案「color+depth / rendered+depth ではなく3つ同時に出す機能にしては」→
  **Both(2バッファ)を廃止し `Mode = All` に一本化**。`0=Rendered / 1=Color / 2=Depth` の3色バッファ。
  Mode は **Depth / Rendered / Color / All** の4つになった
- **All はファイル読みを1回節約している**: `cn_render` に `keepColor` を足し、**再レンダが既に
  デコードした映像トラックからそのまま色を取り出す**(別途 readFrames しない)。
  実測でも All が Rendered と同じ 60フレーム/秒
- **Color の正しさを数値で確認**: `Aperture` f/16 の再レンダ結果と**サンプル領域で完全一致
  (平均絶対差 0.00)**、f/2 では背景の高周波エネルギーが 365→282 に落ちる(=ボケている)。
  つまり Color はボケを付ける前の原版で正しい
- 色の回転は render(CNRenderingSession が preferredTransform を適用)と揃えるため
  `rotateRGBA16` で自前に掛ける。深度と同じ「回転→上下反転」の順
- **実測(M2・実素材)**: All で buffer0 1920x1080 RGBA16F / buffer1 1920x1080 RGBA16F /
  buffer2 512x288 Mono32F を同時取得、**全モード60フレーム/秒**、3枚とも同一フレーム(視認)
- **踏んだ罠(2回)**: 非同期ワーカーの完了を待たずに `.save()` すると**1つ前のモードの絵が保存される**。
  実際に「color と f/2 が完全一致(差0.02)」という誤った結果を得て誤診しかけた。
  モードやパラメータを変えたら**シェル側で数秒待ってから**保存する(TD内 `time.sleep` はTDが止まる)

### 2026-08-10 VisionPose3D に深度を渡す件の結論(Cinematic の深度は使えない・TDが落ちる)

- ユーザー「VisionPose3D の input に Cinematic Video で撮影した depth を入れて精度を上げられないか?」
  → 以前「深度素材が用意できたら相談」としていた宿題。**実測して不可と確定**
- **単体ハーネス(`scratchpad/p3d.swift`)で検証**(Vision が落ちる可能性があるので必ず別プロセスで):
  Cinematic 動画から color(1920x1080)と disparity(512x288)をデコードし、
  `AVDepthData(fromDictionaryRepresentation:)` で深度を組んで `VNDetectHumanBodyPose3DRequest` に渡した
- **結果**:
  - AVDepthData の**生成自体は成功**する(以前の合成データ特有の問題ではなかった)。ただし
    `cameraCalibrationData = nil`
  - 深度**なし**なら検出できる(orientation は down/left/right。up は検出0=向きの問題)
  - 深度**あり**で **`se3.hpp:270` のアサーションでプロセスごと即死**。以前 synthetic depth で
    踏んだのと**同じクラッシュ**で、原因は合成かどうかではなく**較正情報の欠落**だった
- **回避不能な理由(SDKで確認)**: `AVCameraCalibrationData` に**イニシャライザが存在しない**
  (ヘッダにインスタンスメソッド1つのみ)。`replacingDepthDataMap(with:)` も Apple自身が
  「返るオブジェクトの cameraCalibrationData は**常に nil**」と明記。=**自作の深度マップに較正を
  付ける公開手段が無い**。較正が残るのは撮影経路そのままの深度だけ
  (ポートレートHEICの `CGImageSourceCopyAuxiliaryDataInfoAtIndex` / `AVCaptureDepthDataOutput`)
- **Cinematic 固有の追加の壁**: Cinematic フレームワークに較正/内部パラメータのAPIが無い
  (`calibration|intrinsic|focal|baseline` で swiftinterface を走査して0件)。視差もメートルでなく相対値
- **設計上の壁**: TOP は色しか運ばないので、そもそも深度用の入力経路が別途要る
- **危険度が高いので README(英日)に明記**した。「エラーになる」ではなく**TD本体が落ちる**ので、
  安易に試させないことが重要
- 将来やるなら: iPhone ポートレート HEIC(較正付き)を **ファイルパスで**受ける専用経路。
  ただし静止画なので用途は狭い。ライブ深度は Mac に深度カメラが無いので対象外

### 2026-08-10 CI RAW の出力が壊れていたのを実RAWで発見・修正 + 4件の利用例を追加

- ユーザーが実素材を追加: `Assets/sample_heic/IMG_3095.HEIC`(iPhone・**較正付き視差**+
  **HDRゲインマップ**)と `Assets/sample_raw.DNG`(iPhone 17 Pro の Apple ProRAW・8064x6048・**52.9MB**)。
  これで CI RAW / CI HDR の「実素材未入手で未検証」が解消できるようになった
- **CI RAW の実バグを発見**: `[CIContext render:... format:kCIFormatRGBA16 ...]`
  (**16bit符号なし整数**)で描いた結果を、TOPへは `RGBA16Float`(**半精度浮動小数**)として
  アップロードしていた。ビット列が別物として解釈され、実RAWで **NaN / -4696.0** のような値になり
  画面は真っ白。**`kCIFormatRGBAh` に修正**して正常な現像結果を視認確認
  - **非RAWのJPEG等では気づきにくく、実RAWを入れて初めて露見した**。READMEに「実RAW視覚検証は未実施」と
    書いてあった箇所がまさにそれ
  - 横断監査: `kCIFormat` を使う3件のうち **CoreImageHDR は正しい**
    (RGBAf で描いてから明示的に float32→float16 変換している)。CoreImageCode も BGRA8→BGRA8Fixed で一致。
    壊れていたのは CI RAW だけ
- **利用例4件を demo.toe に追加**(ユーザー要望): CIRAW / CIHDR(y=-1400 描画の行)、
  CoreWLAN / CoreWLANScan(y=-2400 その他の行)。既存の型どおり `<Optype>1` + note + out1
  - **CI RAW**: Scale=0.25(2016x1512)。Scale=1.0 のフル現像は初回約10秒
  - **CI HDR**: HDR / Gain Map / SDR の3ノードを並べた。実測 4032x3024・2016x1512・RGBA16Float
  - **CoreWLAN**: 9ch(rssi -50 / snr 43 / channel 104)+ Info DAT。SSID/BSSID は位置情報許可が要り空欄
  - **CoreWLAN Scan**: 126ch・39ネットワーク検出・best_ch_24=14 / best_ch_5=64。
    配置しただけで Callbacks DAT が自動ドックされることも確認
- **素材はまだコミットしていない(ユーザー判断待ち)**。理由は下記の privacy/容量:
  - **DNG に写り込んだノートPC画面が全部読める**。表示されていたのは作業中の会話と、
    サイドバーの**他案件名**(業務情報)。1/4解像度でも判読可能で、実ファイルはその4倍精細
  - **GPS が両方に入っている**(HEIC 35.3381467,139.4899300 / DNG 35.3381783,139.490005)。
    撮影日時も入る
  - **DNG 52.9MB**(現在の Assets 合計 85.4MB に対して大きい)。git履歴は消せないので慎重に
- demo.toe も未コミット(素材の扱いが決まってから)

### 2026-08-10 CoreWLAN Scan の SSID が取れない件 → 原因3つ + 配布物のGatekeeper問題を修正

- ユーザー「Corewlanscan ssid一覧が取れない」→ **プラグインの不具合ではなく位置情報の許可が切れていた**。
  ただし調べる過程で**配布に関わる実害のある問題**が2つ出てきた
- **原因1(直接原因)**: システム設定 > プライバシーとセキュリティ > 位置情報サービス の
  `wifiscan-helper.app` が **OFF** になっていた(8/7 に許可した後に切れた)。オンにしたら
  **69ネットワーク**取得、demo の `_ssid` Info DAT にも **46件**表示された
- **原因2(LaunchServices のゴースト)**: `open` が **-1712** で失敗していた。
  `lsregister -dump` を見ると、bundle id `tokyo.sygnal.wifiscan-helper` が
  **既にアンマウントされた `/Volumes/Apple Frameworks for TouchDesigner v0.9.0` 上のパス**に
  紐づいたままだった(リリースDMGを一度マウントしたため)。`lsregister -f <helper.app>` で実パスを
  再登録し、DMG由来の `com.apple.quarantine` も外して解消
- **原因3(プラグイン側の実装不備・修正済み)**: ヘルパーは `{"status":"timeout"|"denied"|...}` を
  返しているのに、**CHOP がその status を完全に無視**して空の表を出すだけだった。だから理由が
  分からず詰まった。status を読んで**警告に直し方を出す**ようにした
  (「位置情報サービスで wifiscan-helper をオンに。混雑度は許可なしで動く」)
- **配布物の問題(重要・release.sh を修正)**: ユーザー質問「他の人もインストールしただけで取れる?」を
  実測で検証した結果、**取れない**:
  - DMG にはチケットが貼られているが、**取り出した .plugin にはチケットが無い**
    (`stapler validate` → "does not have a ticket stapled to it")
  - quarantine 付きのコピーから入れ子のヘルパーを起動すると、**「マルウェアが含まれていないことを
    検証できませんでした」でブロック**され、プロセスが起動しない(実際にダイアログを再現)
  - **`xcrun stapler staple` は .plugin にも貼れる**ことを確認 → `tools/release.sh` の notarize を
    「①dist の全pluginをzipで公証してバンドル個別にステープル ②その状態でDMGを作り直す
    ③DMGを公証・ステープル」に変更した
  - なお**チケットを貼っても「インストールしただけ」では不十分**で、位置情報の許可は必ず一度
    ユーザーが出す必要がある(OSがユーザーに尋ねる仕組みなのでアプリ側からは決められない)
- **自分のミス**: 検証で `/tmp` のコピーに quarantine を付けて起動したところ、ユーザーの画面に
  Gatekeeper のブロックダイアログを出してしまった。テストコピーは削除済み・実インストールは無傷
- **開発時の注意**: 常設Pluginsへ `codesign -f -s - --deep` で入れ直すと **Developer ID 署名が壊れる**。
  そのため開発機の状態はリリース版と Gatekeeper 的に別物になる。配布の検証は必ず**DMGの中身**で行う
- README(CoreWLANScan 英日)に「SSID一覧が空のままのとき」の症状別表と Gatekeeper の説明を追加

### 2026-08-10 Cinematic Video に Color + Depth モードを追加(All が重い件の実測含む)

- ユーザー「All だと fps が落ちる。color と depth だけの選択肢も欲しい」
- **`Color + Depth`(2色バッファ: 0=色 / 1=深度)を追加**。`cn_render`(Metal 再レンダ)を通さず
  `cn_color` だけを使うので All より軽い。Mode は **Depth / Rendered / Color / Color+Depth / All**
- **文字列メニュー(`OP_StringParameter`+`appendMenu`)は .toe に「値の文字列」が保存される**ので、
  途中に項目を挿しても既存の .toe は壊れない(インデックスではないため)。今回 All の前に挿入した
- **実測(M2)で分かったこと**:
  - 1920×1080 ではどのモードも 60 フレーム/秒。**差が出るのは 4K から**
  - 3840×2160(demo の `Assets/sample_cinematic.MOV`)での生成フレーム数/秒:
    Depth 59.9 / Color 49.2 / **Color+Depth 46.7** / Rendered 44.8 / **All 41.7**
  - ただし**この素材は 23.976fps**なので、All の 41.7 でも 1倍速再生には十分足りている。
    数字が効くのは速いスクラブや `Speed`>1 のとき
  - **TD 自体の実fps はどのモードでも 59.8〜60.0 で落ちなかった**(検証チェーン上では)。
    デコードはワーカースレッドなので cook は 0.4〜9.5ms と軽い
  - → **`All` で fps が落ちるのは下流の負荷**と考えられる。All は 3840×2160 の RGBA16Float を
    2枚渡すので、ビューア / Layout / Composite TOP に載せるとそれだけで重い。
    Color+Depth で半減、ノード直後の Resolution TOP が最も効く、と README に明記
- README(各+ルート英日)更新。検証ノードは削除済み

### 2026-08-10 Cinematic Video: バッファ番号を統一 + Info DAT で素材メタデータ

- ユーザー「Color+Depth と All でバッファ番号が変わるので揃えたい。0=color 1=depth 2=rendered では?」
  → そのとおりなので統一。**Color+Depth が All の先頭2枚と同じ並び**になり、モードを切り替えても
  下流の Render Select を振り直さなくてよくなった
  - 副作用: **All のバッファ0(ノード自身の出力)が再レンダ→原版の色に変わる**。再レンダをワイヤで
    受けたい場合は Render Select で 2 を取る
  - demo の `renderselect_color`/`renderselect_depth` は既に 0/1 だったので、**今回の変更で
    名前と中身が一致した**(従来は名前と逆のものが出ていた)
- **Info DAT を追加**(`cn_fileinfo`): ファイルが自分について持っている情報を key/value で。
  実測20行 — duration / rotation / is_cinematic / cinematic_intent / video_size(3840x2160) /
  video_codec(hvc1) / video_fps(23.990) / video_mbps(20.4) / disparity_size(512x288) /
  disparity_codec(dish) / audio_codec / make(Apple) / model(iPhone 17 Pro) / software(26.6) /
  creationDate / **location(GPS)**。cn_open 時に1回だけ作るので毎フレームの負荷は無い
  - GPS が入る点は README と demo の note に注意書きを入れた
- **踏んだ罠2つ(共通ヘッダを修正)**:
  1. **stub は Callbacks DAT を作るときにしか書かれない**。既に自動生成済みのノードには
     後から増えたコールバック(`onInfoDAT`)が入らず、トグルを押しても何も起きない。
     → `bootstrapCallbacksDAT` に「自動生成した名前の DAT に限り、**不足している def だけ追記**」を追加
  2. **`par.callbacks.eval()` は文字列ではなく DAT オブジェクトを返す**(実測)。
     `== n.name + '_callbacks'` の比較が常に False で、上の追記処理が動かなかった。
     `.name` で比較する
- 実測: 再起動後の初回cookで callbacks に `onInfoDAT` が追記され、Infodat=On で
  `Cinematicvideo1_meta`(20x2)が生成された

### 2026-08-10 Info DAT の Callbacks stub が壊れていた(script error)

- ユーザー「scriptError が出てる」→ 自動生成された Callbacks DAT の `onInfoDAT` が
  **`d` で作ったのに末尾で `c` を参照**しており NameError になっていた
- 原因: stub へ `onInfoDAT` を挿入した位置が悪く、**`onInfoCHOP` の末尾3行
  (`c.nodeX` / `c.nodeY` / `c.viewer`)が `onInfoDAT` の中に移ってしまった**。
  構文エラーにはならないので、コンパイルチェックだけでは見つからない
- 修正: 各関数が自分の変数の末尾処理を持つように stub を直した。
  **検証方法も追加**: .mm の stub 文字列を復元して `compile()` に通し、
  さらに関数ごとに「代入した変数」と「参照した変数」を突き合わせる
  (未定義参照を機械的に検出できる)
- 既に生成済みの壊れた DAT は追記ロジックでは直らない(`onInfoDAT` は既に存在するため)。
  **自動生成された `_callbacks` DAT を消せば次のcookで作り直される**
- 教訓: 文字列連結で作る stub は**挿入位置を間違えても構文は通る**。
  生成結果を実際に compile し、変数の定義/参照まで確認すること
