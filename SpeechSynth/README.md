# Speech Synth CHOP

**English** | [日本語](#日本語)

## English

Outputs macOS's standard AVSpeechSynthesizer voices as a PCM audio CHOP. No network connection,
API key or extra model is needed — it uses the System Voices already installed.

### Output

`left` / `right` (speech synthesis is mono and duplicated). 1024 samples/block by default.
Generation is asynchronous, triggered by a Speak pulse or a Text change, and read out of the queue
on each cook.

### Voice

A dropdown built at runtime from `AVSpeechSynthesisVoice.speechVoices()` — 183 voices across 49
languages on the machine this was measured on. Labelled `en-US  Samantha  (Default)` so the
language is visible while you scroll. Leave it on **System Default** to follow the system voice.

**Every entry is usable immediately — nothing here needs downloading.** This is the opposite of
Speech Transcribe's `Locale`, where the list includes locales whose model downloads on first use.

**No separate locale parameter is needed** — the identifier carries the language
(`com.apple.voice.compact.ja-JP.Kyoko` is Japanese). It is a string parameter, so an identifier
that is not in the list can also be typed.

### Adding higher-quality voices

Most installed voices are the compact **Default** quality. **Enhanced / Premium** voices are an
opt-in download, and **only the user can start that download** — see the table below.

| | |
|---|---|
| List installed voices | `AVSpeechSynthesisVoice.speechVoices()` |
| List voices *not* installed | **no public API** |
| Start a download | **no public API** — `AVSpeechSynthesisVoice` exposes only `speechVoices` / `currentLanguageCode` / `voiceWithLanguage` / `voiceWithIdentifier` |

`voiceWithIdentifier:` is documented to return `nil` for a valid identifier that has not been
downloaded, so the framework is aware of such voices but never offers to fetch them.

So the flow is: press **Open Voice Settings** → System Settings opens straight on *Accessibility →
Spoken Content* → *System Voice* → *Manage Voices* → download → the dropdown picks the new voice
up on its own (the operator listens for `AVSpeechSynthesisAvailableVoicesDidChangeNotification`).
**Refresh Voice List** rebuilds it by hand if it ever looks stale. **No TouchDesigner restart is
needed.** Measured on this Mac: 183 voices, of which 2 are Enhanced (`ja-JP` Kyoko and Otoya) —
both downloaded through Settings and both listed here automatically.

### Parameters

Text, Voice, Rate, Pitch, Volume, Block Samples, Speak When Text Changes, Speak, Stop,
Refresh Voice List, Open Voice Settings.

### Notes

Reference the output CHOP from an Audio Device Out or similar so it cooks every frame. Which voice
identifiers exist depends on the languages installed in macOS. Measured in TD: one English
utterance generated at 22.05 kHz across 181 callback buffers, no errors.

The CHOP is timeslice-based, so playback runs at real time. (An earlier version output a fixed
block per frame, which played about 2.8× too fast and sounded like noise; that is fixed.)

### Build

`./build.sh` → `build/SpeechSynthCHOP.plugin`

## 日本語

AVSpeechSynthesizerのmacOS標準音声をPCM Audio CHOPへ出力する。ネット接続、APIキー、追加モデルは不要で、インストール済みのSystem Voiceを利用できる。

### 出力

`left` / `right`（音声合成はmonoを複製）。既定1024 samples/block。Speak pulseまたはText変更で非同期生成し、cookごとにキューから読み出す。

### Voice

`AVSpeechSynthesisVoice.speechVoices()` から実行時に組むプルダウン（計測機では 183音声 / 49言語）。
`en-US  Samantha  (Default)` の形で言語が見えるようにしてある。**System Default** のままなら
システムの声に従う。

**並んでいるものは全部すぐ使える（ダウンロード不要）。** Speech Transcribe の `Locale` とは
ここが逆で、あちらは未インストールのものも並び初回にDLが走る。

**Locale パラメータは別途要らない** — 識別子が言語を含んでいる
（`com.apple.voice.compact.ja-JP.Kyoko` は日本語）。文字列パラメータなので、一覧に無い識別子を
直接打ち込むこともできる。

### 高品質な音声を追加する

インストール済みのほとんどは compact な **Default** 品質。**Enhanced / Premium** は任意DLで、
**ダウンロードを開始できるのはユーザーだけ**。

| | |
|---|---|
| インストール済みの列挙 | `AVSpeechSynthesisVoice.speechVoices()` |
| **未**インストールの列挙 | **公開APIなし** |
| ダウンロードの開始 | **公開APIなし** — `AVSpeechSynthesisVoice` のクラスメソッドは `speechVoices` / `currentLanguageCode` / `voiceWithLanguage` / `voiceWithIdentifier` の4つだけ |

`voiceWithIdentifier:` は「識別子は正しいがまだDLされていない場合 nil を返す」と明記されており、
フレームワーク自身は未DL音声の存在を認識しているが、取得する手段は提供していない。

したがって手順は、**Open Voice Settings** を押す → システム設定の *アクセシビリティ > 読み上げ
コンテンツ* が直接開く → *システムの声 > 声を管理* でDL → プルダウンが自動で拾う
（`AVSpeechSynthesisAvailableVoicesDidChangeNotification` を監視している）。
おかしいときは **Refresh Voice List** で手動再取得。**TouchDesignerの再起動は不要**。
実測: この Mac は 183音声で、うち Enhanced が2つ（`ja-JP` Kyoko / Otoya）。
どちらも設定からDLしたもので、自動で一覧に出ている。

### パラメータ

Text、Voice、Rate、Pitch、Volume、Block Samples、Speak When Text Changes、Speak、Stop、
Refresh Voice List、Open Voice Settings。

### 注意

出力CHOPをAudio Device Out等から参照し、毎フレームcookさせる。音声identifierはmacOSの言語とインストール状況に依存する。TD実測で英語1 utteranceを22.05 kHz・181 callback buffersへ生成し、エラーなしを確認。

本CHOPは timeslice なので実時間ペースで再生される（初期版は毎フレーム固定ブロックを出していて
実時間の約2.8倍速＝ノイズになっていた。修正済み）。

### ビルド

`./build.sh` → `build/SpeechSynthCHOP.plugin`
