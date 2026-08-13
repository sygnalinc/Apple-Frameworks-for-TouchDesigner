# ビルド・署名・インストール

## 前提

- Xcode(`clang++` / `swiftc`)+ TouchDesigner.app(C++ SDKヘッダを流用)
- SDKヘッダ: `/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/`
  配下の `CHOP/` / `CPUMemoryTOP/`(TOP用) / `DAT/` / `SOP/`
- 各プラグインは `./build.sh` 一発で `build/<Name>.plugin` を作り **ad-hoc署名**(`codesign -s -`)まで行う

## 単純なObjC++単体プラグイン → 共通ヘルパを使う

`common/build_plugin.sh` が bundle 組み立て・Info.plist・署名を共通化している。
プラグインの `build.sh` はこれだけ:

```zsh
#!/bin/zsh
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
source ../common/build_plugin.sh
build_td_plugin CoreImageBokehTOP coreimagebokeh-top CoreImageBokehTOP.mm -- CoreImage CoreGraphics
```

- 第1引数 = `<Name><Family>`(bundle名・実行バイナリ名)、第2 = bundle-id suffix、
  以降 `--` まで = ソース、`--` の後 = 追加フレームワーク(Foundationは自動付与)
- `TD_SDK` で family のヘッダを切替(CHOP/TOP/DAT/SOP)。**TOPは `CPUMemoryTOP`**
- ヘルパは毎回 `rm -rf build` する。**1つのbuild.shから複数バンドルを作るときは使えない**
  (その場合は手動で `build_one` 相当を2回。例 Multipeer In/Out)

## Swift専用APIのラップ(ヘルパdylib方式)

ObjC++から呼べないSwift専用APIは、helperを dylib 化して C ABI で繋ぐ。共通ヘルパは使わず手書き。

- **Cプレフィックスをプラグインごとに分ける**: `sd_`/`pg_`(ImageGen)・`fm_`(FoundationModel)・
  `tr_`(Translate)・`sp_`(SpeechTranscribe)・`wk_`(WhisperKit)・`sh_`(Shazam)・`ph_`(Photogrammetry)
- helperは `@_cdecl` でエクスポート、ハンドルは `Unmanaged.passRetained().toOpaque()`
- 状態受け渡しは **poll方式のJSON**(status/busy/…)+ 必要ならバイト列コピー関数
- 依存が単純なら `swiftc -emit-library` 直、SPM依存(ml-stable-diffusion/WhisperKit)なら
  helper/ を Swift Package にして `swift build -c release`
- dylibは `.plugin/Contents/Frameworks/` に同梱し、リンク時 `-rpath @loader_path/../Frameworks`

手書きbuild.shの骨格(VisionDocument 参照。dylib名は下記のとおり epoch 付き):

```zsh
NAME=VisionDocumentDAT
OUT="build/$NAME.plugin/Contents"
DYLIB="libVisionDocumentHelper_$(date +%s).dylib"
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"
swiftc -O -emit-library -module-name VisionDocumentHelper \
  -target arm64-apple-macos26.0 VisionDocumentHelper.swift \
  -framework Vision \
  -Xlinker -install_name -Xlinker "@rpath/$DYLIB" \
  -o "$OUT/Frameworks/$DYLIB"
clang++ -std=c++17 -fobjc-arc -O2 -bundle -I "$SDK" VisionDocumentDAT.mm \
  -framework Foundation -L "$OUT/Frameworks" -l"${DYLIB:3:-6}" \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks -o "$OUT/MacOS/$NAME"
# Info.plist を PlistBuddy で生成 → codesign --force --deep -s -
```

## dylibキャッシュ対策(超重要)

- **TDは同一パスの .plugin と依存dylibをプロセス内でキャッシュする**。リビルドしても reload で
  古いコードが動き続ける。特にヘルパdylibは **install name が同じだと dyld が旧dylibを使い続ける**
- 開発反復の手段(強い順):
  1. **TD再起動**(最も確実)
  2. dylibを **`lib*_<epoch>.dylib` 方式**にする(ビルド毎に名前が変わりキャッシュを回避)。
     `install_name_tool` で epoch 名に。ImageGen/Photogrammetry/Shazam/WhisperKit の build.sh はこの方式
  3. .plugin をバージョン付きパス(/tmp等)にコピーしてロード
- **SPM helperはフォルダ移動でModuleCacheパスが変わり再ビルド失敗**する
  (`precompiled file ... was compiled with module cache path ...`)。移動後は `rm -rf helper/.build`

## インストール(常設カスタムOP化)

```
cp -R <Name>/build/<Name>.plugin \
  ~/Library/Application\ Support/Derivative/TouchDesigner099/Plugins/
```

- **TD再起動**で OP Create Dialog に登録される
- **リネーム/差し替え時は旧名バンドルを先に削除**。旧バンドルが既に新opTypeを内包していると
  **opType重複衝突**を起こす
- cplusplus系ノードは plugin設定直後にカスタムパラメータが未生成のことがある →
  `reinitpulse` をパルスするか1フレーム待つ

## 調査用のデバッグコードは「ソースから消す」だけでは足りない

一時的に仕込んだ `setWarningString("PROBE ...")` のようなコードは、
**ソースから消したあと常設Pluginsへ再インストールし直す**まで残り続ける。
ソースはきれいなのにインストール済みバイナリだけ汚れている状態は気づきにくい
(実例: NC解像度の調査で入れたプローブが、翌日まで警告を出し続けていた)。

一括監査:

```sh
P=~/Library/Application\ Support/Derivative/TouchDesigner099/Plugins
for d in "$P"/*.plugin; do
  exe="$d/Contents/MacOS/$(basename "$d" .plugin)"
  [ -f "$exe" ] && strings -a "$exe" | grep -q PROBE && echo "$(basename $d)"
done
```

## リリース物はリポジトリの build/ から集める

`tools/release.sh` は `git ls-files '*/build.sh'` から対象を決め、各 `<Name>/build/*.plugin`
を収集する。**インストール済みの Plugins フォルダから集めてはいけない** —
サードパーティ製(Azure Kinect 等)や、古い/デバッグ入りのバンドルが混入する。
verify では署名・Hardened Runtime・Developer ID に加えて
**`OP_CommonAPIVersion` と `CFBundleShortVersionString`** も全数照合する。

## Git

- 巨大ファイル厳禁: `models/`(数GB)・`*.pt`・ビルド産物(`build/`)・`.build/` は gitignore 済み
- **100MB超のテスト動画・TDインポートキャッシュ・CrashAutoSave は gitignore**
  (`git add -A` が巻き込むと GH001 で push 却下。LFSは使わない方針)
- **.gitignoreの行内コメントは無効**(パターンが壊れる)。コメントは前の行に
- 5GB級を誤って `git add` するとハングする。中断後は `.git/objects/pack/tmp_pack_*` を掃除
- コミットメッセージは日本語で「何を・なぜ」。実測値があれば入れる。**このリポジトリは
  ブランチを切らず main へ直接コミット**

## バージョン付け(0.9.0 以降の規約)

バージョンは**3層**あり、意味が違う。単一ソースは**リポジトリ直下の `VERSION` ファイル**。

| 層 | 値 | 上げ方 |
|---|---|---|
| リポジトリ(gitタグ) | `VERSION`(例 `0.9.0`)→ `git tag v0.9.0` | op追加=minor / 修正=patch / opType変更=破壊的 |
| バンドル(Info.plist) | `CFBundleShortVersionString`=VERSION、`CFBundleVersion`=`git rev-list --count HEAD` | ビルド時に自動 |
| オペレータ(`customOPInfo`) | `majorVersion` / `minorVersion` | **opごとに独立** |

- ビルドスクリプトは `source ../common/version.sh` して、**.plugin 生成後に `td_stamp_all`** を呼ぶ
  (`common/build_plugin.sh` 経由なら自動。独自plistのbuild.shは末尾で呼ぶ)。
  **Info.plist を書き換えると署名が壊れる**ので、`td_stamp_version` は書き込み後に必ず再署名する
- **`majorVersion` を一斉に上げてはいけない**。TDは `.toe` に保存された major と
  インストール済みプラグインの major が**一致すること**を期待するため、無関係なopまで上げると
  既存プロジェクトが軒並み非互換扱いになる。**後方互換でない変更をしたそのopだけ +1** する
- `minorVersion` はリリースの minor に合わせる(TDは「.toe保存時 ≦ インストール版」を期待)
- 新規プラグインを追加したら `authorName` の直後に major/minor の2行を必ず入れる

## 最低対応 macOS (deployment target)

**指定しないとビルドしたマシンの OS が焼き込まれる。** macOS 27 beta 機でビルドすると
`minos 27.0` になり、27 の API を1行も使っていなくても **macOS 26 では dyld がロードを拒否する**。
配布物なら全ユーザーが起動できなくなる。

単一ソースは `common/version.sh`(全 build.sh が直接/経由で source する):

```sh
TD_MIN_MACOS="${TD_MIN_MACOS:-26.0}"
export MACOSX_DEPLOYMENT_TARGET="$TD_MIN_MACOS"      # clang++ 用
TD_SWIFT_TARGET="arm64-apple-macos$TD_MIN_MACOS"     # swiftc 用
```

**実測(macOS 26.6 / Xcode 26.4)で分かったこと**:

| ツール | `MACOSX_DEPLOYMENT_TARGET` | 必要な対応 |
|---|---|---|
| clang++ | **効く** | 環境変数だけでよい |
| swiftc | **効かない**(ホストの値のまま) | `-target arm64-apple-macosXX` を明示 |
| SwiftPM (`swift build`) | — | `Package.swift` の `platforms:` が効く |
| xcodebuild (SPM scheme) | — | 同上。追加指定は不要 |

`release.sh verify` が本体バイナリの minos を検査する。同梱ヘルパは意図的に低い値へ
固定していることがある(古い OS でも動く方が良いので)ため、本体だけを見る。

**確認コマンド**: `otool -l <実行ファイル> | grep -A3 LC_BUILD_VERSION | grep minos`
