# Process Audio CHOP

**Core Audio Process Tap**(macOS 14.4+)で、システム全体または**指定プロセス(PID)の音声だけ**を
タップし、CHOPのオーディオ(48kHz stereo)として出力する。SystemAudio(ScreenCaptureKit)より粒度が細かく
「特定アプリの音だけ」を取れる。IOProc(リアルタイムスレッド)→ ロックフリーSPSCリングバッファ →
timeslice CHOP出力。cook はブロックしない。

## 実測(M2)

- Global モードで `say` の連続音声を再生中、出力 peak=0.535 を確認(システム音声を捕捉)
- 48kHz stereo。ヘッドレスprobeでも tap→aggregate→IOProc の全経路とpeak捕捉を確認

## 出力(CHOP)

`left` / `right`(48kHz・timeslice)。Info CHOP: `executes / running / buffered / underruns / samplerate`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Active | タップの有効/無効 |
| Mode | Global(全システム音)/ Single Process(PID指定) |
| Process PID | Process モード時に対象アプリのPID |
| Exclude TouchDesigner | Global時にTD自身の音を除外(**既定Off**。Onにすると環境によっては捕捉されなくなる) |

## 注意

- **Core Audio Process Tap の内部**: `CATapDescription` → `AudioHardwareCreateProcessTap` →
  tap UID → aggregate device(private, tap list)→ `AudioDeviceIOProcID` → `AudioDeviceStart`。
  IOProcの音声を SPSC リングへ、CHOPは timeslice で読む
- **出力サンプルレートを 48000 に設定必須**(未設定だとタイムラインFPS=60扱いになり音にならない)
- 消費が遅れてリングが溢れそうになると最新へ追いつく(常に直近音を出す・データ喪失防止)
- Single Process は対象アプリが音を出している必要がある(PIDが音声プロセスとして登録されていること)

## ビルド
```
cd ProcessAudio && ./build.sh
```
