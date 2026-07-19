# SpeechSynth CHOP

AVSpeechSynthesizerのmacOS標準音声をPCM Audio CHOPへ出力する。ネット接続、APIキー、追加モデルは不要で、インストール済みのSystem Voiceを利用できる。

## 出力

`left` / `right`（音声合成はmonoを複製）。既定1024 samples/block。Speak pulseまたはText変更で非同期生成し、cookごとにキューから読み出す。

## パラメータ

Text、Voice Identifier（空欄は既定音声）、Rate、Pitch、Volume、Block Samples、Speak When Text Changes、Speak、Stop。

## 注意

出力CHOPをAudio Device Out等から参照し、毎フレームcookさせる。音声identifierはmacOSの言語とインストール状況に依存する。TD実測で英語1 utteranceを22.05 kHz・181 callback buffersへ生成し、エラーなしを確認。連続Audio Device Outの聴感確認は未実施。

## ビルド

`./build.sh` → `build/SpeechSynthCHOP.plugin`
