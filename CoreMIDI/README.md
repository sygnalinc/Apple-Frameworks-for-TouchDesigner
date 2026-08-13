# CoreMIDI Out

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

### Testing without writing a script

Everything needed to prove the connection is on the parameters:

1. Pick the target in **Device**
2. Press **Send Note** — sends Note On, then Note Off after **Note Duration**
3. Press **Send CC**, or **All Notes Off** if something hangs

`connected`, `online` and `sends` on the output tell you whether it went out.

### Output channels

| Channel | Meaning |
|---|---|
| `connected` | 1 when the selected device resolved to a live endpoint |
| `online` | 1 when that device reports itself online |
| `sends` | Total MIDI messages sent since the node was created |

Info CHOP: `executes / sends / devices / connected / online`.
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
| Channel | MIDI channel 1–16 |
| Note / Velocity / Note Duration | The test note |
| Send Note / Send CC / All Notes Off | Pulses |
| CC Number / CC Value | The test CC |

### Notes

- **A CHOP does not cook unless its output is used.** The automatic Note Off is handled during cook,
  so connect the output to a Null CHOP while testing, or notes will hang.
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

### Build

```bash
cd CoreMIDI && ./build.sh
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

### スクリプトを書かずに送信テストする

接続確認に必要なものは全部パラメータにある。

1. **Device** で送り先を選ぶ
2. **Send Note** を押す → Note On が出て、**Note Duration** 後に Note Off が出る
3. **Send CC**、音が残ったら **All Notes Off**

実際に出たかどうかは出力の `connected` / `online` / `sends` で分かる。

### 出力チャンネル

| チャンネル | 意味 |
|---|---|
| `connected` | 選択中のデバイスが生きたエンドポイントとして解決できていれば1 |
| `online` | そのデバイスがオンラインを申告していれば1 |
| `sends` | ノード生成からの累計送信数 |

Info CHOP: `executes / sends / devices / connected / online`。
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
| Channel | MIDI チャンネル 1〜16 |
| Note / Velocity / Note Duration | テスト用のノート |
| Send Note / Send CC / All Notes Off | パルス |
| CC Number / CC Value | テスト用の CC |

### 注意

- **CHOP は出力が使われていないと cook されない。** 自動 Note Off は cook で処理するので、
  テスト中は出力を Null CHOP などに繋いでおく(繋がないと音が鳴りっぱなしになる)
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

### ビルド

```bash
cd CoreMIDI && ./build.sh
cp -R build/CoreMIDIOutCHOP.plugin ~/Library/Application\ Support/Derivative/TouchDesigner099/Plugins/
```
