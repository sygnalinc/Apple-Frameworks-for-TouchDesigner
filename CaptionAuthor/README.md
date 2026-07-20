# Caption Author DAT

文字起こし/字幕テーブルを **SRT / WebVTT の字幕テキストへ整形**し、ファイルにも書き出す。
SpeechText DAT(index/text/final)や、start/end/text 列を持つ任意の入力DATを字幕にできる。

## 何ができる

- 入力DATに **start/end 列があればその時刻**を使う(秒 / ミリ秒 / タイムコードを選択)
- start が無ければ **Default Duration で 0 から連番タイミングを自動付与**
  (SpeechText の index/text/final をそのまま字幕化できる)
- end が無ければ start + Default Duration、または次キャプションの start までにクランプ
- `Only Finalized Rows` で SpeechText の未確定(volatile)行を除外
- 出力は DAT本体に整形済みテキスト(SRT/VTT)、`Write File` でファイル保存

## 実測(M2)

- start/end/text の3行テーブル(秒)→ SRT を正しい連番+タイムコード
  (`00:00:00,000 --> 00:00:02,500`)で出力
- 同じ入力を VTT に切替 → `WEBVTT` ヘッダ + ドット区切り時刻(`00:00:00.000 --> ...`)
- text のみのテーブル → Default Duration 1.5s で 0→1.5→3.0s の連番字幕を自動生成

## 出力

- DAT本体: 整形済み字幕テキスト(`setText`)。File Out DAT でも保存可・自前 Write もあり
- Info CHOP: `executes` / `cues`(字幕数) / `writes`(ファイル書き込み回数)

## パラメータ

| パラメータ | 説明 |
|---|---|
| Format | SubRip(.srt)/ WebVTT(.vtt) |
| Text Column | テキスト列名(既定 text) |
| Start Column | 開始時刻列名(既定 start・無ければ連番) |
| End Column | 終了時刻列名(既定 end・無ければ Default Duration) |
| Time Unit | 秒 / ミリ秒 / タイムコード(HH:MM:SS,mmm) |
| Default Duration (s) | start/end 欠落時の1字幕の長さ |
| Only Finalized Rows | `final` 列が 0 の行を除外(SpeechText 向け) |
| Output File | 書き出し先(.srt / .vtt) |
| Auto Write | 内容が変わるたび自動保存 |
| Write File | 手動で保存(パルス) |

## 注意

- SpeechText の現行出力は index/text/final で**時刻列を持たない**ため、連番モード
  (Default Duration)で字幕化する。正確な時刻が要る場合は start/end 列を持つDATを入力する
- タイムコード入力は `HH:MM:SS,mmm` / `HH:MM:SS.mmm` / `MM:SS` を受ける

## ビルド

```
cd CaptionAuthor && ./build.sh   # → build/CaptionAuthorDAT.plugin
```
