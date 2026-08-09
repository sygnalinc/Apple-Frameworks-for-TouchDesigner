# Speech Activity CHOP

**English** | [日本語](#日本語)

## English

Detects speech segments in an audio CHOP on-device with macOS 26's SpeechDetector.

Measured (M2, macOS 26, a 44.1 kHz sine): six channels output, speaking 0 as non-speech, no errors
or warnings. Onset/offset values on real speech material are unverified.

### Output

`speaking / onset / offset / start / end / duration`. onset/offset are one-cook pulses.
The Info DAT shows `listening`, errors and the OS requirement.

### Parameters

Active, Sensitivity (Low/Medium/High). Channel 0 of the input is used and converted internally to
the required format.

### Notes

macOS 26 or later only. SpeechAnalyzer's Swift-only API is used through a bundled helper dylib.

### Build

```sh
./build.sh
```

## 日本語

macOS 26のSpeechDetectorでAudio CHOPから発話区間をオンデバイス検出する。

実測（M2 / macOS 26 / 44.1kHz正弦波）: 6chを出力し、非音声としてspeaking 0、
エラー・警告なし。実発話素材によるonset/offset値は未検証。

### 出力

`speaking / onset / offset / start / end / duration`。onset/offsetは1cookパルス。
Info DATに`listening`、エラー、OS要件を表示する。

### パラメータ

Active、Sensitivity（Low/Medium/High）。入力はch0を使用し、内部で必要形式へ変換する。

### 注意

macOS 26以降専用。SpeechAnalyzerのSwift専用APIを同梱helper dylib経由で使用する。

### ビルド

```sh
./build.sh
```
