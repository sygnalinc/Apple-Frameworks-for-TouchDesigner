# CA Process Tap CHOP

**English** | [日本語](#日本語)

## English

Uses **Core Audio Process Tap** (macOS 14.4+) to tap the whole system's audio — or **only a
chosen process (PID)** — and output it as CHOP audio (48 kHz stereo). Being able to grab "just
this app's sound" is finer-grained than a screen-capture based route. The signal path is
IOProc (realtime thread) → lock-free SPSC ring buffer → timeslice CHOP output, so cook never
blocks.

### Measured (M2)

- In Global mode, while `say` was speaking continuously, output peak = 0.535 (system audio
  captured)
- 48 kHz stereo. A headless probe also confirmed the whole tap → aggregate → IOProc path and
  the peak

### Output (CHOP)

`left` / `right` (48 kHz, timeslice). Info CHOP:
`executes / running / buffered / underruns / samplerate`

### Parameters

| Parameter | Description |
|---|---|
| Active | Enable/disable the tap |
| Mode | Global (all system audio) / Single Process (by PID) |
| Process PID | Target app's PID in Process mode |
| Exclude TouchDesigner | Exclude TD's own audio in Global mode (**default Off** — turning it on stops capture entirely in some environments) |

### Notes

- **How the Core Audio Process Tap works**: `CATapDescription` → `AudioHardwareCreateProcessTap`
  → tap UID → aggregate device (private, tap list) → `AudioDeviceIOProcID` → `AudioDeviceStart`.
  The IOProc pushes audio into an SPSC ring and the CHOP reads it as a timeslice
- **The output sample rate must be set to 48000** (without it the rate defaults to the timeline
  FPS of 60 and the result is not audio)
- If consumption falls behind and the ring is about to overflow, the reader catches up to the
  newest data (always plays the most recent audio, never corrupts)
- Single Process requires the target app to actually be producing sound (the PID must be
  registered as an audio process)

### Build

```
cd CoreAudioProcessTap && ./build.sh
```

## 日本語

**Core Audio Process Tap**(macOS 14.4+)で、システム全体または**指定プロセス(PID)の音声だけ**を
タップし、CHOPのオーディオ(48kHz stereo)として出力する。画面収録ベースの取得より粒度が細かく
「特定アプリの音だけ」を取れる。IOProc(リアルタイムスレッド)→ ロックフリーSPSCリングバッファ →
timeslice CHOP出力。cook はブロックしない。

### 実測(M2)

- Global モードで `say` の連続音声を再生中、出力 peak=0.535 を確認(システム音声を捕捉)
- 48kHz stereo。ヘッドレスprobeでも tap→aggregate→IOProc の全経路とpeak捕捉を確認

### 出力(CHOP)

`left` / `right`(48kHz・timeslice)。Info CHOP: `executes / running / buffered / underruns / samplerate`

### パラメータ

| パラメータ | 説明 |
|---|---|
| Active | タップの有効/無効 |
| Mode | Global(全システム音)/ Single Process(PID指定) |
| Process PID | Process モード時に対象アプリのPID |
| Exclude TouchDesigner | Global時にTD自身の音を除外(**既定Off**。Onにすると環境によっては捕捉されなくなる) |

### 注意

- **Core Audio Process Tap の内部**: `CATapDescription` → `AudioHardwareCreateProcessTap` →
  tap UID → aggregate device(private, tap list)→ `AudioDeviceIOProcID` → `AudioDeviceStart`。
  IOProcの音声を SPSC リングへ、CHOPは timeslice で読む
- **出力サンプルレートを 48000 に設定必須**(未設定だとタイムラインFPS=60扱いになり音にならない)
- 消費が遅れてリングが溢れそうになると最新へ追いつく(常に直近音を出す・データ喪失防止)
- Single Process は対象アプリが音を出している必要がある(PIDが音声プロセスとして登録されていること)

### ビルド

```
cd CoreAudioProcessTap && ./build.sh
```
