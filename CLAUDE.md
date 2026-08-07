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
