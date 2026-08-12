# AppleScript DAT

**English** | [日本語](#日本語)

## English

Runs **AppleScript / JavaScript (JXA) from TouchDesigner** via `osascript`. Anything macOS
scripting can do — controlling other apps (Music, Finder, Mail, Keynote…), reading system
information, automating workflows — can be triggered from a TD pulse, and **the result text
comes back**.

Compared to the Shortcuts DAT this is **more flexible and it returns a value** (Shortcuts only
runs pre-built shortcuts).

### Usage

1. Pick a **Language** (AppleScript / JavaScript (JXA))
2. Supply the script:
   - one-liner → the **Script** parameter
   - multi-line → **connect a DAT** (e.g. a Text DAT) to the input; all cells are joined with
     newlines and take priority over the parameter
3. Pulse **Run**
4. The **output table always shows** `status / result / error / took_ms / language`

### Examples

| Language | Script | result |
|---|---|---|
| applescript | `return (10 + 5) * 2` | `30` |
| javascript | `6 * 7` | `42` |
| applescript | `return system version of (system info)` | `26.5.1` |
| applescript | `tell application "Finder" to return name of home` | `murata` |
| applescript | `tell application "Music" to play` | (starts playback) |
| applescript | `tell application "Music" to return name of current track` | track name |
| applescript | `do shell script "open '/path/to/MyWorkflow.app'"` | launches an Automator app |
| applescript | `do shell script "automator '/path/to/foo.workflow'"` | runs an Automator workflow |

### Running Automator `.app` / `.workflow`

No dedicated operator is needed — drive them from this DAT:

- **`.app` exported from Automator as an Application**: an ordinary app bundle, just launch it.
  - `do shell script "open '/Users/you/MyWorkflow.app'"`
  - or `tell application "/Users/you/MyWorkflow.app" to activate`
- **`.workflow` document**: pass it to `/usr/bin/automator`.
  - `do shell script "automator '/Users/you/foo.workflow'"`
  - to pass input, `automator -i <input> foo.workflow` (per automator's own rules)

Note: Apple's `NSUserAutomatorTask` API only handles `.workflow` files placed under
`~/Library/Application Scripts/<bundle id>/`, so `do shell script "automator ..."` is the
practical route from TD. `.app` files are outside `NSUserAutomatorTask` entirely (they are
normal apps — launch them with `open`).

### Measured (M2, macOS 26.5.1)

All of the above succeeded through the operator, including **starting Music playback from the
AppleScript DAT** (`playing`). A syntax error reports `status=error` plus the reason in the
`error` row; TD does not crash.

### Permissions (important)

- **Pure computation and system info need no permission**
- Scripts that **drive another app** (`tell application "..."`) need macOS **Automation (TCC)
  permission**. Because the script runs from TouchDesigner, the first attempt shows a
  "**TouchDesigner wants to control &lt;app&gt;**" dialog that **must be approved**. Once granted it
  keeps working; if denied, the reason appears in the `error` row.
- Unlike the Shortcuts DAT CLI route (which fails with "not found"), AppleScript goes through
  the **proper Automation permission flow**, so with approval TD can control apps directly and
  still read the result.

### Parameters

| Parameter | Description |
|---|---|
| Language | applescript / javascript (JXA) |
| Script | Script to run (an input DAT takes priority) |
| Run | Execute (pulse) |

Info CHOP: `executes / runs / running`

### Notes

- Execution happens on a worker thread (cook never blocks). The script is piped to `osascript`
  over stdin
- **Run fires the instant it is pulsed.** Be careful wiring scripts with side effects (delete,
  send, …)
- The result appears one to a few frames later (pulse → cook queues the job → worker runs it →
  next cook publishes it)
- A script that blocks for a long time (waiting on a dialog, etc.) leaves `running` set

### Build

```
cd AppleScript && ./build.sh   # → build/AppleScriptDAT.plugin
```

## 日本語

**AppleScript / JavaScript(JXA)を TD から実行**する汎用オートメーションDAT(`osascript` 経由)。
他アプリ制御(Music/Finder/メール/Keynote 等)、システム情報取得、ワークフロー自動化など、
macOS のスクリプティングで出来ることを TD のイベント(パルス)から叩ける。**結果テキストも受け取れる**。

Shortcuts DAT より**自由度が高く結果も返る**のが特徴(Shortcutsは既製のショートカット実行専用)。

### 使い方

1. **Language** を選ぶ(AppleScript / JavaScript(JXA))
2. スクリプトを与える:
   - 短い1行 → **Script** パラメータ
   - 複数行 → **DAT(Text DAT等)を入力に接続**(全セルを改行連結してスクリプトにする・優先)
3. **Run** をパルスで実行
4. **画面(出力テーブル)は常に**: `status / result / error / took_ms / language`

### 例

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

### Automator の .app / .workflow を実行する

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

### 実測(M2・macOS 26.5.1)

上記すべて OP経由で成功。**「Music を再生」も TD の AppleScript DAT から実行して `playing` に**。
構文エラーは status=error + error列に理由を出し、TDは落ちない。

### 権限(重要)

- **純粋な計算・システム情報取得は権限不要**
- **他アプリを操作するスクリプト**(`tell application "..."`)は macOS の **Automation権限(TCC)** が要る。
  TouchDesigner から実行するので、初回に「**TouchDesigner が <アプリ> を制御しようとしています**」の
  許可ダイアログが出る(**許可が必要**)。許可すれば以降は通る。拒否/未許可だと error 列に理由が出る
- Shortcuts DAT の CLI方式が「見つかりません」で失敗したのと違い、AppleScript は**正規の Automation
  許可フロー**に乗るので、許可さえ与えれば TD から直接アプリ制御でき、結果も取れる

### パラメータ

| パラメータ | 説明 |
|---|---|
| Language | applescript / javascript(JXA) |
| Script | 実行するスクリプト(入力DATがあればそちらを優先) |
| Run | 実行(パルス) |

Info CHOP: `executes / runs / running`

### 注意

- 実行はワーカースレッド(cook非ブロック)。スクリプトは `osascript` に stdin で渡す
- **Run は押した瞬間に即実行**。副作用のあるスクリプト(削除・送信等)は配線に注意
- 結果は 1〜数フレーム遅れで反映(パルス→cook でジョブ投入→ワーカー実行→次のcookで反映)
- 長時間ブロックするスクリプト(ダイアログ待ち等)は running のままになる

### ビルド

```
cd AppleScript && ./build.sh   # → build/AppleScriptDAT.plugin
```
