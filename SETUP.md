# SETUP.md — 別マシンで作業を引き継ぐ

このリポジトリを**別の Mac（macOS 27 beta 機など）でクローンして、そのまま開発を続ける**ための
手引き。リポジトリに入っていないもの・マシン固有の設定・ベータ環境特有の注意をまとめる。

規約とハマりどころ集と作業ログは **[CLAUDE.md](CLAUDE.md)** が正。こちらは「環境の作り方」だけ。

---

## 1. 何がリポジトリに入っていて、何が入っていないか

**入っている（クローンすれば揃う）**

| | |
|---|---|
| `CLAUDE.md` | 開発ガイド・ハマりどころ集・作業ログ。**AIエージェントは起動時に自動で読む** |
| `.claude/skills/` | `td-apple-plugin`（作る側）/ `td-apple-ops`（使う側）。**プロジェクトスキルとして自動で認識される** |
| `PLUGINS.tsv` | リリース対象の単一ソース |
| `demo.toe` | 全プラグインの利用例。`/project1/td_mcp_server` も内包 |
| `Assets/sample_*` | 検証用のサンプル映像・画像・音声（生成AI製またはApple製で再配布可） |
| `tools/` | `release.sh` / `apiscan.c` / `tdmcp.py` など |

**入っていない（別途用意する）**

| | 入手方法 |
|---|---|
| `models/` | [models/README.md](models/README.md) の表に入手先と `hf download` コマンド |
| `eval/` | モーション評価用の動画。**再配布不可のものが多いので意図的に除外**。手元で撮る/落とす |
| `demo_capture/` | README のデモGIFの元動画。GIF だけコミットしている |
| 大きい `Assets/*` | Cinematic 実素材・空間ビデオ・LIVE Photo など。実機で撮って置く |
| `~/.claude/.../memory/` | セッションメモリはマシンローカル。**内容は CLAUDE.md の「セッション運用メモ」に転記済み** |

---

## 2. 新しいマシンでやること

### 2.1 TouchDesigner は**同じビルドを入れる**

現在の基準は **2025.32280**（`defaults read /Applications/TouchDesigner.app/Contents/Info.plist CFBundleVersion` で確認）。

**バージョンが違うと `OP_CommonAPIVersion` が変わり、片方のマシンでビルドしたプラグインが
もう片方で「invalid opType name」という原因と無関係に見えるエラーで拒否される。**
実際に踏んでいる（CLAUDE.md 2026-08-07 の記録）。診断は:

```bash
cc -o /tmp/apiscan tools/apiscan.c
/tmp/apiscan <plugin>/Contents/MacOS/<実行ファイル>     # common=N を表示
grep -m1 'OP_CommonAPIVersion = ' \
  /Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CHOP/CPlusPlus_Common.h
```

この2つが一致しない環境では、**そのマシンでビルドし直す**のが唯一の解。

### 2.2 Xcode

**ほぼ全てのプラグインは Command Line Tools だけで足りる**(`clang++` と `swiftc` が使えればよい。
`xcode-select -p` が CommandLineTools を指していても問題ない)。

**例外は LLM MLX だけ**で、これには**フルXcode + Metal Toolchain** が要る:

- 理由: mlx-swift の Metal シェーダ(`default.metallib`)は **SwiftPM の `swift build` では
  作れない**(mlx-swift 公式README明記)。生成されないまま実行すると
  `Failed to load the default metallib` で死ぬので、**`xcodebuild` でビルドする**必要がある。
  `xcodebuild` はフルXcodeにしか入っていない
- `xcode-select --switch` は sudo が要るグローバル変更なので、**LLMMLX/build.sh が
  自分で `DEVELOPER_DIR` にフルXcodeを見つけて設定する**(他プラグインのCLTビルドに影響しない)。
  自動検出が外れる場合は自分で `DEVELOPER_DIR=<Xcode.app>/Contents/Developer` を渡す
- **Metal Toolchain は Xcode 本体と別コンポーネント**。未導入だと
  `cannot execute tool 'metal' due to missing Metal Toolchain` になるので:

  ```bash
  xcodebuild -downloadComponent MetalToolchain   # 約840MB
  ```

  **OS や Xcode を更新すると無効化される**(アセットはディスクに残るが
  `xcodebuild -showComponent MetalToolchain` が `Status: uninstalled` になる)。
  更新後に LLMMLX をビルドするなら**再ダウンロードが必要**。実測でOS betaの更新
  (26A5388g→26A5406e)で要求版が 27A5228f→27A5237l に変わり無効化された

### 2.3 ビルドの確認

```bash
./VisionPose/build.sh          # 1件だけ試す
otool -l VisionPose/build/VisionPoseCHOP.plugin/Contents/MacOS/VisionPoseCHOP \
  | grep -A3 LC_BUILD_VERSION | grep minos      # → 26.0 になるはず
```

**`minos` がホストの OS になっていたら `common/version.sh` が読まれていない。**
`TD_MIN_MACOS`（既定 26.0）で固定しているので、27 機でも 26.0 が出るのが正しい。

### 2.4 プラグインの設置

```bash
cp -R <Plugin>/build/*.plugin ~/Library/Application\ Support/Derivative/TouchDesigner099/Plugins/
```

TD は**起動時にしか走査しない**ので再起動が要る。多数を一度に入れると初回起動が数分かかる
（2回目以降はキャッシュで通常速度）。プラグインごとに許可ダイアログが出るので、
**まず使うものだけ**入れるのが楽。

### 2.5 TD MCP（AIエージェントから TD を操作する）

`demo.toe` を開くと `/project1/td_mcp_server` が **ポート 9988** で待ち受ける。

```bash
echo "def go(): return op('/project1').name
print(go())" | python3 tools/tdmcp.py
```

MCP ツールがセッションに登録されていないときも、この `tools/tdmcp.py` で駆動できる
（ポートは自動検出）。

> **セキュリティ**: このサーバーは `0.0.0.0` で待ち受け、**認証なしで TD 内の任意の Python を
> 実行できる**。同一 LAN の誰でもマシンを操作できるので、共有ネットワークでは demo.toe を
> 開いたままにしない。詳細は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

### 2.6 リリース（配布物を作るマシンだけ）

- **Developer ID Application 証明書**（`SYGNAL INC. (2ZSD5ZZLKB)`）を秘密鍵ごとキーチェーンへ
- 公証の認証情報を一度だけ登録:
  ```bash
  xcrun notarytool store-credentials tdappleops     # 対話式
  ```
- `./tools/release.sh sign → verify → dmg → notarize`

**リリースは必ず安定版 macOS のマシンで作る**（理由は次章）。

---

## 3. macOS 27 beta 機での注意

1. **配布物をベータ機で作らない。** `release.sh verify` が本体バイナリの `minos` を検査して
   止めるようにしてあるが、そもそも回さないこと。
2. **ベータ機でビルドしたバンドルを安定版機の Plugins フォルダに入れない。**
   SDK 混在は §2.1 の症状を引き起こす。
3. **macOS 27 の API を使うプラグインは `PLUGINS.tsv` の `minos` を `27.0` にする。**
   26 機ではビルド対象から外れる（除外時は必ずログに出す。黙って飛ばさない）。
4. **27 専用フレームワークは `-weak_framework` でリンクし、`@available` で分岐する。**
   非対応 OS では**エラーではなく警告 + 素通し**にする（Metal Denoise で確立した型）。
   弱リンクを忘れると 26 でロード自体が失敗する。
5. **ベータ SDK の API はベータ間で変わる。** `PLUGINS.tsv` の status は `experimental` のままにし、
   **27 が正式版になるまで `released` に上げない**。README の実測欄にベータ番号を書く。
6. **TouchDesigner 自体がベータ OS で不安定なことがある。** プラグインを疑う前に
   TD 単体が正常に起動・動作するかを先に確認する。

### 27 で最初にやる候補

CLAUDE.md（2026-07-20）に足場を残してある: **`GaussianSplatComponent`（macOS 27 で公開）**を使って
**RealityKit Splat TOP を作り直す**。3DGS `.ply` の自前パーサは git 履歴から復元できる
（`git log --all --diff-filter=D -- 'GaussianSplat*'`）。

---

## 4. 引き継ぎの作法

- **作業のたびに CLAUDE.md 末尾の作業ログへ追記する**（何を・なぜ・検証結果・次にやること）。
  次のセッションが CLAUDE.md だけで継続できる状態を保つ。
- 新しく踏んだ罠は該当セクションと `.claude/skills/td-apple-plugin/pitfalls.md` にも反映する。
- ブランチは `main` だけ。リリース対象は `PLUGINS.tsv` で決める（CLAUDE.md「ブランチ運用」節）。
