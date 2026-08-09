# Shortcuts DAT

**English** | [日本語](#日本語)

## English

**Runs macOS Shortcuts (Shortcuts.app) from TD.** HomeKit lighting, appliances, Music playback,
notifications, other-app integrations — anything a shortcut can do can be triggered from a TD
event (a pulse).

### Usage

1. Pick from the **Shortcut** dropdown (**the list is fetched automatically at startup**; use
   **Refresh List** when it changes)
2. Choose a **Run Method** (see below)
3. If input is needed, use **Input Text** or connect a DAT and its cell(0,0) is used
4. Pulse **Run**
5. **The DAT always displays status/info**: `status / shortcut / method / output / took_ms /
   shortcuts` (the list count)

The list is not "dumped" into the table (it goes into the dropdown), so the display always shows
the current state.

### Run Method (important — this is where people get stuck)

| Method | Behaviour | Output | Use for |
|---|---|---|---|
| **App (shortcuts://)** default | `open shortcuts://run-shortcut` **delegates to Shortcuts.app** | ✗ none | **Making something happen** — Music playback, lighting, notifications (almost everything) |
| CLI (output) | Runs `shortcuts run` directly | ○ returns text | Shortcuts that purely **return a value** |

**Why App is the default**: running the `shortcuts run` CLI straight from TouchDesigner executes
it **with TD's process permissions**, and shortcuts that drive external apps like Music or HomeKit
**fail** with the misleading error "the shortcut was not found" (measured). The App method runs
**inside Shortcuts.app**, which does have the permissions, so it works reliably — at the cost of
not returning the output text.

→ **Use App (default) to make something happen; use CLI when you need the output.** A shortcut
that fails under CLI is failing because TD lacks the permission (this is how macOS works).

### Measured (M2, macOS 26.5.1)

- 21 real user shortcuts fetched into the dropdown automatically at startup; the display always
  shows status
- Run (App method): "play every track on the album I'm listening to" → **Music.app went to
  `playing`** (from a TD operator)
- The same shortcut under CLI produced the "not found" error (TD lacking permission), which the
  App method solves
- Behaviour still depends on the shortcut itself (e.g. "play the album *now playing*" does nothing
  when Music is stopped, since there is no target). The operator reliably gets as far as launching

### Parameters

| Parameter | Description |
|---|---|
| Shortcut | The shortcut to run (**a dropdown**, fetched automatically at startup) |
| Input Text | Input for the shortcut (a connected DAT's cell(0,0) takes priority) |
| Run Method | app (delegate to Shortcuts.app, default) / cli (returns output) |
| Run | Execute (pulse) |
| Refresh List | Re-fetch the dropdown list (pulse) |

### Notes

- **Run fires the instant it is pulsed.** Be careful wiring shortcuts with side effects (locking,
  unlocking, purchasing…)
- Execution is on a worker thread (cook never blocks). The result appears one to a few frames later
- A pulse flows as "cook queues the job → the worker runs it → the next cook publishes the result"
- Using the output somewhere (connecting a null DAT, say) makes it cook every frame so the result
  reliably lands

### Build

```
cd Shortcuts && ./build.sh   # → build/ShortcutsDAT.plugin
```

## 日本語

**macOSショートカット(Shortcuts.app)をTDから実行**する。HomeKit照明・家電・Music再生・
通知・他アプリ連携など、ショートカットにできることは全て TD のイベント(パルス)から叩ける。

### 使い方

1. **Shortcut** プルダウンから選ぶ(**起動時に一覧を自動取得**。増減したら **Refresh List** で更新)
2. **Run Method** を選ぶ(下記)
3. 入力が要るなら **Input Text**、または入力DATの cell(0,0) を接続
4. **Run** をパルスで実行
5. **DATの画面は常に status/情報を表示**: `status / shortcut / method / output / took_ms / shortcuts`(一覧数)

一覧はテーブルに"ダンプ"されない(プルダウンに入る)ので、画面は常に現在の状態が見える。

### Run Method(重要 — ここでハマる)

| Method | 動作 | 出力 | 用途 |
|---|---|---|---|
| **App (shortcuts://)** 既定 | `open shortcuts://run-shortcut` で **Shortcuts.app に委譲** | ✗ 返らない | **Music再生・照明・通知など「動作」させる**もの(ほぼ全部) |
| CLI (output) | `shortcuts run` を直接実行 | ○ テキストが返る | 純粋に**値を返すだけ**のショートカット |

**なぜ App 方式が既定か**: TouchDesigner から `shortcuts run` CLI を直接叩くと、**TDのプロセス
権限で実行**され、Music/HomeKit等の外部アプリを操作するショートカットは
「ショートカットが見つかりませんでした」という紛らわしいエラーで**失敗する**(実測)。
App方式は権限を持つ **Shortcuts.app 側で走る**ので確実に動く。ただし出力テキストは受け取れない。

→ **動作させたいだけなら App(既定)、出力が欲しいなら CLI**。CLI で失敗するショートカットは
TD に権限が無いのが原因(macOS の仕様)。

### 実測(M2・macOS 26.5.1)

- 起動時に自動でユーザーの実ショートカット21件をプルダウンに取得。画面は常に status を表示
- Run(App方式): 「今聴いているアルバムの全曲を再生」を実行 → **Music.app が `playing` に**(TDのOPから)
- CLI方式で同じショートカットを実行すると「見つかりません」エラー(TD権限不足)を確認 → App方式で解決
- ※ ショートカット自身の挙動には依存する(例「"再生中の"アルバムを再生」はMusicが停止中だと対象が
  無く何もしない)。OPは launch まで確実に行う

### パラメータ

| パラメータ | 説明 |
|---|---|
| Shortcut | 実行するショートカット(**プルダウン**。起動時に自動取得) |
| Input Text | ショートカットへの入力(入力DATがあればその cell(0,0) を優先) |
| Run Method | app(Shortcuts.app委譲・既定)/ cli(出力を返す) |
| Run | 実行(パルス) |
| Refresh List | プルダウンの一覧を再取得(パルス) |

### 注意

- **Run は押した瞬間に即実行**。施錠/開錠・購入等の副作用ショートカットは配線に注意
- 実行はワーカースレッド(cook非ブロック)。結果は 1〜数フレーム遅れで反映
- パルスは「cook でジョブ投入 → ワーカー実行 → 次の cook で結果反映」の流れ
- 出力をどこかで使う(null DAT等に繋ぐ)と毎フレーム cook され結果が確実に反映される

### ビルド

```
cd Shortcuts && ./build.sh   # → build/ShortcutsDAT.plugin
```
