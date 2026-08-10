---
name: td-apple-plugin
description: TouchDesignerのネイティブカスタムOP(.plugin)としてAppleのオンデバイスフレームワーク(Vision / Core ML / Core Image / VideoToolbox / MetalFX / SpeechAnalyzer / SoundAnalysis / NaturalLanguage / FoundationModels / ScreenCaptureKit / RealityKit / MultipeerConnectivity 等)をmacOSでラップするプラグインを新規作成・改修するときに使う。ObjC++本体、Swiftヘルパdylib、ビルド/署名/インストール、非同期ワーカーの実装の型、実際に踏んだハマりどころ、TD MCPでの実データ検証までを網羅。
---

# TouchDesigner × Apple フレームワーク プラグイン開発

macOS / Apple Silicon のオンデバイスML/メディアAPIを、TouchDesigner の
**ネイティブカスタムOP(.plugin)** として提供するための実践ガイド。
このスキルの内容は**全て実機で踏んだ知見**。同じ穴に落ちないこと。

> このリポジトリ(TDAppleOps)には約50個の実装済みプラグインがある。**新規実装や改修の前に、
> 近い family(CHOP/TOP/DAT/SOP)・近いフレームワークの既存プラグインを1つ読む**のが最短。
> 例: 新しいVision CHOP → `VisionPose/`、新しいCore Image TOP → `CoreImageBokeh/`、
> Swiftヘルパが要る → `VisionDocument/`(swiftc直) か `CoreMLImageGen/`(SPM依存)。

## トピック別リファレンス

- [architecture.md](architecture.md) — 全プラグイン共通の実装の型(非同期ワーカー、cook非ブロック、
  TOPのdownload/flip、Info CHOP診断、複数検出スロット出力)
- [build.md](build.md) — ビルド・署名・インストール、`common/build_plugin.sh`、Swiftヘルパdylib方式、
  SPM依存、dylibキャッシュ対策
- [pitfalls.md](pitfalls.md) — フレームワーク別ハマりどころ集(TD本体・Vision・VideoToolbox/MetalFX・
  音声/言語・SOP・git)
- [verification.md](verification.md) — TouchDesigner MCP での実データ検証の作法
- [naming.md](naming.md) — opType/opLabel/opIcon/パラメータの命名規約(TD起動時の検証で弾かれる罠)

## 新規プラグイン作成の標準フロー

1. **既存の近縁プラグインを1つ読む**(family + フレームワークが近いもの)。ディレクトリ構成・
   build.sh・`.mm` の骨格をそのまま踏襲する
2. **フォルダを作る**: `<FrameworkPrefix><Feature>/`(例 `VisionContours/`・`CoreImageBokeh/`・
   `MetalUpscale/`)。中に `<Name><Family>.mm`・`build.sh`・`README.md`。Swift専用APIなら Swift ソースも
3. **命名を決める**([naming.md](naming.md)): opType(先頭大文字+以降小文字数字のみ)・
   opLabel(`Framework Feature` 形式)・opIcon(**英字のみ3文字**、数字禁止)
4. **実装する**([architecture.md](architecture.md)): 推論はワーカースレッド、cookは絶対ブロックしない、
   Info CHOP診断を必ず出す、TOPのdownload flipは Vision/ML意味処理系のみ
5. **ビルド・署名**([build.md](build.md)): `./build.sh` 一発で `build/<Name>.plugin` + ad-hoc署名まで
6. **TD MCPで実データ検証**([verification.md](verification.md)): ロード・パラメータ生成・エラーなし +
   TOPは `render`(旧get_top_image)で視認、CHOPは値、DATはテーブル内容。**実測値(fps/ms/解像度)を取る**
7. **常設インストール**: `~/Library/Application Support/Derivative/TouchDesigner099/Plugins/` へコピー
   → **TD再起動**で OP Create Dialog に登録
8. **ドキュメント**: そのプラグインの `README.md` + ルート `README.md` の一覧表を更新
9. **CLAUDE.md の作業ログに追記**(何を・なぜ・検証結果・次にやること)。新しく踏んだ罠は
   pitfalls.md にも反映

## 絶対に外さない3原則

- **cook(execute)をブロックするな**。重い推論・`getData()`・GPU完了待ちは全てワーカースレッドへ。
  結果は1〜2フレーム遅れで最新値を出す
- **Info CHOP診断を必ず出す**(`executes / submits / analyzes` 等)。`analyzes` が `executes` に
  追従していればフレーム落ちなし、という読み方ができる
- **リビルドしても古いコードが動くことがある**(TDが同一パスの.pluginと依存dylibをプロセス内で
  キャッシュ)。確実な反映はTD再起動。dylibは epoch 付き名でキャッシュを回避する([build.md](build.md))
