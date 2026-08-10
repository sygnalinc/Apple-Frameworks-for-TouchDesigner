# Speech Activity CHOP

**English** | [日本語](#日本語)

## English

Detects speech segments in an audio CHOP on-device with macOS 26's SpeechDetector.

> [!WARNING]
> **This operator does not work, and cannot be made to work with the current API.** Measured on
> M2 / macOS 26.6 with 19 s of clear speech: `speaking` never leaves 0 across 729 frames, at two
> sample rates and the highest sensitivity, while the Info DAT reports `listening` with no errors.
> See *Why it does not work* below. Use **Sound Class** (its 303-class catalog includes `speech`)
> for speech gating until this is resolved.

### Output

`speaking / onset / offset / start / end / duration`. onset/offset are one-cook pulses.
The Info DAT shows `listening`, errors and the OS requirement.

### Parameters

Active, Sensitivity (Low/Medium/High). Channel 0 of the input is used and converted internally to
the required format.

### Why it does not work

Measured with a standalone Swift harness against the same audio:

| Step | Result |
|---|---|
| `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [detector])` | **0 Hz / 0 ch** — the only format `SpeechDetector` advertises |
| `AVAudioConverter(from: input, to: that format)` | `nil`, so the helper's `feed()` returns early and **no audio ever reaches the analyzer** |
| `prepareToAnalyze` with a detector-only module set | Apple's own trap: *"Cannot create SpeechDetector-only worker; use with a transcriber module"* |
| Detector paired with `SpeechTranscriber` (format becomes 16 kHz, 19 s fed) | Transcriber returns 4 correct results — so the audio path is fine — but `detector.results` yields **0** |

So `SpeechDetector` behaves as an internal gating module for the transcriber rather than a
user-facing VAD, and the status read `listening` only because the helper sets that string *before*
calling `analyzer.start()`.

### Notes

macOS 26 or later only. SpeechAnalyzer's Swift-only API is used through a bundled helper dylib.

### Build

```sh
./build.sh
```

## 日本語

macOS 26のSpeechDetectorでAudio CHOPから発話区間をオンデバイス検出する。

> [!WARNING]
> **このオペレータは動作せず、現行APIでは動作させられない。** M2 / macOS 26.6 で19秒の明瞭な
> 発話を入力した実測: サンプルレート2種・感度最高でも `speaking` は729フレーム中一度も立たず、
> Info DAT は `listening`・エラーなしのまま。理由は下の「動作しない理由」を参照。
> 発話ゲートが要るなら当面 **Sound Class**（303クラスに `speech` がある）を使う。

### 出力

`speaking / onset / offset / start / end / duration`。onset/offsetは1cookパルス。
Info DATに`listening`、エラー、OS要件を表示する。

### パラメータ

Active、Sensitivity（Low/Medium/High）。入力はch0を使用し、内部で必要形式へ変換する。

### 動作しない理由

同じ音声を単体Swiftハーネスに通した実測:

| 段階 | 結果 |
|---|---|
| `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [detector])` | **0 Hz / 0 ch** — `SpeechDetector` が申告する互換フォーマットはこれ1つだけ |
| `AVAudioConverter(from: 入力, to: そのフォーマット)` | `nil` になり、helper の `feed()` が早期returnして**音声が1サンプルも解析器へ届かない** |
| detector 単体で `prepareToAnalyze` | Apple自身の致命的エラー *"Cannot create SpeechDetector-only worker; use with a transcriber module"* |
| `SpeechTranscriber` と組み合わせ（16kHzになり19秒投入） | transcriber は正しい認識結果を4件返す（=音声経路は正常）が、`detector.results` は**0件** |

`SpeechDetector` はユーザー向けVADではなく transcriber の内部ゲート用モジュールとして振る舞う。
状態が `listening` に見えていたのは、helper が `analyzer.start()` の**前**にその文字列を
セットしているためで、起動の証拠になっていなかった。

### 注意

macOS 26以降専用。SpeechAnalyzerのSwift専用APIを同梱helper dylib経由で使用する。

### ビルド

```sh
./build.sh
```
