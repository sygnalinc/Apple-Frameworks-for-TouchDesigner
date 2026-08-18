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
- **Learn**: touch a knob in the GUI to bind it to one of 16 slots — drive them from MIDI, keyframes
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
2. Open the GUI and touch the knobs you want — each one is marked as learned
3. Press **Create / Rebuild Panel** to put them on the panel

Turning Learn off and on again does not disturb an existing panel. The two DATs the panel needs
(its callbacks and the parameter table) are **docked to their host as closed chips**, so they stay
out of the way — click the chip to open one.

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

`Input Range` decides how the incoming value is read: **Normalized** (default) treats 0–1 as the
parameter's full range, **Raw** writes the value as it is.

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

One more trap: **`AUParameter.address` is not the v2 parameter ID** (measured: v2 id 3 maps to
address 10). The two lists line up by position, not by value.

### A panel with the right controls for each parameter

`Create / Rebuild Panel` generates a **Script CHOP** beside the node and wires it into input 1. It
reads the parameter table and grows a **properly typed control for each learned parameter** — a
menu with the plugin's own choice names, a toggle, an integer, or a float with the real range and
units. Measured across the 24 installed effects: 189 parameters want a slider, **24 are indexed
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
| Always On Top | Floating window vs a normal one (default off) |
| Reset Plugin State | Clears the AU's internal state (reverb tails etc.) |
| Load / Save Plugin State, Plugin State | See above |
| Learn Parameters / Clear Learned / Learned Mapping | Which parameters go on the panel |
| Create / Rebuild Panel | Generates the Script CHOP panel described above |

### Notes

- **Effects only** (`aufx`). Instruments (`aumu`) and music effects (`aumf`) need MIDI input and are
  not handled yet — pair a future version with [CoreMIDI In](../CoreMIDI/)
- Plugins load with the system's default policy for that component, so v3 app-extension plugins run
  **out of process** and a crash there does not take TouchDesigner with it
- **TouchDesigner cannot grow parameters at runtime.** `setupParameters` is called exactly once per
  instance (measured), so the VST CHOP's "learn parameters" cannot be reproduced literally, and the
  slots cannot grow as you learn. Python cannot add them either — `appendCustomPage` exists on COMPs
  but not on a CHOP (measured). The 16 pre-declared slots, with the unassigned ones greyed out, are
  the equivalent here; raising the count is a one-line change to `kLearnSlots`
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
- **Learn**: GUI でつまみを触るとその場で16個の枠に割り当て。MIDI・キーフレーム・式から動かせる。
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
2. GUI を開いて、使いたいつまみを触る。触ったものが対象として記録される
3. **Create / Rebuild Panel** を押してパネルに載せる

Learn を Off にして再度 On にしても、既にあるパネルは作り直されない。パネルが使う2つの DAT
(callbacks とパラメータ表)は**ホストに閉じたチップとしてドック**されるので、ネットワークは
散らからない。チップをクリックすれば開く。

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

`Input Range` は入力値の読み方。**Normalized**(既定)は 0〜1 をそのパラメータの
フルレンジとして扱い、**Raw** はそのまま書く。

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

もう1つの罠: **`AUParameter.address` は v2 のパラメータIDではない**(実測: v2id=3 ↔ addr=10)。
2つの一覧は値ではなく**並び順**で対応する。

### パラメータの型どおりのパネル

`Create / Rebuild Panel` を押すと、隣に **Script CHOP** が生成されて入力1へ配線される。
パラメータ表を読んで、**learn 済みパラメータごとに型どおりのコントロール**を生やす —
プラグイン自身の選択肢名が入ったプルダウン、トグル、整数、実単位・実レンジのスライダー。
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
| Always On Top | 最前面に固定するか(既定 Off) |
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
  呼ばれない(実測)。そのため VST CHOP の「learn parms」をそのままの形では再現できず、
  **learn するたびに枠を増やすこともできない**。Python からも足せない
  (`appendCustomPage` は COMP にはあるが CHOP には無い・実測)。上の「Learn」で説明した
  **16個の枠**(未割り当てはグレー)がその代わり。数を増やすのは `kLearnSlots` の1行
- この op は下流から要求されたときだけ cook する。GUI が出ないときは、まず**cook されているか**を疑う

### ビルド

```bash
cd AudioUnit && ./build.sh   # → build/AudioUnitCHOP.plugin
```
