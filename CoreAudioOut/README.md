# CoreAudio Out CHOP

**English** | [日本語](#日本語)

## English

Plays audio to a CoreAudio output device **directly**, bypassing TouchDesigner's cook-driven audio
path. Two sources, mixed together:

- **Input 0** (optional): a TD audio CHOP — the Audio Device Out role
- **File Player page**: an audio file decoded on its own thread, fed straight to the device's
  IOProc. **Playback survives cook stalls completely** — the file keeps playing even while
  TouchDesigner's main thread is blocked.

> **Status: experimental.** File playback through a 2-second deliberate main-thread stall verified
> on macOS 26 (position kept advancing, ~2.7 s of decode-ahead maintained). Not shipped in the
> release DMG. `PLUGINS.tsv` is the source of truth.

### Why this exists (measured)

TouchDesigner's audio is cook-driven: Audio File In produces samples only when it cooks, so a heavy
frame produces nothing and Audio Device Out's queue drains. One stall longer than `Buffer Length`
(0.15 s by default) and the device underruns — that is the crackle you hear when fps drops. This
operator's file player does not depend on cooking at all: a decoder thread keeps a ring buffer
(~5 s) full and the CoreAudio IOProc reads it on the audio thread.

The CHOP input, by contrast, **is still cook-driven** — if TD stalls, that component stops with it.
The file player is the part a custom op can actually fix.

### Parameters

| Page | Parameter | Meaning |
|---|---|---|
| CoreAudio Out | Active | start/stop the device connection |
| | Device | output device (dynamic menu of every device with an output stream; `System Default` follows the OS setting). A selected device that is unplugged raises an error instead of silently falling back |
| | Device Sample Rate | **changes the device's rate system-wide** (As Is / 44100–96000). Unsupported rates raise a warning without touching the device |
| | Buffer Size (frames) | the device's I/O buffer (As Is / 64–2048). Smaller = lower latency, easier to underrun |
| | Input Gain | gain for input 0 |
| | Exclusive (Hog Mode) | take the device exclusively (no other apps, no rate changes) |
| File Player | Audio File | any format Core Audio reads (wav/aiff/mp3/m4a/…) |
| | Play / Loop / File Gain | transport; decoding converts to the device rate |
| | Cue Point (s) / Cue Pulse | seek |

The CHOP output is a **monitor copy** of what actually played. Info CHOP: `device_rate`, `running`,
`file_position`, `file_duration`, `file_buffered` (samples of decode-ahead), `buffer_frames`
(the device's actual I/O buffer). When the device rate changes, the file player reopens and
converts to the new rate automatically.

**Measured (M2)**: switching to a virtual device (BlackHole) at 44100/256 then 96000/1024 —
`device_rate` and `buffer_frames` follow each time, playback continues, and the CHOP output rate
tracks the device. Selecting a disconnected device stops cleanly with an error.

### Notes

- The device's own rate is used as-is (no resampling in TD; the decoder converts the file once)
- `Exclusive` affects the whole system — other apps go silent. Meant for installations
- Latency of the file player is the device buffer only (~14 ms measured); the CHOP input keeps
  TouchDesigner's usual frame-quantised timing

## 日本語

CoreAudio の出力デバイスへ**直接**音を出す。TouchDesigner の cook 駆動の音声経路を通らない。
音源は2系統で、ミックスされる:

- **入力0**(任意): TD の音声 CHOP — Audio Device Out の役割
- **File Player ページ**: 音声ファイルを自前スレッドでデコードし、デバイスの IOProc へ直接流す。
  **cook が止まっても再生は完全に継続する**

> **状態: 実験中。** メインスレッドを意図的に2秒止めても再生が続くこと(位置が進み続け、
> 約2.7秒の先読みを維持)を macOS 26 で実測済み。リリース DMG には同梱しない。
> 正は `PLUGINS.tsv`。

### 何のためにあるか(実測)

TD の音声は cook 駆動で、Audio File In は cook されたときしかサンプルを作らない。重いフレームでは
何も作られず Audio Device Out の待ち行列が減り続け、**1回のハングが `Buffer Length`(既定0.15秒)を
超えるとデバイスが枯渇してプツッと切れる** — fps が落ちたときの音の乱れの正体。
この op のファイル再生は cook に一切依存しない: デコーダスレッドがリングバッファ(約5秒)を
満たし続け、CoreAudio の IOProc がオーディオスレッドで読む。

一方 **CHOP 入力は今までどおり cook 駆動**なので、TD が止まればその成分は止まる。
自作 op で本当に直せるのはファイル再生の部分。

### パラメータ

| ページ | パラメータ | 意味 |
|---|---|---|
| CoreAudio Out | Active | デバイス接続の開始/停止 |
| | Device | 出力デバイス(出力ストリームを持つ全デバイスの動的メニュー。`System Default` は OS の設定に追従)。選んだデバイスが抜かれていたら**黙って他へ切り替えずエラー**にする |
| | Device Sample Rate | **デバイスのレートを変更する(システム全体に効く)**。As Is / 44100〜96000。非対応レートは警告を出してデバイスに触らない |
| | Buffer Size (frames) | デバイスの I/O バッファ(As Is / 64〜2048)。小さいほど低レイテンシ・音切れしやすい |
| | Input Gain | 入力0のゲイン |
| | Exclusive (Hog Mode) | デバイスを排他で取る(他アプリの音・レート変更が入らない) |
| File Player | Audio File | Core Audio が読める形式(wav/aiff/mp3/m4a/…) |
| | Play / Loop / File Gain | トランスポート。デコード時にデバイスのレートへ変換 |
| | Cue Point (s) / Cue Pulse | 頭出し |

CHOP 出力は**実際に鳴った音のモニタコピー**。Info CHOP: `device_rate` / `running` /
`file_position` / `file_duration` / `file_buffered`(先読みサンプル数)/ `buffer_frames`
(デバイスの実際の I/O バッファ)。デバイスのレートが変わるとファイルプレイヤーは
自動で開き直し、新しいレートへ変換する。

**実測(M2)**: 仮想デバイス(BlackHole)へ切り替えて 44100/256 → 96000/1024 —
`device_rate` と `buffer_frames` が毎回追従し、再生は継続、CHOP の出力レートもデバイスに追従。
抜かれたデバイスを選ぶとエラーを出して止まる(黙って別のデバイスへは切り替えない)。

### 注意

- デバイスのレートをそのまま使う(TD 側で再変換しない。ファイルはデコード時に1回だけ変換)
- `Exclusive` は**システム全体に効く**(他アプリが無音になる)。インスタレーション向け
- ファイル再生のレイテンシはデバイスバッファのみ(実測 約14ms)。CHOP 入力は従来どおり
  フレーム量子化されたタイミング

### ビルド

```
cd CoreAudioOut && ./build.sh
```
