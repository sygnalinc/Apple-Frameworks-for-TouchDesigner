# CLAUDE.md — TDAppleML 開発ガイド(AIエージェント向け)

このリポジトリで作業するAI/開発者が守るべきルールと、実装済みプラグインで得た知見の集約。
**ここに書かれたハマりどころは全て実際に踏んだもの**。同じ穴に落ちないこと。

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
