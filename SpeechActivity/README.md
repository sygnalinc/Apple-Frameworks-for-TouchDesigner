# Voice Activity CHOP

macOS 26のSpeechDetectorでAudio CHOPから発話区間をオンデバイス検出する。

実測（M2 / macOS 26 / 44.1kHz正弦波）: 6chを出力し、非音声としてspeaking 0、
エラー・警告なし。実発話素材によるonset/offset値は未検証。

## 出力

`speaking / onset / offset / start / end / duration`。onset/offsetは1cookパルス。
Info DATに`listening`、エラー、OS要件を表示する。

## パラメータ

Active、Sensitivity（Low/Medium/High）。入力はch0を使用し、内部で必要形式へ変換する。

## 注意

macOS 26以降専用。SpeechAnalyzerのSwift専用APIを同梱helper dylib経由で使用する。

## ビルド

```sh
./build.sh
```
