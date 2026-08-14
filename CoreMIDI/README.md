# CoreMIDI Out / In

**English** | [日本語](#日本語)

## English

Sends MIDI through Apple's CoreMIDI. This is **not** a replacement for TouchDesigner's own MIDI Out
CHOP — it exists for the three things TD's MIDI cannot do.

### Why this exists

TD's `libMIDI.dylib` uses only `MIDIClientCreate / MIDIInputPortCreate / MIDIOutputPortCreate /
MIDIGetSource / MIDIGetDestination / MIDIPacketListInit / MIDIPacketListAdd / MIDISend /
MIDIObjectGetStringProperty` with `kMIDIPropertyDisplayName`. That tells you exactly what it can't do:

| | TD's MIDI Out | CoreMIDI Out |
|---|---|---|
| Device list | **Snapshot taken at TD launch.** Devices plugged in later never appear; unplugged ones stay in the list and silently swallow everything you send | **Live.** Updates on CoreMIDI's setup-changed notification, no restart |
| Device identity | Display name only. Two identical units are indistinguishable, and the USB order decides which one you get | **UniqueID.** Re-resolved with `MIDIObjectFindByUniqueID`, so the same physical device is re-bound after a replug |
| Device metadata | none | manufacturer / model / online state in the Info DAT |

If you just need to send notes to a DAW that is already running, TD's built-in MIDI Out CHOP is fine
and better integrated. Reach for this one when devices come and go during a show.

### Sending without writing a script

Everything is on the **Send** page:

1. Pick the target in **Device**
2. Press **Send Note** — Note On, then Note Off after **Note Duration**
3. Press **Send CC**, or **All Notes Off** if something hangs

`connected`, `online` and `sends` on the output tell you whether it went out.

### Controlling a DAW's transport

**Play / Stop / Record / Return to Start** are on the same page. There are two ways a DAW can
listen, and which one works depends on its settings, so **Transport Method** defaults to `Both`:

| Method | What is sent |
|---|---|
| MMC (SysEx) | `F0 7F <MMC Device ID> 06 <cmd> F7` — Play `02`, Stop `01`, Record Strobe `06`, and Locate `44 06 01 00 00 00 00 00` for Return to Start |
| MIDI Realtime | Continue `FB`, Stop `FC`, and Song Position Pointer `F2 00 00` for Return to Start |

**In Logic Pro**, enable MMC input under Settings → MIDI → Sync, or slave Logic to MIDI Clock for
the realtime path. If your DAW reacts twice, switch Transport Method from `Both` to one of them.

`MMC Device ID` is 127 (all devices) by default, which is what most DAWs expect.

### Following TouchDesigner's timeline

Two ways to send position, because **which one a DAW understands is not a matter of preference**:

| Sync Mode | For |
|---|---|
| `MTC (MIDI Time Code)` | **Logic Pro.** Logic has no setting for receiving MIDI Clock — its Sync tab only exposes MTC on the receive side. Quarter frames at 4 × frame rate, plus a Full Frame message on start and after a jump |
| `MIDI Clock (24 PPQN)` | Ableton Live and hardware that slaves to MIDI clock |

**For Logic**, open Settings → MIDI → Sync → **「MIDI同期プロジェクト設定...」** and set 同期モード
to MTC. (The MMC *receive* setting lives in that same dialog — the MMC section on the Sync tab
itself is only about what Logic *transmits*.)

Two things in that dialog have to match, or Logic locks but never moves:

| Logic | This op |
|---|---|
| **SMPTE オフセット** (Logic's default is `01:00:00:00`) | **MTC Offset** — must be the same |
| **フレームレート** (Logic's default is `29.97`) | **MTC Frame Rate** |

The offset is the one that bites. Logic's bar 1 sits one hour in by default, so sending timecode
from `00:00:00:00` points an hour *before* the project — Logic chases, shows a negative bar and
appears frozen. `MTC Offset` defaults to `01:00:00:00` to match Logic out of the box.

With `MIDI Clock` the op sends 24 PPQN locked to TD's timeline:

- Timeline play/stop becomes Start `FA` / Continue `FB` / Stop `FC`
- Position is announced with Song Position Pointer, and re-announced when the timeline loops or
  is scrubbed
- **Tempo** is a plain parameter — bind it to the timeline with the expression `root.time.tempo`
  (the example does) and changing TD's tempo changes the clock

**Following the timeline and driving the transport by hand are different goals**, so **Sync Source**
picks which one runs the stream:

| Sync Source | Position comes from | Play / Stop / Return to Start |
|---|---|---|
| `TD Timeline` | TD's timeline | Sent as MMC / realtime. A DAW that is slaved to the sync stream will ignore them |
| `Manual` | This op, advancing on the real clock | **They run the stream itself** — Play starts it, Stop freezes it, Return to Start rewinds |

`Manual` is what you want when the DAW stays slaved but you need to start it at an arbitrary
moment: the DAW follows the stream, and the stream follows these buttons. It keeps running with
TD's timeline stopped.

With `MTC` it sends quarter frames carrying `hh:mm:ss:ff` derived from the timeline, at the frame
rate chosen in **MTC Frame Rate** (24 / 25 / 29.97 drop / 30).

**On accuracy.** Cook only happens at frame rate, so sending clock naively bunches every tick onto
frame boundaries. This op **schedules one frame ahead with CoreMIDI timestamps**
(`MIDIPacketListAdd` takes a per-packet host time), so the clock does not inherit the frame rate's
jitter. TD's own MIDI Out sends with timestamp 0 — immediate only — and cannot do this.

### Output channels

| Channel | Meaning |
|---|---|
| `connected` | 1 when the selected device resolved to a live endpoint |
| `online` | 1 when that device reports itself online |
| `sends` | Total MIDI messages sent since the node was created |

Info CHOP: `executes / sends / devices / connected / online / clock_running / clocks / beat`.
Info DAT: one row per destination — `uniqueid / name / manufacturer / model / online`.

### Input CHOP (optional)

Channels are mapped by name, and **only changes are sent** — nothing is streamed every frame.

| Channel name | Sends |
|---|---|
| `note<n>` | Note On when the value goes 0 → non-zero, Note Off on the way back. Values ≤ 1 are treated as 0–1 and scaled to velocity |
| `cc<n>` | Control Change when the value changes. Values ≤ 1 are treated as 0–1 |

### Parameters

| Parameter | Meaning |
|---|---|
| Active | Off stops all sending and clears pending Note Offs |
| Device | Destination, stored as its **UniqueID** so a replug re-binds to the same unit |
| Refresh Devices | Re-enumerate by hand (normally unnecessary — hot-plug is automatic) |
| Restart MIDI System | `MIDIRestart()` — ask the MIDI drivers to rescan for hardware |
| Channel | MIDI channel 1–16 |
| Note / Velocity / Note Duration | The note sent by Send Note |
| Send Note / Send CC / All Notes Off | Pulses |
| CC Number / CC Value | The CC sent by Send CC |
| Transport Method | `MMC (SysEx)` / `MIDI Realtime` / `Both` (default) |
| MMC Device ID | 0–127, default 127 (all devices) |
| Play / Stop / Record / Return to Start | DAW transport pulses |
| Sync Mode | `Off` (default) / `MIDI Clock (24 PPQN)` / `MTC (MIDI Time Code)` |
| Sync Source | `TD Timeline` (default) / `Manual (transport buttons)` |
| MTC Frame Rate | 24 / 25 / 29.97 drop / 30 (MTC only). Match the DAW |
| MTC Offset (hh:mm:ss:ff) | The DAW's project start. Default `01:00:00:00` (Logic's default) |
| Tempo (BPM) | Clock tempo. Bind to `root.time.tempo` to follow the timeline |
| Send Song Position | Announce the position on start and after a jump (default on) |

### Notes

- **The MIDI client lives on a dedicated thread with a run loop** (CoreMIDI delivers setup-change
  notifications to the run loop of the thread that created the client, and the cook thread has
  none). `CFRunLoopGetCurrent()` returns an **unowned** reference: if that thread exits first, the
  run loop is deallocated and the destructor's `CFRunLoopStop` trips
  `__CFCheckCFInfoPACSignature` (SIGTRAP) — this crashed TouchDesigner on every quit until the
  reference was retained and released after `join()`

- This op **cooks every frame whether or not its output is used**, and keeps cooking when the
  timeline is stopped. A MIDI sink that only runs when someone looks at it is useless — pulses,
  automatic Note Offs and the sync stream all need cook.
- Notes are MIDI 1.0. MIDI 2.0 (UMP) is not implemented yet.
- **Logic Pro publishes its own virtual input while it is running**, so you do not need the IAC
  Driver to send to it. The name is localised.

### Measured (M2 / macOS 26.6)

- Device menu lists destinations by UniqueID, so several endpoints sharing the display name
  `TD MIDI Test` were still individually selectable
- `Send Note` produced `20903C64` (note 60, velocity 100) and the matching Note Off; `Send CC`
  produced `20B04A40` (CC 74 = 64), verified on a virtual MIDI destination
- **Hot-unplug**: killing the receiving endpoint removed it from the menu and dropped `connected`
  and `online` to 0 **without restarting TD**
- **Hot-plug**: a newly created endpoint appeared in the menu, was selectable, and received a note
  — again with no restart
- **Transport**: Play produced MMC `7F 7F 06 02` plus realtime `FB`; Stop produced `7F 7F 06 01`
  plus `FC`; Record produced `7F 7F 06 06`; Return to Start produced the Locate SysEx plus
  Song Position `0,0`
- **Clock**: 120 BPM for 5 s produced 245 ticks (240 in theory) and 90 BPM for 6 s produced 217
  (216 in theory); stopping the timeline produced 0 ticks and a `FC`. Looping the timeline
  re-announced the position, as intended
- **MTC**: 30 fps for 5 s produced 608 quarter frames (600 in theory), cycling pieces 0–7 with
  rate code 3 (30 fps) and a timecode of `00:00:03:06` matching the timeline
- **MTC Offset**: with `01:00:00:00` and 29.97 drop, the reconstructed timecode was `01:00:06:00`
  with rate code 2 — offset and rate both land where Logic expects them
- **Manual sync source**: with the TD timeline stopped and nothing pulling the output, Play produced
  366 quarter frames in 3 s (360 in theory) and the timecode advanced `01:00:03:00` → `:08`; Stop
  halted it completely (0 in 3 s); Return to Start rewound to `01:00:00:24`


## CoreMIDI In

Receives everything a controller or DAW sends: **keys, pads, knobs, wheels** and **sync**.

1. **Channels appear as you play.** Touch a key and `ch1n60` exists; turn a knob and `ch1c21`
   exists. TD's own MIDI In CHOP makes you list the note numbers and controller indices you want up
   front — here you just play. Names follow TD's format (`ch1n60`, `ch1c74`) so a patch built
   against one can be pointed at the other
2. **Turn MIDI Clock into a tempo.** TD shows clock messages but never gives you a BPM. Make the DAW
   the tempo master and follow it in TD. **MTC carries no tempo**, so this is the only path for
   tempo sync
3. **Receive MTC.** TD has no MTC support at all

Device selection is by **UniqueID** with hot-plug, exactly like CoreMIDI Out.

### Keys, pads and knobs

Every note, controller, bend and aftertouch that arrives becomes its own channel, named the same way
TD names them:

| Channel | Message |
|---|---|
| `ch1n60` | Note 60 on MIDI channel 1 — velocity while held, 0 on release |
| `ch1c74` | Controller 74 |
| `ch1bend` | Pitch bend, −1 to 1 |
| `ch1press` | Channel pressure |
| `ch1p60` | Polyphonic aftertouch for note 60 |
| `ch1prog` | Program number (always raw, never normalized) |

Turn off the message types you do not want — fewer channels, less to wire. **Notes As Gate** gives 1
while a key is held instead of its velocity. **Normalize To 0-1** off gives raw 0–127. **Reset
Channels** forgets everything discovered so far, which is how you get rid of channels from a device
you no longer use. A cap of 512 discovered channels keeps a misbehaving device from filling the CHOP.

Measured with a Novation Launchkey Mini MK4 37: playing the keys, hitting the pads and sweeping the
knobs produced **101 channels** — `ch10n36`–`n51` for the 16 pads with velocity, `ch10p36`–`p51`
for their aftertouch, `ch14n36`–`n101` for the keyboard, `ch14c21`–`c28` for the eight knobs, plus
`ch14c1` (modulation) and `ch14bend`. The MIDI channel numbers come straight from the device, so
check the controller's own settings if they are not what you expect.

### If a device does not appear in the Device menu

Hot-plug is verified: with the op present, unplugging and replugging a Launchkey Mini MK4 took the
device count 2 → 0 → 2 on its own, and a node created afterwards saw it immediately.

One case was seen where a device that other applications could enumerate did **not** appear inside
TouchDesigner — the count stayed at 0 even after **Refresh Devices**, and TD's own
`/local/midi/midi_inputs` was empty too. Restarting TouchDesigner fixed it, and the same sequence
could not be reproduced afterwards. If you hit it, in order of increasing disruption:

1. **Refresh Devices** — re-enumerates
2. **Restart MIDI System** — calls `MIDIRestart()`, which asks the MIDI drivers to rescan for
   hardware. Verified not to disturb a working setup (2 devices before and after, no errors); it
   has **not** been verified against the failure above, because the failure did not recur
3. Restart TouchDesigner — this is what actually fixed it the one time it happened

The op also re-enumerates on its own about every two seconds, so a missed notification heals itself.

### Output channels

| Channel | Meaning |
|---|---|
| `connected` / `online` | The selected source resolved / reports itself online |
| `playing` | 1 between Start/Continue and Stop. Also falls back to 0 if clock stops arriving for 0.5 s |
| `bpm` | Derived from the interval between clock ticks (24 PPQN) |
| `beat` | Quarter notes since the last Start, or since the last Song Position Pointer |
| `bar` | `beat / Beats Per Bar` |
| `tc_hours` `tc_minutes` `tc_seconds` `tc_frames` | Incoming MTC |
| `tc_position` | The same timecode in seconds |
| `tc_valid` | 1 once a full timecode has been assembled |

### Parameters

| Parameter | Meaning |
|---|---|
| Device | Source, stored as its **UniqueID** |
| Refresh Devices | Re-enumerate by hand (hot-plug is automatic) |
| Restart MIDI System | `MIDIRestart()` — see "If a device does not appear" above |
| Notes / Controllers (CC) / Pitch Bend / Aftertouch / Program Change | Which message types become channels |
| Notes As Gate | 1 while held instead of velocity |
| Normalize To 0-1 | Off gives raw 0–127 |
| Reset Channels | Forget every discovered channel |
| Beats Per Bar | Divisor for `bar` |
| BPM Smoothing (clocks) | How many clock ticks to average. Smaller follows faster, larger is steadier. Default 24 = one beat |

### Measured (M2 / macOS 26.6)

Against a virtual source emitting clock and MTC at a known tempo:

- 128 BPM source → `bpm` 127.39; 90 BPM source → `bpm` 89.9 / 89.4 (the residual is the test
  sender's own timer jitter)
- `beat` advanced 59.125 → 64.417 in 3.53 s — 5.29 quarter notes against 5.3 expected at 90 BPM
- MTC assembled to `tc_valid` = 1 with `00:00:18:06` → `00:00:21:22`, and `tc_position`
  18.200 → 21.733 matching real elapsed time
- Killing the source dropped `playing`, `connected` and `online` to 0 without restarting TD

## Build

```bash
cd CoreMIDI && ./build.sh          # Out と In の両方が build/ にできる
cp -R build/CoreMIDIOutCHOP.plugin ~/Library/Application\ Support/Derivative/TouchDesigner099/Plugins/
```

---

## 日本語

Apple の CoreMIDI で MIDI を送る。**TouchDesigner 標準の MIDI Out CHOP の置き換えではない** —
TD の MIDI にできない3点のためにある。

### 何のためにあるか

TD の `libMIDI.dylib` が使っているのは `MIDIClientCreate / MIDIInputPortCreate /
MIDIOutputPortCreate / MIDIGetSource / MIDIGetDestination / MIDIPacketListInit /
MIDIPacketListAdd / MIDISend / MIDIObjectGetStringProperty`(+ `kMIDIPropertyDisplayName`)だけ。
ここから何ができないかがそのまま分かる。

| | TD の MIDI Out | CoreMIDI Out |
|---|---|---|
| デバイス一覧 | **TD 起動時のスナップショット。** 後から挿した機材は現れず、抜いた機材は一覧に残って送信を黙って飲み込む | **常に最新。** CoreMIDI の setup 変更通知で更新。再起動不要 |
| デバイスの識別 | 表示名のみ。同型機を区別できず、USB の挿し順で相手が変わる | **UniqueID。** `MIDIObjectFindByUniqueID` で引き直すので、挿し直しても同じ実機に繋ぎ直る |
| 機材の素性 | 取れない | 製造元 / モデル / オンライン状態を Info DAT に出す |

**起動済みの DAW にノートを送るだけなら TD 標準で十分**で、そちらの方が統合されている。
本番中に機材が抜き差しされる用途でこちらを使う。

### スクリプトを書かずに送る

必要なものは全部 **Send** ページにある。

1. **Device** で送り先を選ぶ
2. **Send Note** を押す → Note On が出て、**Note Duration** 後に Note Off が出る
3. **Send CC**、音が残ったら **All Notes Off**

実際に出たかどうかは出力の `connected` / `online` / `sends` で分かる。

### DAW のトランスポートを操作する

同じページに **Play / Stop / Record / Return to Start** がある。DAW が聞く経路は2種類あり、
どちらが有効かは DAW の設定次第なので、**Transport Method** の既定は `Both`(両方送る)。

| 方式 | 送るもの |
|---|---|
| MMC (SysEx) | `F0 7F <MMC Device ID> 06 <cmd> F7` — Play `02` / Stop `01` / Record Strobe `06`、Return to Start は Locate `44 06 01 00 00 00 00 00` |
| MIDI Realtime | Continue `FB` / Stop `FC`、Return to Start は Song Position Pointer `F2 00 00` |

**Logic Pro なら**、設定 > MIDI > 同期 で MMC の受信を有効にする(リアルタイム側を使うなら
Logic を MIDI クロックに同期させる)。二重に反応する DAW では `Both` から片方に絞る。

`MMC Device ID` の既定は 127(全デバイス宛)で、たいていの DAW はこれで反応する。

### TouchDesigner のタイムラインに追従させる

送り方が2つあるのは、**どちらを理解するかが DAW 側で決まっていて選べない**ため。

| Sync Mode | 用途 |
|---|---|
| `MTC (MIDI Time Code)` | **Logic Pro。** Logic には MIDI クロックを受信する設定が無く、同期タブの受信側は MTC しか無い。クォーターフレームを 4×フレームレートで送り、開始時と位置が飛んだときに Full Frame メッセージを送る |
| `MIDI Clock (24 PPQN)` | Ableton Live など、MIDI クロックに同期する DAW / 機材 |

**Logic の設定**: 設定 > MIDI > 同期 の **「MIDI同期プロジェクト設定...」**を開き、同期モードを
MTC にする(MMC の**受信**設定も同じダイアログ内。同期タブに見えている MMC 欄は Logic が
**送信**する側の設定)。

そのダイアログの2つを合わせないと、**Logic はロックするのに進まない**:

| Logic | このOP |
|---|---|
| **SMPTE オフセット**(既定 `01:00:00:00`) | **MTC Offset** — 同じ値にする |
| **フレームレート**(既定 `29.97`) | **MTC Frame Rate** |

引っかかるのはオフセット。**Logic の1小節目は既定で1時間の位置**にあるので、`00:00:00:00` から
送るとプロジェクト開始の1時間前を指してしまい、Logic は追従しようとして負の小節に張り付き、
止まって見える。`MTC Offset` の既定は Logic に合わせて `01:00:00:00` にしてある。

`MIDI Clock` にすると、TD のタイムラインに同期した 24 PPQN のクロックを送る。

- タイムラインの再生/停止がそのまま Start `FA` / Continue `FB` / Stop `FC` になる
- 再生位置は Song Position Pointer で伝え、ループやスクラブで飛んだら貼り直す
- **Tempo** はただのパラメータなので、式で `root.time.tempo` に束ねるとタイムラインのテンポに
  追従する(利用例はそうしてある)

**タイムラインに追従させることと、任意のタイミングでトランスポートを操作することは別の目的**
なので、**Sync Source** でどちらがストリームを駆動するかを選ぶ。

| Sync Source | 位置の出どころ | Play / Stop / Return to Start |
|---|---|---|
| `TD Timeline` | TD のタイムライン | MMC / リアルタイムとして送る。同期に従っている DAW はこれを無視する |
| `Manual` | このOP(実時計で進む) | **ストリームそのものを制御する** — Play で走り出し、Stop で止まり、Return to Start で頭出し |

**DAW を同期モードにしたまま、任意のタイミングで走らせたいときは `Manual`。** DAW はストリームに
従い、ストリームはこのボタンに従う。**TD のタイムラインを止めていても動く。**

`MTC` にすると、タイムラインから作った `hh:mm:ss:ff` をクォーターフレームで送る。
フレームレートは **MTC Frame Rate**(24 / 25 / 29.97 drop / 30)で選ぶ。

**精度について。** cook はフレームレートでしか回らないので、素直に送るとクロックがフレーム境界に
固まる。このOPは **CoreMIDI のタイムスタンプ付き送信で1フレームぶん先まで予約する**
(`MIDIPacketListAdd` はパケットごとにホスト時刻を持てる)ため、フレームレートのジッタを引き継がない。
TD 標準の MIDI Out は timestamp 0 = 即時送信しかできないのでこれができない。

### 出力チャンネル

| チャンネル | 意味 |
|---|---|
| `connected` | 選択中のデバイスが生きたエンドポイントとして解決できていれば1 |
| `online` | そのデバイスがオンラインを申告していれば1 |
| `sends` | ノード生成からの累計送信数 |

Info CHOP: `executes / sends / devices / connected / online / clock_running / clocks / beat`。
Info DAT: 送り先1件=1行で `uniqueid / name / manufacturer / model / online`。

### 入力CHOP(任意)

チャンネル名で対応づけ、**変化したときだけ送る**(毎フレーム垂れ流さない)。

| チャンネル名 | 送るもの |
|---|---|
| `note<n>` | 0→非0 で Note On、戻りで Note Off。1以下の値は 0〜1 とみなして velocity に換算 |
| `cc<n>` | 値が変わったら Control Change。1以下の値は 0〜1 とみなす |

### パラメータ

| パラメータ | 意味 |
|---|---|
| Active | Off で送信を止め、保留中の Note Off も破棄する |
| Device | 送り先。**UniqueID で保持**するので挿し直しても同じ機材に繋ぎ直る |
| Refresh Devices | 手動で再列挙(通常は不要。ホットプラグは自動) |
| Restart MIDI System | `MIDIRestart()`。MIDI ドライバにハードウェアを再スキャンさせる |
| Channel | MIDI チャンネル 1〜16 |
| Note / Velocity / Note Duration | Send Note で送るノート |
| Send Note / Send CC / All Notes Off | パルス |
| CC Number / CC Value | Send CC で送る CC |
| Transport Method | `MMC (SysEx)` / `MIDI Realtime` / `Both`(既定) |
| MMC Device ID | 0〜127。既定 127(全デバイス宛) |
| Play / Stop / Record / Return to Start | DAW のトランスポート操作 |
| Sync Mode | `Off`(既定)/ `MIDI Clock (24 PPQN)` / `MTC (MIDI Time Code)` |
| Sync Source | `TD Timeline`(既定)/ `Manual (transport buttons)` |
| MTC Frame Rate | 24 / 25 / 29.97 drop / 30(MTC のみ)。DAW に合わせる |
| MTC Offset (hh:mm:ss:ff) | DAW のプロジェクト開始位置。既定 `01:00:00:00`(Logic の既定) |
| Tempo (BPM) | クロックのテンポ。`root.time.tempo` に束ねるとタイムラインに追従 |
| Send Song Position | 開始時と位置が飛んだときに再生位置を伝える(既定On) |

### 注意

- **MIDI クライアントはランループ常駐の専用スレッドで作る**(CoreMIDI の setup 変更通知は
  クライアントを作ったスレッドのランループへ届き、cook スレッドにはランループが無いため)。
  `CFRunLoopGetCurrent()` は**所有権を持たない参照**で、スレッドが先に抜けるとランループごと
  解放される。デストラクタで `CFRunLoopStop` するとその解放済みオブジェクトを触り
  `__CFCheckCFInfoPACSignature`(SIGTRAP)で落ちる — **TD 終了のたびにクラッシュしていた**。
  CFRetain して `join()` の後に解放すること

- このOPは**出力が使われていなくても毎フレーム cook する**。タイムラインを止めていても動く。
  パルスも自動 Note Off も同期ストリームも cook が要るので、見られていないと動かない
  MIDI 出力では困るため
- 送信は MIDI 1.0。MIDI 2.0 (UMP) は未実装
- **Logic Pro は起動していれば自前の仮想入力を公開する**ので、送るのに IAC ドライバは要らない。
  名前は言語設定で変わる

### 実測(M2 / macOS 26.6)

- Device メニューは UniqueID で列挙するので、表示名が同じ `TD MIDI Test` が複数あっても
  それぞれ個別に選べた
- `Send Note` で `20903C64`(note 60 / velocity 100)と対の Note Off、`Send CC` で
  `20B04A40`(CC 74 = 64)を仮想 MIDI デスティネーションで受信して確認
- **抜いたとき**: 受信側を落とすとメニューから消え、`connected` と `online` が 0 になった。
  **TD の再起動なし**
- **挿したとき**: 新しく作ったエンドポイントがメニューに現れ、選択して送信できた。こちらも再起動なし
- **トランスポート**: Play で MMC `7F 7F 06 02` とリアルタイム `FB`、Stop で `7F 7F 06 01` と
  `FC`、Record で `7F 7F 06 06`、Return to Start で Locate SysEx と Song Position `0,0` を確認
- **クロック**: 120BPM 5秒で 245個(理論240)、90BPM 6秒で 217個(理論216)、タイムライン停止で
  0個 + `FC`。タイムラインがループしたときは位置を貼り直すことも確認
- **MTC**: 30fps 5秒で 608個(理論600)。piece 0〜7 が巡回し、レートコード 3(30fps)、
  タイムコード `00:00:03:06` がタイムライン位置と一致することを確認
- **MTC Offset**: `01:00:00:00` + 29.97 drop で、復元したタイムコードが `01:00:06:00`・
  レートコード2。オフセットもレートも Logic が期待する値になることを確認
- **Sync Source = Manual**: TD のタイムラインを止め、出力を誰も参照していない状態で Play →
  3秒で 366個(理論360)、タイムコードは `01:00:03:00` → `:08` と実時間で進行。Stop で完全停止
  (3秒で0個)、Return to Start で `01:00:00:24` へ頭出し


## CoreMIDI In

DAW / 機材から**同期情報**を受け取る。ノートや CC はここでは扱わない(TD 標準の MIDI In CHOP で
足りる)。このOPがあるのは、TD にできない次の2つのため。

1. **MIDI Clock からテンポを出す。** TD は clock メッセージを見せるだけで BPM にはしてくれない。
   DAW をテンポマスターにして TD を追従させられる。**MTC はテンポを運ばない**ので、
   テンポ同期はこの経路でしか成立しない
2. **MTC を受ける。** TD は MTC に一切対応していない

デバイスの選択は CoreMIDI Out と同じく **UniqueID**、ホットプラグも反映する。

### 鍵盤・パッド・ノブ

届いたノート / コントローラ / ベンド / アフタータッチが、そのままチャンネルになる。名前は TD と
同じ書式:

| チャンネル | メッセージ |
|---|---|
| `ch1n60` | MIDI チャンネル 1 のノート 60。押している間はベロシティ、離すと 0 |
| `ch1c74` | コントローラ 74 |
| `ch1bend` | ピッチベンド。−1〜1 |
| `ch1press` | チャンネルプレッシャー |
| `ch1p60` | ノート 60 のポリフォニックアフタータッチ |
| `ch1prog` | プログラム番号(常に生値。正規化しない) |

要らないメッセージ種別は切る。チャンネルが減って配線が楽になる。**Notes As Gate** は押している間 1
(ベロシティではなく)。**Normalize To 0-1** を切ると 0〜127 の生値。**Reset Channels** は
それまでに見つけたチャンネルを忘れる(使わなくなった機材のチャンネルを消すのに使う)。
上限は 512 チャンネルで、暴れる機材で CHOP が埋まらないようにしてある。

Novation Launchkey Mini MK4 37 で実測: 鍵盤を弾き、パッドを叩き、ノブを回すと **101 チャンネル**
生えた — パッド16個が `ch10n36`〜`n51`(ベロシティ付き)、そのアフタータッチが `ch10p36`〜`p51`、
鍵盤が `ch14n36`〜`n101`、ノブ8個が `ch14c21`〜`c28`、ほかに `ch14c1`(モジュレーション)と
`ch14bend`。**MIDI チャンネル番号は機材が送ってきたそのまま**なので、思った番号でなければ
コントローラ側の設定を見ること。

### デバイスが Device メニューに出ないとき

ホットプラグは検証済み: op を置いた状態で Launchkey Mini MK4 を抜き挿しすると、デバイス数が
自動で 2 → 0 → 2 と追従し、その後に新規作成したノードもすぐ認識した。

一度だけ、**他のアプリからは列挙できるデバイスが TouchDesigner の中だけ見えない**ことがあった。
**Refresh Devices** を押しても 0 のままで、TD 本体の `/local/midi/midi_inputs` も空だった。
TouchDesigner を再起動したら直り、その後は同じ手順で再現しなかった。遭遇したら、影響の小さい順に:

1. **Refresh Devices** — 列挙し直す
2. **Restart MIDI System** — `MIDIRestart()` を呼び、MIDI ドライバにハードウェアの再スキャンを
   させる。**正常な状態を壊さないことは確認済み**(前後とも 2 台・エラーなし)。ただし上記の
   症状に効くかは**未検証**(再現しなくなったため)
3. TouchDesigner を再起動する — 実際に直ったのはこれ

なお op 自身も 2 秒に 1 回ほど列挙し直すので、通知を取りこぼしても自力で戻る。

### 出力チャンネル

| チャンネル | 意味 |
|---|---|
| `connected` / `online` | 選択中のソースが解決できた / オンラインを申告している |
| `playing` | Start/Continue から Stop まで1。clock が 0.5秒途切れても 0 に戻す |
| `bpm` | clock(24 PPQN)の間隔から算出 |
| `beat` | 直近の Start または Song Position Pointer からの4分音符数 |
| `bar` | `beat / Beats Per Bar` |
| `tc_hours` `tc_minutes` `tc_seconds` `tc_frames` | 受信した MTC |
| `tc_position` | 同じタイムコードを秒に直したもの |
| `tc_valid` | タイムコードが1つ揃ったら1 |

### パラメータ

| パラメータ | 意味 |
|---|---|
| Device | 入力元。**UniqueID で保持** |
| Refresh Devices | 手動で再列挙(ホットプラグは自動) |
| Restart MIDI System | `MIDIRestart()`。上の「デバイスが出ないとき」を参照 |
| Notes / Controllers (CC) / Pitch Bend / Aftertouch / Program Change | どのメッセージをチャンネルにするか |
| Notes As Gate | ベロシティではなく押している間 1 |
| Normalize To 0-1 | 切ると 0〜127 の生値 |
| Reset Channels | 見つけたチャンネルを全部忘れる |
| Beats Per Bar | `bar` の割り算に使う拍数 |
| BPM Smoothing (clocks) | 何 clock ぶんで平均するか。小さいと追従が速く、大きいと安定する。既定24 = 1拍 |

### 実測(M2 / macOS 26.6)

既知のテンポで clock と MTC を流す仮想ソースに対して:

- 128 BPM の源 → `bpm` 127.39、90 BPM の源 → `bpm` 89.9 / 89.4
  (残差は送信側テストツールのタイマ揺らぎ)
- `beat` が 3.53秒で 59.125 → 64.417。90 BPM での理論値 5.3 拍に対し 5.29 拍
- MTC は `tc_valid` = 1 になり `00:00:18:06` → `00:00:21:22`、`tc_position` は
  18.200 → 21.733 で実経過時間と一致
- ソースを落とすと `playing` / `connected` / `online` が **TD 再起動なしで** 0 になった

## ビルド

```bash
cd CoreMIDI && ./build.sh          # Out と In の両方が build/ にできる
cp -R build/CoreMIDIOutCHOP.plugin ~/Library/Application\ Support/Derivative/TouchDesigner099/Plugins/
```
