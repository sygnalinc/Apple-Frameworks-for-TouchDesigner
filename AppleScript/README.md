# AppleScript DAT

**AppleScript / JavaScript(JXA)を TD から実行**する汎用オートメーションDAT(`osascript` 経由)。
他アプリ制御(Music/Finder/メール/Keynote 等)、システム情報取得、ワークフロー自動化など、
macOS のスクリプティングで出来ることを TD のイベント(パルス)から叩ける。**結果テキストも受け取れる**。

Shortcuts DAT より**自由度が高く結果も返る**のが特徴(Shortcutsは既製のショートカット実行専用)。

## 使い方

1. **Language** を選ぶ(AppleScript / JavaScript(JXA))
2. スクリプトを与える:
   - 短い1行 → **Script** パラメータ
   - 複数行 → **DAT(Text DAT等)を入力に接続**(全セルを改行連結してスクリプトにする・優先)
3. **Run** をパルスで実行
4. **画面(出力テーブル)は常に**: `status / result / error / took_ms / language`

## 例

| Language | Script | result |
|---|---|---|
| applescript | `return (10 + 5) * 2` | `30` |
| javascript | `6 * 7` | `42` |
| applescript | `return system version of (system info)` | `26.5.1` |
| applescript | `tell application "Finder" to return name of home` | `murata` |
| applescript | `tell application "Music" to play` | (再生開始) |
| applescript | `tell application "Music" to return name of current track` | 曲名 |
| applescript | `do shell script "open '/path/to/MyWorkflow.app'"` | Automator製 .app を起動 |
| applescript | `do shell script "automator '/path/to/foo.workflow'"` | Automator の .workflow を実行 |

## Automator の .app / .workflow を実行する

専用OPは不要。この AppleScript DAT からそのまま叩ける:

- **Automator で「アプリケーション」として書き出した .app**: 普通のアプリバンドルなので起動するだけ。
  - `do shell script "open '/Users/you/MyWorkflow.app'"`
  - または `tell application "/Users/you/MyWorkflow.app" to activate`
- **Automator の .workflow ファイル(文書)**: `/usr/bin/automator` に渡す。
  - `do shell script "automator '/Users/you/foo.workflow'"`
  - 入力を渡すなら `automator -i <input> foo.workflow`(automator の仕様に従う)

補足: Apple の `NSUserAutomatorTask` API は `.workflow` 専用かつ
`~/Library/Application Scripts/<bundle id>/` 配下に置いたものしか実行できない制約があるため、
TD からは上記の `do shell script "automator ..."` 経由が扱いやすい。`.app` は `NSUserAutomatorTask`
の対象外(普通のアプリなので `open` で起動する)。

## 実測(M2・macOS 26.5.1)

上記すべて OP経由で成功。**「Music を再生」も TD の AppleScript DAT から実行して `playing` に**。
構文エラーは status=error + error列に理由を出し、TDは落ちない。

## 権限(重要)

- **純粋な計算・システム情報取得は権限不要**
- **他アプリを操作するスクリプト**(`tell application "..."`)は macOS の **Automation権限(TCC)** が要る。
  TouchDesigner から実行するので、初回に「**TouchDesigner が <アプリ> を制御しようとしています**」の
  許可ダイアログが出る(**許可が必要**)。許可すれば以降は通る。拒否/未許可だと error 列に理由が出る
- Shortcuts DAT の CLI方式が「見つかりません」で失敗したのと違い、AppleScript は**正規の Automation
  許可フロー**に乗るので、許可さえ与えれば TD から直接アプリ制御でき、結果も取れる

## パラメータ

| パラメータ | 説明 |
|---|---|
| Language | applescript / javascript(JXA) |
| Script | 実行するスクリプト(入力DATがあればそちらを優先) |
| Run | 実行(パルス) |

Info CHOP: `executes / runs / running`

## 注意

- 実行はワーカースレッド(cook非ブロック)。スクリプトは `osascript` に stdin で渡す
- **Run は押した瞬間に即実行**。副作用のあるスクリプト(削除・送信等)は配線に注意
- 結果は 1〜数フレーム遅れで反映(パルス→cook でジョブ投入→ワーカー実行→次のcookで反映)
- 長時間ブロックするスクリプト(ダイアログ待ち等)は running のままになる

## ビルド

```
cd AppleScript && ./build.sh   # → build/AppleScriptDAT.plugin
```
