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

A dropdown built at runtime from `AVSpeechSynthesisVoice.speechVoices()` — 180 voices across 49
languages on the machine this was measured on. Labelled `en-US  Samantha  (Default)` so the
language is visible while you scroll. Leave it on **System Default** to follow the system voice.

**Nothing here needs downloading.** `speechVoices()` only reports voices already installed, so
every entry is usable immediately (verified by instantiating several). This is the opposite of
Speech Transcribe's `Locale`, where the list includes locales whose model downloads on first use.

Higher-quality **Enhanced / Premium** voices are an opt-in download in System Settings →
Accessibility → Spoken Content → System Voice → Manage Voices. Once installed they appear in this
dropdown automatically, since it is rebuilt at runtime.

**No separate locale parameter is needed** — the identifier carries the language
(`com.apple.voice.compact.ja-JP.Kyoko` is Japanese). It is a string parameter, so an identifier
that is not in the list can also be typed.

### Parameters

Text, Voice Identifier (blank = the default voice), Rate, Pitch, Volume, Block Samples,
Speak When Text Changes, Speak, Stop.

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

`AVSpeechSynthesisVoice.speechVoices()` から実行時に組むプルダウン（計測機では 180音声 / 49言語）。
`en-US  Samantha  (Default)` の形で言語が見えるようにしてある。**System Default** のままなら
システムの声に従う。

**ここに出るものはダウンロード不要。** `speechVoices()` は端末にインストール済みの音声しか
返さないので、並んでいる時点で全部すぐ使える（いくつか実際にインスタンス化して確認）。
Speech Transcribe の `Locale` とはここが逆で、あちらは未インストールのものも並び初回にDLが走る。

より高品質な **Enhanced / Premium** は、システム設定 > アクセシビリティ > 読み上げコンテンツ >
システムの声 > 声を管理 からダウンロードする。入れればこのプルダウンに自動で加わる（実行時に
組み直しているため）。

**Locale パラメータは別途要らない** — 識別子が言語を含んでいる
（`com.apple.voice.compact.ja-JP.Kyoko` は日本語）。文字列パラメータなので、一覧に無い識別子を
直接打ち込むこともできる。

### パラメータ

Text、Voice Identifier（空欄は既定音声）、Rate、Pitch、Volume、Block Samples、Speak When Text Changes、Speak、Stop。

### 注意

出力CHOPをAudio Device Out等から参照し、毎フレームcookさせる。音声identifierはmacOSの言語とインストール状況に依存する。TD実測で英語1 utteranceを22.05 kHz・181 callback buffersへ生成し、エラーなしを確認。

本CHOPは timeslice なので実時間ペースで再生される（初期版は毎フレーム固定ブロックを出していて
実時間の約2.8倍速＝ノイズになっていた。修正済み）。

### ビルド

`./build.sh` → `build/SpeechSynthCHOP.plugin`
