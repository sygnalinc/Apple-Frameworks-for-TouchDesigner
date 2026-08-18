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

### Learn (assigning parameters, like the VST CHOP)

TouchDesigner's Audio VST CHOP has **Learn Parameters**, which turns plugin parameters into real
TD parameters. That exact behaviour is impossible here: `setupParameters` is called **once per
instance** (measured), so a C++ Custom OP cannot grow parameters at runtime. What this operator
does instead is pre-declare **16 slots** and let you assign plugin parameters to them.

1. Turn **Learn Parameters** on
2. Open the GUI and touch the knobs you want — each one is assigned to the next free slot

That is all. `Learn 1` … `Learn 16` sit on the same page and drive those parameters. They are normal
TD parameters, so you can bind them, keyframe them, or drive them by expression. The Info DAT's
`learn` column shows which slot owns which parameter.

The slots are always **0–1**, stretched to each parameter's own `min`–`max`. That is what makes a
MIDI controller work without any scaling on your side.

**The two sides stay in sync, both ways, all the time** — including while Learn is still on:

- Move a knob in the plugin's GUI → the matching `Learn n` slot follows
- Move a `Learn n` slot → the plugin's GUI knob follows

Leaving Learn on simply means new knobs you touch keep getting assigned. Turning it off freezes the
assignments; the two-way sync carries on either way.

**Assignments are stored per plugin** in the `Learned Mapping` parameter, which saves with the
.toe. Switch to another plugin and back and your mapping returns.

Slots you have not assigned are **greyed out**, so the page reads as "these are the ones I learned"
and grows as you go. The count is fixed at 16 — see the note below on why it cannot grow at runtime.

**The slot follows the knob's own curve, not the raw value.** Audio Units declare how their GUI
sweeps a parameter, and many are logarithmic. AUPeakLimiter's `Attack Time` runs 0.0005–0.03 s on a
log scale: its knob at centre is 0.00387, which a plain linear normalization would report as
**0.114**, not 0.5. This operator reads that flag and applies the same curve, so the slot and the
GUI knob always agree. Measured across the 24 installed effects: 181 parameters linear,
41 logarithmic, 4 squared, 3 square-root, 1 cubed, 1 exponential.

### Driving from a MIDI controller

Wire a MIDI In CHOP (or [CoreMIDI In](../CoreMIDI/)) into input 1 and rename its channels to the
slot names:

```
MIDI In CHOP  →  Rename CHOP ("ch1c74 ch1c75" → "learn1 learn2")  →  AudioUnit CHOP input 1
```

Or skip the input entirely and bind the parameter directly:

```python
op('audiounit1').par.Learn1.expr = "op('midiin1')['ch1c74']"
```

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
| Learn Parameters / Clear Learned / Learned Mapping | See "Learn" above |
| Learn 1 … 16 | The assigned parameters, always 0–1. Two-way with the GUI |

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

### Learn(パラメータの割り当て。VST CHOP 相当)

TouchDesigner の Audio VST CHOP には **Learn Parameters**(プラグインのパラメータを TD の
パラメータとして生やす)がある。**同じことはできない** — `setupParameters` は
インスタンスにつき**1回きり**しか呼ばれず(実測)、C++ Custom OP は実行中にパラメータを
増やせない。そこでこの op は **16個の枠を先に用意**して、そこへ割り当てる形にした。

1. **Learn Parameters** を On
2. GUI を開いて、使いたいつまみを触る。触った順に空いている枠へ割り当てられる

これだけ。**同じページの `Learn 1` 〜 `Learn 16`** がそのパラメータを動かす。普通の TD
パラメータなので、バインドもキーフレームも式も使える。どの枠がどれを持っているかは
Info DAT の `learn` 列で分かる。

枠は常に **0〜1** で、各パラメータの `min`〜`max` へ引き伸ばされる。MIDI コンを
スケーリング無しでそのまま使えるのはこのため。

**両側は常に双方向で同期する。Learn を On にしたままでも同じ**:

- プラグインの GUI でつまみを動かす → 対応する `Learn n` の枠が追従する
- `Learn n` の枠を動かす → プラグインの GUI のつまみが追従する

Learn を On のままにしておくと、新しく触ったつまみが割り当てられ続ける、というだけの違い。
Off にすると割り当てが固定される。双方向の同期はどちらでも働く。

**割り当てはプラグインごとに** `Learned Mapping` パラメータへ保存され、.toe と一緒に残る。
別のプラグインへ切り替えて戻すと、そのプラグイン用の割り当てが戻る。

割り当てていない枠は**グレーアウト**するので、ページは「learn した分だけ」に見えて、
learn するたびに増えていく。枠の数は16固定(実行中に増やせない理由は下の注意を参照)。

**枠はつまみ自身の曲線に従う。生の値ではない。** Audio Unit は GUI がパラメータをどう振るかを
フラグで持っていて、対数のものが多い。AUPeakLimiter の `Attack Time` は 0.0005〜0.03 秒の
**対数**で、つまみ中央は 0.00387。素の線形正規化だとこれが **0.114** になってしまい 0.5 にならない。
この op はそのフラグを読んで同じ曲線を掛けるので、枠と GUI のつまみは常に一致する。
インストール済みエフェクト24個での実測: 線形181・**対数41**・Squared 4・SquareRoot 3・Cubed 1・Exponential 1。

### MIDI コンから動かす

MIDI In CHOP(または [CoreMIDI In](../CoreMIDI/))を入力1へ繋ぎ、チャンネル名を枠の名前に変える:

```
MIDI In CHOP  →  Rename CHOP（"ch1c74 ch1c75" → "learn1 learn2"）  →  AudioUnit CHOP 入力1
```

入力を使わず、パラメータへ直接バインドしてもよい:

```python
op('audiounit1').par.Learn1.expr = "op('midiin1')['ch1c74']"
```

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
| Learn Parameters / Clear Learned / Learned Mapping | 上記「Learn」 |
| Learn 1 〜 16 | 割り当てたパラメータ。常に 0〜1。GUI と双方向 |

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
