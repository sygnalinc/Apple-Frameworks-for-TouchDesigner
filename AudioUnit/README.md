# AU Effect / AU Instrument CHOP

**English** | [日本語](#日本語)

## English

Hosts **Audio Units** in TouchDesigner. Two operators share one implementation:

| Operator | What it hosts | Input 0 | Input 1 |
|---|---|---|---|
| **AU Effect** (`Aueffect`) | effects (`aufx`) | audio | parameter panel |
| **AU Instrument** (`Auinstrument`) | instruments (`aumu`) | notes (optional) | parameter panel |

Pick a plugin, automate its parameters from CHOP channels, and open the plugin's own GUI.
TouchDesigner's own Audio VST CHOP is **VST3-only** (`libJUCE.dylib` carries `VST3PluginFormat`
and no `AudioUnitPluginFormat`, measured), so on a stock Mac it finds 0 plugins where these find 30.
It *does* host instruments — `libC_CHOP.dylib` imports `JUCE_VSTPluginHost::sendMidiBytes` and the
CHOP exposes `sendNoteOn` / `sendControl` / `panic` and eight more MIDI methods — so the gap these
operators fill is **Audio Units**, not instruments as such. The two also differ in how you play
them: TD's takes notes through **Python method calls**, while AU Instrument takes them as **CHOP
channels**, so a CoreMIDI In CHOP wires straight in (a C++ Custom OP cannot add Python methods).

### Latency

If notes feel late when you play a MIDI keyboard, it is almost always **Audio Device Out**, not this
operator. Its `Buffer Length` defaults to **0.15 s**, and that goes straight into the delay you hear.

| Stage | Delay |
|---|---|
| CoreMIDI In CHOP | 0–1 frame (16.7 ms at 60 fps) — the receive thread has no queue |
| AU Effect / AU Instrument | none — notes are applied in the same cook that renders the block |
| **Audio Device Out `Buffer Length`** | **150 ms by default** |

Drop `Buffer Length` to **0.02–0.05** and raise the project to 120 fps if you need more. Too small a
buffer causes dropouts, and heavy plugins need more headroom, so tune it by ear.

A "render straight to the audio device" mode would not help much: the output device on this machine
sits at **13.7 ms** (512-frame buffer at 48 kHz, plus 74 latency and 73 safety frames), and notes
arriving through a CHOP still cost a frame — about 30 ms all in, against 35–50 ms for a tuned CHOP
path. Going below that means the instrument opening CoreMIDI itself instead of taking notes from a
CHOP.

- **Program change** picks the instrument: a `ch<channel>p` channel switches the GM program on that
  channel (TouchDesigner reports GM programs **1-based**, so 69 means Oboe). This is what lets one
  multi-timbral instrument play a multi-track MIDI file with its real orchestration
- **`Sound Bank` matters**: AUMIDISynth ignores program changes with no bank loaded — measured, every
  program renders a **byte-identical** waveform. The parameter defaults to the bank macOS ships
  (`/System/Library/.../gs_instruments.dls`); with it loaded, programs sound clearly different
  (piano rms 0.022 / violin 0.058 / oboe 0.072). DLSMusicDevice responds without a bank but is
  silent inside TouchDesigner, so **AUMIDISynth + the default bank** is the combination that works

### Playing notes with AU Instrument

- **Wire a note CHOP into input 0.** Channels are named `ch<channel>n<note>` (**exactly what
  CoreMIDI In CHOP emits**) or `note<note>`. The value is velocity: **above 0 starts the note,
  back to 0 stops it**. Both 0–1 and raw MIDI velocities (1–127) are accepted
- With no input at all, the **Play page** (`Note`, `Velocity`, `MIDI Channel`, `Note On`,
  `Note Off`, `All Notes Off`) is enough to hear the plugin
- The Info CHOP reports `notes_sent` / `notes_held` — check these first when nothing sounds
- Turning `Active` off sends **all notes off** immediately, so nothing is left ringing

**Measured (M2)**: AUMIDISynth peaks at 0.217 for one note, 0.559 for `ch1n64` + `ch1n67` together,
and `notes_held` returns to 0 when the values go back to 0. Cook time 0.138 ms.
**DLSMusicDevice is silent inside TouchDesigner** — the same code reaches 0.117 in a standalone
process, so that plugin appears not to load its default sound bank in this context. If you hear
nothing, try **AUMIDISynth, AUSampler, or a third-party instrument** before suspecting the wiring.

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
- **Learn**: touch a knob in the GUI and it appears on the panel — drive it from MIDI, keyframes
  or expressions. Assignments are remembered per plugin

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
| Learn | Touching a parameter assigns it to `learn1`; slider 0 / 0.25 / 0.5 / 1 → `WetDry_Mix` 0 / 25 / 50 / 100; the same via a `learn1` input channel; the mapping came back after switching plugins away and back |
| Two-way sync | With Learn still on: AU side moves → slot follows (`Delay` 1.6 → 0.003, 15.5 → 0.031); slot moves → AU follows (0.0 / 0.4 / 1.0 → 0.1 / 200.06 / 500) |
| Display curve | AUPeakLimiter, slot 0.7 → `Attack Time` 0.0087837 = exactly 0.700 on its log curve (linear would read 0.281); `Pre-Gain` 0.7 → 16 (linear) |

### Inputs

| Input | What |
|---|---|
| 0 | Audio (required). Mono is duplicated to stereo |
| 1 | Parameter automation (optional). One channel per parameter you want to drive |

Output is always **stereo** (`left` / `right`).

### Learn (choosing which parameters go on the panel)

TouchDesigner's Audio VST CHOP has **Learn Parameters**, which turns plugin parameters into real TD
parameters. A C++ Custom OP cannot do that — `setupParameters` is called **once per instance**
(measured), and Python cannot add parameters to a CHOP either (`appendCustomPage` exists on COMPs
but not on a CHOP, measured). **A Script CHOP can**, so that is where the controls live.

1. Turn **Learn Parameters** on — the panel is created for you if it does not exist yet
2. Open the GUI and touch the knobs you want — **each one appears on the panel as you touch it**

There is no third step: the panel is rebuilt the moment a parameter is learned. **Create / Rebuild
Panel** is only there to recreate the panel if you deleted it. Learning works whether or not audio
is flowing — the parameter side of the operator runs even with no signal on input 0.

Turning Learn off and on again does not disturb an existing panel. The panel lands **directly below
the operator with its viewer open**, and the two DATs it needs (its callbacks and the parameter
table) are **docked to their host as closed chips** — click a chip to open one.

The panel is never written to from inside the operator's cook. Its parameters sit **upstream on
input 1**, so touching them while the operator cooks makes TouchDesigner report a **Cook dependency
loop** — the rebuild is deferred by one frame instead. For the same reason the panel script never
calls `store()` on itself (its parse cache is a module-level dict).

**Assignments are stored per plugin** in the `Learned Mapping` parameter, which saves with the .toe.
Switch to another plugin and back and your selection returns. The Info DAT's `learn` column shows
what is currently selected.

### Driving from a MIDI controller

Wire the controller into the **panel's** input and name the channels after the parameters:

```
MIDI In CHOP  →  Rename CHOP ("ch1c74" → "Low_Frequency")  →  panel Script CHOP input 0
```

Incoming values are read as **0–1 and stretched along the parameter's own display curve**, so a
plain CC sweeps the knob exactly as the plugin's GUI would. Measured on `Low Frequency`
(10–21829.5 Hz, logarithmic): 0.25 → 68.35 Hz, 0.5 → 467.22 Hz, 1.0 → 21829.5 Hz — log positions
0.250 / 0.500 / 1.000. The panel's own control shows the real value while it is being driven.

### Driving parameters

Attach an Info DAT to see the parameter table — `index`, `channel`, `name`, `min`, `max`, `value`,
`unit`. **The `channel` column is the exact channel name to use.** For example AUDistortion gives
`Delay`, `Decay`, `Delay_Mix`, `Ring_Mod_Freq_1`, … `WetDry_Mix`. Assigned slots can also be
addressed as `learn1`, `learn2`, ….

`Input Range` decides what the numbers on input 1 mean: **Normalized** (default) treats 0–1 as a
knob position and stretches it along the parameter's display curve, **Raw** takes the value in the
parameter's own unit (Hz, ms, dB) and clamps it to min–max. **The generated panel follows this
setting** — switch it and the panel is rebuilt with the matching sliders, converting the values as
it goes, so nothing jumps: `Delay_Mix` at 75.7% shows `0.757` in Normalized and `75.7` (range
0–100) in Raw, and `Ring Mod Freq 1` at 1000 Hz shows `1000` (range 0.5–8000) or `0.7852`, its
position on the log curve. The plugin's own value is untouched either way.

Channel names come from the parameter's **display name**, not its identifier — several Apple AUs
report identifiers that are just `"0"`, `"1"`, `"2"`, which would collide with the `p<index>`
aliases. You can also address a parameter positionally as `p0`, `p1`, ….

A parameter is written **only when the incoming value changes**, so anything you do not automate
stays under the control of the plugin's GUI and presets.

### How the plugin's GUI and this operator stay in sync

Apple's bundled AUs are **v2** units wrapped in an AUv3 bridge, and the two sides do not sync both
ways. Measured:

| | Result |
|---|---|
| Write `AUParameter.value` → read the v2 unit | **syncs** (so the audio changes) |
| Move a knob in the GUI (writes the v2 unit) → read `AUParameter.value` | **does not sync** — the value stays stale |
| Move a knob in the GUI → parameter observer | **never fires** |
| Write `AUParameter.value` → a GUI-style `AUEventListener` | **0 notifications** — the GUI does not redraw |
| The same write followed by `AUEventListenerNotify` | **delivered** — the GUI follows |

So this operator **reads the v2 side** (`AudioUnitGetParameter`) and **posts an event after every
write**. Learn works by polling those v2 values rather than by the parameter observer, which is why
turning a knob in the plugin's own window is picked up at all.

One more trap: **`AUParameter.address` *is* the v2 parameter ID** — verified against six plugins,
100% of names matched when the v2 `ParameterInfo` was fetched by address. What is *not* safe is
walking `kAudioUnitProperty_ParameterList` and pairing it with the v3 tree by position: **the two
orders differ** (AUDistortion, 11 of 16 out of place; AUMatrixReverb, 11 of 17). Pairing by index
makes the host read one parameter while writing another, and values appear stuck.

### A panel with the right controls for each parameter

`Create / Rebuild Panel` generates a **Script CHOP** beside the node and wires it into input 1. It
reads the parameter table and grows a **properly typed control for each learned parameter** — a
menu with the plugin's own choice names, a toggle, an integer, or a float. **Float controls are
always 0–1 knob position**, so a knob sitting halfway in the plugin's window reads 0.5 here no
matter what the underlying units or curve are; the real value (Hz, ms, dB) is in the Info DAT's
`value` column. Measured on AUPeakLimiter: `Pre-Gain` centred in the GUI → 0.5000 exactly, while
`Attack Time` at 0.002 s (log, 0.0005–0.03) reads 0.3386. Measured across the 24 installed effects: 189 parameters want a slider, **24 are indexed
(menus)** and **18 are boolean (toggles)**, so a page of bare 0–1 sliders throws away a lot.

The op cannot grow parameters itself, but a Script CHOP can — `onSetupParameters` may append
`Float` / `Int` / `Menu` / `Toggle` at any time, and it rebuilds itself when the learned set changes.

The panel is **two-way with the plugin's own GUI**: move a knob in the plugin window and the panel
follows; move a panel control and the plugin follows. Measured: panel 400 / 5000 Hz → plugin 400 /
5000 exactly, menu → `High Pass`, gain → −12 dB; and with the plugin driven from elsewhere the panel
tracked it (10 Hz / 21829.5 Hz). Steady-state cost of the pair is **0.45 ms** per frame.

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
| Learn Parameters / Clear Learned / Learned Mapping | Which parameters go on the panel |
| Create / Rebuild Panel | Generates the Script CHOP panel described above |

### Notes

- **Effects only** (`aufx`). Instruments (`aumu`) and music effects (`aumf`) need MIDI input and are
  not handled yet — pair a future version with [CoreMIDI In](../CoreMIDI/)
- Plugins load with the system's default policy for that component, so v3 app-extension plugins run
  **out of process** and a crash there does not take TouchDesigner with it
- **A C++ Custom OP cannot grow parameters at runtime.** `setupParameters` is called exactly once
  per instance (measured), and Python cannot add them either — `appendCustomPage` exists on COMPs but
  not on a CHOP (measured). That is why the controls live on a generated **Script CHOP**, which can
  grow. Up to **128** parameters can be learned; past that you get a warning and **Clear Learned**
  starts over (the limit is `kLearnSlots`, a one-line change)
- This operator only cooks when something downstream asks for it. If the GUI does not appear, check
  that the CHOP is actually cooking

### Build

```bash
cd AudioUnit && ./build.sh   # → build/AudioUnitCHOP.plugin
```

---

## 日本語

**Audio Unit** を TouchDesigner でホストする。実装は共通で、オペレータが2つある:

| オペレータ | ホストするもの | 入力0 | 入力1 |
|---|---|---|---|
| **AU Effect**(`Aueffect`) | エフェクト(`aufx`) | 音声 | パラメータのパネル |
| **AU Instrument**(`Auinstrument`) | 楽器(`aumu`) | ノート(任意) | パラメータのパネル |

プラグインを選び、CHOP のチャンネルでパラメータを動かし、プラグイン自身の GUI も開ける。
TouchDesigner 標準の Audio VST CHOP は **VST3 専用**(`libJUCE.dylib` に `VST3PluginFormat` は
あるが `AudioUnitPluginFormat` は無い・実測)なので、素の Mac では VST3 が0個に対し
こちらは30個見つかる。**楽器自体は TD 標準でもホストできる**(`libC_CHOP.dylib` が
`JUCE_VSTPluginHost::sendMidiBytes` を参照し、CHOP に `sendNoteOn` / `sendControl` / `panic` など
MIDI メソッドが11個ある)。したがってこの op が埋めるのは「楽器」ではなく **Audio Unit** の穴。
鳴らし方も違い、TD 標準は **Python のメソッド呼び出し**、AU Instrument は **CHOP のチャンネル**
なので CoreMIDI In CHOP をそのまま繋げる(C++ Custom OP は Python メソッドを生やせないため)。

### レイテンシ

MIDI キーボードで弾いて音が遅れるときは、**ほぼ Audio Device Out** が原因でこの op ではない。
`Buffer Length` の既定が **0.15 秒**で、それがそのまま体感の遅れになる。

| 要素 | 遅れ |
|---|---|
| CoreMIDI In CHOP | 0〜1フレーム(60fps で 16.7ms)。受信スレッドにキューは無い |
| AU Effect / AU Instrument | 無し。ノートは**そのブロックをレンダする同じ cook 内**で適用される |
| **Audio Device Out の `Buffer Length`** | **既定 150ms** |

`Buffer Length` を **0.02〜0.05** に下げる。足りなければ fps を 120 に上げる。
小さくしすぎると音切れするし、重いプラグインほど余裕が要るので**耳で詰める**。

「オーディオデバイスへ直接出す」モードにしてもあまり得しない: この機体の出力デバイスは
**13.7ms**(48kHz・バッファ512フレーム + latency 74 + safety 73)で、CHOP 経由のノートは
どのみち1フレーム掛かるので合計 約30ms。詰めた CHOP 経路の 35〜50ms との差は小さい。
これより下げるには、**楽器側が CoreMIDI を自分で開いて** cook を介さずノートを受ける必要がある。

- **音色はプログラムチェンジで決まる**。`ch<チャンネル>p` のチャンネルでそのチャンネルの GM 音色を
  切り替える(TouchDesigner は GM の慣習どおり**1始まり**で出すので 69 = Oboe)。これがあると
  1台のマルチティンバー音源で、多トラックの MIDI ファイルを本来の楽器編成のまま鳴らせる
- **`Sound Bank` が要る**: AUMIDISynth はバンクを読ませないとプログラムチェンジを無視する —
  実測で**全プログラムの波形が完全に一致**した。既定は macOS 同梱の
  `/System/Library/.../gs_instruments.dls`。読ませると音色がはっきり変わる
  (ピアノ rms 0.022 / ヴァイオリン 0.058 / オーボエ 0.072)。DLSMusicDevice はバンク無しでも
  音色は変わるが **TouchDesigner 内では無音**なので、**AUMIDISynth + 既定バンク**が正解

### AU Instrument でノートを鳴らす

- **入力0にノートの CHOP** を繋ぐ。チャンネル名は `ch<チャンネル>n<ノート番号>`
  (**CoreMIDI In CHOP の出力そのまま**)か `note<ノート番号>`。値がベロシティで、
  **0 より大きくなったらノートオン / 0 に戻ったらノートオフ**。0〜1 でも生の MIDI 値(1〜127)でも受ける
- 入力が無くても **Play ページ**の `Note` / `Velocity` / `MIDI Channel` と
  `Note On` / `Note Off` / `All Notes Off` で鳴らせる(動作確認用)
- Info CHOP に `notes_sent` / `notes_held` を出す。鳴らないときはまずここを見る
- **`Active` を切るとその場で全ノートオフ**する(音が残らない)

**実測(M2)**: AUMIDISynth に Note On で peak 0.217、`ch1n64`+`ch1n67` を同時に鳴らして 0.559、
値を 0 に戻すと `notes_held` が 0 に。cook 0.138ms。
**DLSMusicDevice は TouchDesigner 内では無音**だった(単体プロセスでは 0.117 出るので、
このプラグインが既定のサウンドバンクをこの文脈で読めていないと思われる)。
音が出ないときは **AUMIDISynth や AUSampler、サードパーティの楽器で確かめる**

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
- **Learn**: GUI でつまみを触るとその場でパネルに出る。MIDI・キーフレーム・式から動かせる。
  割り当てはプラグインごとに覚える

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
| Learn | パラメータを触ると `learn1` に割り当て。スライダ 0 / 0.25 / 0.5 / 1 → `WetDry_Mix` 0 / 25 / 50 / 100。入力CHOP の `learn1` でも同じ。別プラグインへ切り替えて戻しても割り当てが復元 |
| 双方向同期 | Learn を On のまま: AU 側が動く → 枠が追従(`Delay` 1.6 → 0.003・15.5 → 0.031)。枠を動かす → AU が追従(0.0 / 0.4 / 1.0 → 0.1 / 200.06 / 500) |
| 表示曲線 | AUPeakLimiter で枠 0.7 → `Attack Time` 0.0087837 = 対数位置ちょうど 0.700(線形なら 0.281)。`Pre-Gain` 0.7 → 16(線形) |

### 入力

| 入力 | 内容 |
|---|---|
| 0 | 音声(必須)。モノならステレオに複製する |
| 1 | パラメータ自動化(任意)。動かしたいパラメータごとに1チャンネル |

出力は常に**ステレオ**(`left` / `right`)。

### Learn(どのパラメータをパネルに載せるか)

TouchDesigner の Audio VST CHOP には **Learn Parameters**(プラグインのパラメータを TD の
パラメータとして生やす)がある。C++ Custom OP にはできない — `setupParameters` は
インスタンスにつき**1回きり**しか呼ばれず(実測)、Python からも足せない
(`appendCustomPage` は COMP にはあるが CHOP には無い・実測)。**Script CHOP なら生やせる**ので、
コントロールはそちらに置く。

1. **Learn Parameters** を On にする — パネルが無ければこのとき自動で作られる
2. GUI を開いて、使いたいつまみを触る。**触った瞬間にパネルへ出る**

3つ目の手順は無い。learn した時点でパネルが作り直される。**Create / Rebuild Panel** は
パネルを消してしまったときに作り直すためだけにある。learn は**音が流れていなくても動く**
(入力0に信号が無くても、この op のパラメータ側は動く)。

Learn を Off にして再度 On にしても、既にあるパネルは作り直されない。パネルは**この op の
真下にビューアを開いた状態**で置かれ、パネルが使う2つの DAT(callbacks とパラメータ表)は
**ホストに閉じたチップとしてドック**される。チップをクリックすれば開く。

**op の cook 中にパネルへ書き込まない。** パネルは入力1に繋がる*上流*なので、
op が cook している最中にパネルのパラメータを触ると **Cook dependency loop** になる。
作り直しは1フレーム遅らせている。同じ理由で、パネルのスクリプトは**自分自身に `store()` しない**
(パースのキャッシュはモジュール変数の辞書に置いている)。

**パネルはこの op を一切読まない。** パネルは入力1へ繋がる*上流*なので、そこから op の
Info DAT を読むと TouchDesigner が **Cook dependency loop** を報告する。代わりに op が
`storage` でパラメータの仕様を渡し、変わった値をパネルのパラメータへ押し込む。
Info DAT は人が中身を確認するためだけに置いてある。

**選択はプラグインごとに** `Learned Mapping` パラメータへ保存され、.toe と一緒に残る。
別のプラグインへ切り替えて戻すと、そのプラグイン用の選択が戻る。今どれが選ばれているかは
Info DAT の `learn` 列で分かる。

### MIDI コンから動かす

コントローラは**パネルの入力**へ繋ぎ、チャンネル名をパラメータ名に合わせる:

```
MIDI In CHOP  →  Rename CHOP（"ch1c74" → "Low_Frequency"）  →  パネル Script CHOP の入力0
```

入ってきた値は **0〜1 として読まれ、そのパラメータ自身の表示曲線に沿って引き伸ばされる**ので、
素の CC がプラグインの GUI と同じ振れ方をする。`Low Frequency`(10〜21829.5 Hz・対数)での実測:
0.25 → 68.35 Hz、0.5 → 467.22 Hz、0.75 → 3193.6 Hz、1.0 → 21829.5 Hz — 対数位置で
0.250 / 0.500 / 0.750 / 1.000。動かしている間、パネルのコントロールには実値が表示される。

### パラメータの動かし方

Info DAT を繋ぐとパラメータ表が出る(`index` / `channel` / `name` / `min` / `max` / `value` /
`unit`)。**`channel` 列がそのまま使うチャンネル名**。例えば AUDistortion なら
`Delay` `Decay` `Delay_Mix` `Ring_Mod_Freq_1` … `WetDry_Mix`。割り当て済みの枠は
`learn1` `learn2` … でも指せる。

`Input Range` は**入力1に来る数値の意味**。**Normalized**(既定)は 0〜1 を**つまみ位置**として
扱い、そのパラメータの表示曲線に沿って引き伸ばす。**Raw** はそのパラメータ自身の単位
(Hz・ms・dB)として受け取り min〜max にクランプする。**生成されるパネルもこの設定に追従する** —
切り替えるとパネルが作り直され、値も換算されるので飛ばない。`Delay_Mix` が 75.7% なら
Normalized で `0.757`、Raw で `75.7`(範囲 0〜100)。`Ring Mod Freq 1` が 1000Hz なら
Raw で `1000`(範囲 0.5〜8000)、Normalized で `0.7852`(対数カーブ上の位置)。
どちらでもプラグイン側の値は動かない。

チャンネル名は識別子ではなく**表示名**から作っている。Apple の AU には識別子が `"0"` `"1"` `"2"` と
数字だけのものがあり、それだと添え字別名 `p<index>` と衝突するため(実測で発覚)。位置で指したい
場合は `p0` `p1` … も使える。

パラメータは**値が変わったときだけ**書き込む。自動化していないパラメータはプラグインの GUI や
プリセットが持ち主のままになる。

### プラグインの GUI とこの op の同期について

Apple 純正の AU は **v2** のユニットを AUv3 のブリッジで包んだもので、**両者は片方向にしか
同期しない**。実測:

| | 結果 |
|---|---|
| `AUParameter.value` に書く → v2 側を読む | **同期する**(だから音が変わる) |
| GUI でつまみを動かす(v2 側に書かれる)→ `AUParameter.value` を読む | **同期しない**。古い値のまま |
| GUI でつまみを動かす → パラメータオブザーバ | **発火しない** |
| `AUParameter.value` に書く → GUI と同じ `AUEventListener` | **通知0回**。GUI は描き直さない |
| 同じ書き込み + `AUEventListenerNotify` | **届く**。GUI が追従する |

そのためこの op は **v2 側を読み**(`AudioUnitGetParameter`)、**書いたら必ずイベントを飛ばす**。
Learn もオブザーバではなく **v2 側の値のポーリング**で検出している。プラグイン自身のウインドウで
つまみを回したときに拾えるのはこのため。

もう1つの罠: **`AUParameter.address` は v2 のパラメータID そのもの**(6プラグインで検証し、
address で `ParameterInfo` を引くと名前が100%一致)。**危ないのは
`kAudioUnitProperty_ParameterList` を並び順で v3 のツリーと突き合わせること** —
**両者の並びは違う**(AUDistortion は16個中11個、AUMatrixReverb は17個中11個がずれ)。
添え字で対応づけると**書く先と読む先が食い違い、値が動かなくなる**。

### パラメータの型どおりのパネル

`Create / Rebuild Panel` を押すと、隣に **Script CHOP** が生成されて入力1へ配線される。
パラメータ表を読んで、**learn 済みパラメータごとに型どおりのコントロール**を生やす —
プラグイン自身の選択肢名が入ったプルダウン、トグル、整数、そして Float。**Float は常に
0〜1 のつまみ位置**なので、プラグインのウインドウでつまみが半分なら、単位や曲線に関わらず
ここでも 0.5 になる。実値(Hz・ms・dB)は Info DAT の `value` 列で見る。AUPeakLimiter での実測:
GUI で中央の `Pre-Gain` はちょうど 0.5000、`Attack Time` は 0.002 秒(対数 0.0005〜0.03)で 0.3386。
実測(エフェクト24個)では 189個がスライダー向き・**24個が Indexed(プルダウン)**・
**18個が Boolean(トグル)**なので、0〜1 のスライダーだけでは情報がかなり落ちる。

op 自身は実行中にパラメータを増やせないが、**Script CHOP なら増やせる** —
`onSetupParameters` で `Float` / `Int` / `Menu` / `Toggle` をいつでも append でき、
learn の内容が変わると自分で作り直す。

パネルは**プラグイン自身の GUI と双方向**。プラグインのつまみを回せばパネルが追従し、
パネルを動かせばプラグインが追従する。実測: パネル 400 / 5000 Hz → プラグインも 400 / 5000
(厳密一致)、プルダウン → `High Pass`、ゲイン → −12 dB。逆にプラグイン側を動かすと
パネルが 10 Hz / 21829.5 Hz へ追従した。2つ合わせた定常負荷は **1フレーム 0.45 ms**。

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
| Learn Parameters / Clear Learned / Learned Mapping | どのパラメータをパネルに載せるか |
| Create / Rebuild Panel | 上記のパネル(Script CHOP)を生成する |

### 注意

- **エフェクト専用**(`aufx`)。インストゥルメント(`aumu`)と Music Effect(`aumf`)は MIDI 入力が
  要るため未対応。将来 [CoreMIDI In](../CoreMIDI/) と組み合わせる想定
- 読み込み方はそのコンポーネントの既定に任せているので、v3 のアプリ拡張型プラグインは
  **別プロセスで動く**。そちらが落ちても TouchDesigner は巻き込まれない
- **TD は実行中にパラメータを増やせない。** `setupParameters` はインスタンスにつき**1回きり**しか
  呼ばれない(実測)。Python からも足せない
  (`appendCustomPage` は COMP にはあるが CHOP には無い・実測)。だからコントロールは
  **生成した Script CHOP** に置いている(こちらは増やせる)。learn できるのは **128個**まで。
  超えると警告が出るので **Clear Learned** でやり直す(上限は `kLearnSlots` の1行)
- この op は下流から要求されたときだけ cook する。GUI が出ないときは、まず**cook されているか**を疑う

### ビルド

```bash
cd AudioUnit && ./build.sh   # → build/AudioUnitCHOP.plugin
```
