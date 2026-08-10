# Speech Text DAT — live transcription (macOS 26+ / SpeechAnalyzer)

**English** | [日本語](#日本語)

## English

A TD-native custom DAT that live-transcribes the audio CHOP named in the Audio parameter (Audio
Device In, Audio File In, …) with the **new SpeechAnalyzer / SpeechTranscriber** and outputs the
result as a table.

- **Fully on-device** (audio never leaves the machine) and **no speech-recognition TCC permission
  required** — unlike the old SFSpeechRecognizer it works even though the host app's Info.plist
  has no usage key (TouchDesigner has no speech-recognition key, which is why this newer API is
  used)
- The first run downloads the locale's language model (the Info DAT status shows
  "downloading model")
- Implemented via the bundled `libSpeechHelper.dylib` (Swift — SpeechAnalyzer is a Swift-only API)

Measured (M2, Japanese audio generated with `say`): transcribed without a single error.

### Output table

```
index | text                     | final
0     | Hello, welcome to the …  | 1      ← a finalised segment
1     | Today everyone is …      | 0      ← still being recognised (volatile, rewritten as it goes)
```

- Finalised rows accumulate, and the last row holds the in-progress text (final = 0)
- Finalised rows beyond `Max Rows` are discarded
- Finalisation happens at speech boundaries (pauses). Continuous speech keeps extending the
  volatile row

### Parameters

| Parameter | Default | Description |
|---|---|---|
| Audio CHOP | — | The audio CHOP to transcribe (channel 0 is used) |
| Active | On | Enable/disable analysis |
| Locale | ja-JP | Recognition locale, as a dropdown built at runtime from `SpeechTranscriber.supportedLocales` (30 on macOS 26.6). Locales whose model is already on the machine are marked `(installed)`; the rest download on first use. **A code that is not in the list can also be typed**, which is how you reach WhisperKit's wider language set |
| Max Rows | 50 | Finalised rows to keep |
| Clear Transcript | — | Pulse to clear the finalised text |

Info CHOP: `executes / finalized`. Info DAT: `status` (starting / downloading model / listening /
error…).

### Notes

- **macOS 26 or later only** (SpeechAnalyzer). Below that the status reads "requires macOS 26"
- `cookEveryFrameIfAsked` — unless the output is used (displayed) somewhere it does not cook and
  no audio flows (watch it with a DAT Execute, for example)
- Custom parameters are occasionally invisible right after loading → pulse `Re-Init Plugin`

### Whisper backend (macOS 14+)

The Backend menu can switch to **WhisperKit (Core ML Whisper)**:

| | Apple SpeechAnalyzer (default) | WhisperKit |
|---|---|---|
| OS | macOS 26+ | **macOS 14+** |
| Method | True streaming (low latency) | Chunked re-recognition (volatile updated periodically, finalised on silence or at 30 s) |
| Language | The locale's language model | Multilingual (the first two letters of Locale are the language hint) |
| Translation | None (pair with the Translate DAT) | **Whisper Task = Translate To English translates directly** |
| Model | Ships with the OS (downloaded once) | Tiny 75 MB / Base 150 MB / Small 500 MB / Large v3 3 GB (downloaded from Hugging Face on first use into `~/Documents/huggingface/`) |

- On the first run the status stays at "loading model..." while the model downloads (Base is about
  150 MB)
- Whisper does not stream, so finalisation is slower than the Apple backend. For low latency,
  macOS 26 with the Apple backend is recommended
- Whisper hallucinates things like "[music]" on silent buffers, so near-silent buffers are dropped
  (RMS < 0.004) and finalised lines that are nothing but a bracketed tag are discarded

### Build

```
./build.sh    # → build/SpeechTextDAT.plugin (bundles the Swift helper dylib)
```

## 日本語

Audio パラメータで指定したオーディオ CHOP（Audio Device In / Audio File In 等）を
**新しい SpeechAnalyzer / SpeechTranscriber** でライブ文字起こしし、テーブルで出力する
TD ネイティブのカスタム DAT。

- **完全オンデバイス**（音声は端末外へ出ない）・**音声認識の TCC 許可が不要**
  （旧 SFSpeechRecognizer と違い、ホストアプリの Info.plist に使用目的キーが無くても動く —
  TouchDesigner には音声認識キーが無いため、この新APIを採用している）
- 初回のみロケールの言語モデルダウンロードが走る（Info DAT の status が "downloading model"）
- 実装は同梱の `libSpeechHelper.dylib`（Swift・SpeechAnalyzer は Swift 専用APIのため）

実測（M2 / `say` 生成の日本語音声）: 一字違わず転写。

### 出力テーブル

```
index | text                     | final
0     | こんにちは、エアバンドへ… | 1      ← 確定したセグメント
1     | 今日はみんなで…          | 0      ← 認識途中（volatile・随時書き換わる）
```

- 確定行が積み上がり、最終行に認識途中のテキスト（final=0）が出る
- `Max Rows` を超えた古い確定行は捨てられる
- 確定は発話の区切り（ポーズ）で起きる。連続音声は途中結果のまま伸びていく

### パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| Audio CHOP | — | 文字起こしするオーディオ CHOP（ch0 を使用） |
| Active | On | 解析の有効/無効 |
| Locale | ja-JP | 認識ロケール。`SpeechTranscriber.supportedLocales` から実行時に組むプルダウン（macOS 26.6 で30件）。端末に言語モデルが入っているものは `(installed)` 表示、無いものは初回にダウンロードが走る。**一覧に無いコードを直接打ち込むこともできる**（WhisperKit のより広い言語セット用） |
| Max Rows | 50 | 保持する確定行数 |
| Clear Transcript | — | パルスで確定済みテキストをクリア |

Info CHOP: `executes / finalized`。Info DAT: `status`（starting / downloading model /
listening / error...）。

### 注意

- **macOS 26 以降専用**（SpeechAnalyzer）。それ未満では status が "requires macOS 26" になる
- `cookEveryFrameIfAsked` — 出力をどこかで使って（表示して）いないと cook されず音声が
  流れない（DAT Execute で監視する等）
- ロード直後にカスタムパラメータが見えないことがある → `Re-Init Plugin` をパルス

### Whisper バックエンド(macOS 14+)

Backend メニューで **WhisperKit(Core ML版Whisper)** に切替できる:

| | Apple SpeechAnalyzer(既定) | WhisperKit |
|---|---|---|
| 対応OS | macOS 26+ | **macOS 14+** |
| 方式 | 真のストリーミング(低遅延) | チャンク再認識(volatileを定期更新・無音/30秒で確定) |
| 言語 | ロケールの言語モデル | 多言語(Localeの先頭2文字を言語ヒントに) |
| 英訳 | なし(Translate DATを併用) | **Whisper Task=Translate To English で直接英訳** |
| モデル | OS同梱(初回DL) | Tiny 75MB / Base 150MB / Small 500MB / Large v3 3GB(初回にHugging FaceからDL・`~/Documents/huggingface/`) |

- 初回は status が "loading model..." のままモデルDLが走る(Base 約150MB)
- Whisper はストリーミング非対応のため確定までのテンポは Apple 側より遅い。
  低遅延が必要なら macOS 26 + Apple バックエンドを推奨
- Whisper は無音バッファに「[音楽]」等を幻覚するため、ほぼ無音のバッファは認識せず捨て
  (RMS<0.004)、括弧タグだけの確定行も破棄している

### ビルド

```
./build.sh    # → build/SpeechTextDAT.plugin（Swift ヘルパ dylib を同梱）
```
