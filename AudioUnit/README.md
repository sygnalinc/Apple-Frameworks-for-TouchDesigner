# AudioUnit CHOP

**English** | [日本語](#日本語)

## English

Hosts **Audio Unit effects** in TouchDesigner's audio path — pick a plugin, wire audio through it,
automate its parameters from CHOP channels, and open the plugin's own GUI.

> **Status: experimental.** Verified end to end on macOS 26 with Apple's bundled effects (audio
> processing, parameter automation, presets, state save/restore, GUI window). Not tested with
> third-party plugins yet, and **not shipped in the release DMG**. `PLUGINS.tsv` is the source of
> truth — build it yourself from this folder.

### Why this exists

TouchDesigner ships an **Audio VST CHOP**, but on macOS it hosts **VST3 only** — the bundled
`libJUCE.dylib` contains `VST3PluginFormat` and **no `AudioUnitPluginFormat`**, and it scans only
`/Library/Audio/Plug-Ins/VST3`. Meanwhile macOS itself ships around 30 Audio Units, and many
Mac-native plugins are distributed as AU.

Measured on a stock M2 (macOS 26.6): **0 VST3 plugins installed, 30 Audio Units** — 23 effects,
3 instruments, 4 generators, all from Apple. This operator makes those usable.

### What it does

- Lists every installed AU **effect** (`aufx`) in a dropdown, and loads the one you pick
- Runs the audio through it: input CHOP → `AVAudioSourceNode` → the AU → manual rendering
- **Automates parameters** from a second CHOP input, matched by channel name
- Applies **factory presets**
- Opens the plugin's **own GUI** in a floating window
- **Saves the plugin's state into the .toe** so a sound you dialled in by hand survives a reopen

### Measured (M2, macOS 26.6)

| | |
|---|---|
| Plugins found | 24 menu entries (23 Apple effects + "none") |
| Cost | **0.009 ms** per 512-sample block, two AUs in series (standalone harness) |
| In TD | 735 samples per cook at 44100 Hz / 60 fps, no dropped blocks |
| Bypass on / off | peak 0.500 (exactly the source) vs 0.583 (AUDistortion) |
| Output gain 0.5 | peak 0.292 = 0.583 × 0.5 |
| Parameter automation | `Delay_Mix` 0 / 45 / 100 → AU value and output follow |
| Plugin state | 463 base64 characters for AUDistortion; restored correctly after switching plugins away and back |
| GUI | AUDistortion's own view, 581×518, floating (window layer 3) |

### Inputs

| Input | What |
|---|---|
| 0 | Audio (required). Mono is duplicated to stereo |
| 1 | Parameter automation (optional). One channel per parameter you want to drive |

Output is always **stereo** (`left` / `right`).

### Driving parameters

Attach an Info DAT to see the parameter table — `index`, `channel`, `name`, `min`, `max`, `value`,
`unit`. **The `channel` column is the exact channel name to use.** For example AUDistortion gives
`Delay`, `Decay`, `Delay_Mix`, `Ring_Mod_Freq_1`, … `WetDry_Mix`.

Channel names come from the parameter's **display name**, not its identifier — several Apple AUs
report identifiers that are just `"0"`, `"1"`, `"2"`, which would collide with the `p<index>`
aliases. You can also address a parameter positionally as `p0`, `p1`, ….

A parameter is written **only when the incoming value changes**, so anything you do not automate
stays under the control of the plugin's GUI and presets.

### Plugin state

The GUI is only useful if what you set there survives. `Save Plugin State` serializes the AU's
`fullState` to base64 into the `Plugin State` string parameter, which saves with the .toe;
`Load Plugin State` restores it after the plugin loads. State is also captured automatically when
you close the GUI window. The state is tagged with the plugin ID, so switching plugins never feeds
one plugin's state into another.

### Parameters

| Parameter | What |
|---|---|
| Active | Off passes audio through untouched |
| Plugin | Installed AU effects. The stored value is `type:subtype:manufacturer` in hex, so it survives renames and reinstalls |
| Rescan Plugins | Re-enumerate (after installing a new plugin) |
| Factory Preset | Presets the plugin ships with |
| Bypass | Uses the AU's own bypass, so effect tails are handled properly |
| Dry / Wet | 1 is fully processed, 0 is the original |
| Output Gain | Applied after the mix |
| Display GUI | Opens the plugin's own interface |
| Always On Top | Floating window vs a normal one |
| Reset Plugin State | Clears the AU's internal state (reverb tails etc.) |
| Load / Save Plugin State, Plugin State | See above |

### Notes

- **Effects only** (`aufx`). Instruments (`aumu`) and music effects (`aumf`) need MIDI input and are
  not handled yet — pair a future version with [CoreMIDI In](../CoreMIDI/)
- Plugins load with the system's default policy for that component, so v3 app-extension plugins run
  **out of process** and a crash there does not take TouchDesigner with it
- **TouchDesigner cannot grow parameters at runtime.** `setupParameters` is called exactly once per
  instance (measured), so the VST CHOP's "learn parameters" — which turns plugin parameters into
  real TD parameters — cannot be reproduced through the public C++ SDK. The automation input plus
  the Info DAT is the equivalent here
- This operator only cooks when something downstream asks for it. If the GUI does not appear, check
  that the CHOP is actually cooking

### Build

```bash
cd AudioUnit && ./build.sh   # → build/AudioUnitCHOP.plugin
```

---

## 日本語

**Audio Unit エフェクト**を TouchDesigner のオーディオ経路でホストする。プラグインを選んで音を
通し、CHOP のチャンネルでパラメータを動かし、プラグイン自身の GUI も開ける。

> **状態: experimental。** macOS 26 上で Apple 純正エフェクトを使い、音の処理・パラメータ自動化・
> プリセット・状態の保存復元・GUI 表示まで一通り実測済み。ただし**サードパーティ製プラグインでは
> 未検証**で、**リリース DMG には入らない**。正は `PLUGINS.tsv`。使うにはこのフォルダで
> 自分でビルドする。

### なぜ必要か

TouchDesigner には **Audio VST CHOP** があるが、macOS では **VST3 しかホストしない**。
同梱の `libJUCE.dylib` に入っているのは `VST3PluginFormat` だけで **`AudioUnitPluginFormat` は
無く**、走査先も `/Library/Audio/Plug-Ins/VST3` のみ。一方 macOS 自体が 30 個ほどの Audio Unit を
標準で持っていて、Mac 向けプラグインは AU で配られることも多い。

素の M2(macOS 26.6)での実数: **VST3 が 0個・Audio Unit が 30個**(エフェクト23・
インストゥルメント3・ジェネレータ4、すべて Apple 純正)。この op はそれを使えるようにする。

### できること

- インストール済みの AU **エフェクト**(`aufx`)をプルダウンに列挙してロード
- 音を通す: 入力CHOP → `AVAudioSourceNode` → AU → manual rendering
- 2つ目の CHOP 入力から**チャンネル名でパラメータを自動化**
- **ファクトリープリセット**の適用
- プラグイン**自身の GUI** をフローティングウインドウで表示
- **プラグインの状態を .toe に保存**。GUI で作り込んだ音が開き直しても残る

### 実測(M2・macOS 26.6)

| | |
|---|---|
| 検出されたプラグイン | メニュー24件(Apple 純正エフェクト23 + none) |
| 処理コスト | AU 2段直列で **512サンプル1ブロックあたり 0.009 ms**(単体ハーネス) |
| TD 上 | 44100 Hz / 60 fps で 1 cook あたり 735 サンプル・取りこぼしなし |
| Bypass On / Off | peak 0.500(入力そのもの)対 0.583(AUDistortion) |
| Output Gain 0.5 | peak 0.292 = 0.583 × 0.5 |
| パラメータ自動化 | `Delay_Mix` 0 / 45 / 100 で AU 側の値と出音が追従 |
| プラグイン状態 | AUDistortion で base64 463文字。別プラグインへ切り替えて戻しても復元される |
| GUI | AUDistortion 自身の画面 581×518・最前面(layer 3) |

### 入力

| 入力 | 内容 |
|---|---|
| 0 | 音声(必須)。モノならステレオに複製する |
| 1 | パラメータ自動化(任意)。動かしたいパラメータごとに1チャンネル |

出力は常に**ステレオ**(`left` / `right`)。

### パラメータの動かし方

Info DAT を繋ぐとパラメータ表が出る(`index` / `channel` / `name` / `min` / `max` / `value` /
`unit`)。**`channel` 列がそのまま使うチャンネル名**。例えば AUDistortion なら
`Delay` `Decay` `Delay_Mix` `Ring_Mod_Freq_1` … `WetDry_Mix`。

チャンネル名は識別子ではなく**表示名**から作っている。Apple の AU には識別子が `"0"` `"1"` `"2"` と
数字だけのものがあり、それだと添え字別名 `p<index>` と衝突するため(実測で発覚)。位置で指したい
場合は `p0` `p1` … も使える。

パラメータは**値が変わったときだけ**書き込む。自動化していないパラメータはプラグインの GUI や
プリセットが持ち主のままになる。

### プラグインの状態

GUI は「そこで作った音が残る」ことで初めて役に立つ。`Save Plugin State` で AU の `fullState` を
base64 にして `Plugin State` 文字列パラメータへ入れる(.toe と一緒に保存される)。
`Load Plugin State` がロード後に復元する。GUI ウインドウを閉じたときにも自動で保存される。
状態にはプラグインIDを付けてあるので、別プラグインの状態が流し込まれることはない。

### パラメータ

| パラメータ | 内容 |
|---|---|
| Active | Off で素通し |
| Plugin | インストール済み AU エフェクト。保存される値は `type:subtype:manufacturer` の16進なので、名前が変わっても再インストールしても壊れない |
| Rescan Plugins | 一覧を取り直す(新しいプラグインを入れた後) |
| Factory Preset | プラグイン同梱のプリセット |
| Bypass | AU 自身のバイパスを使うので残響の切れ方が自然 |
| Dry / Wet | 1 で全部エフェクト、0 で原音 |
| Output Gain | ミックス後に掛かる |
| Display GUI | プラグイン自身の画面を開く |
| Always On Top | 最前面に固定するか |
| Reset Plugin State | AU の内部状態(残響など)を消す |
| Load / Save Plugin State・Plugin State | 上記 |

### 注意

- **エフェクト専用**(`aufx`)。インストゥルメント(`aumu`)と Music Effect(`aumf`)は MIDI 入力が
  要るため未対応。将来 [CoreMIDI In](../CoreMIDI/) と組み合わせる想定
- 読み込み方はそのコンポーネントの既定に任せているので、v3 のアプリ拡張型プラグインは
  **別プロセスで動く**。そちらが落ちても TouchDesigner は巻き込まれない
- **TD は実行中にパラメータを増やせない。** `setupParameters` はインスタンスにつき**1回きり**しか
  呼ばれない(実測)。そのため VST CHOP の「learn parms」(プラグインのパラメータを TD のパラメータ
  として生やす機能)は公開 C++ SDK では再現できない。ここでは自動化入力 + Info DAT がその代わり
- この op は下流から要求されたときだけ cook する。GUI が出ないときは、まず**cook されているか**を疑う

### ビルド

```bash
cd AudioUnit && ./build.sh   # → build/AudioUnitCHOP.plugin
```
