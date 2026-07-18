# Speech Text DAT — ライブ文字起こし（macOS 26+ / SpeechAnalyzer）

Audio パラメータで指定したオーディオ CHOP（Audio Device In / Audio File In 等）を
**新しい SpeechAnalyzer / SpeechTranscriber** でライブ文字起こしし、テーブルで出力する
TD ネイティブのカスタム DAT。

- **完全オンデバイス**（音声は端末外へ出ない）・**音声認識の TCC 許可が不要**
  （旧 SFSpeechRecognizer と違い、ホストアプリの Info.plist に使用目的キーが無くても動く —
  TouchDesigner には音声認識キーが無いため、この新APIを採用している）
- 初回のみロケールの言語モデルダウンロードが走る（Info DAT の status が "downloading model"）
- 実装は同梱の `libSpeechHelper.dylib`（Swift・SpeechAnalyzer は Swift 専用APIのため）

実測（M2 / `say` 生成の日本語音声）: 一字違わず転写。

## 出力テーブル

```
index | text                     | final
0     | こんにちは、エアバンドへ… | 1      ← 確定したセグメント
1     | 今日はみんなで…          | 0      ← 認識途中（volatile・随時書き換わる）
```

- 確定行が積み上がり、最終行に認識途中のテキスト（final=0）が出る
- `Max Rows` を超えた古い確定行は捨てられる
- 確定は発話の区切り（ポーズ）で起きる。連続音声は途中結果のまま伸びていく

## パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| Audio CHOP | — | 文字起こしするオーディオ CHOP（ch0 を使用） |
| Active | On | 解析の有効/無効 |
| Locale | ja-JP | 言語（BCP-47。対応外なら Info DAT に unsupported と出る） |
| Max Rows | 50 | 保持する確定行数 |
| Clear Transcript | — | パルスで確定済みテキストをクリア |

Info CHOP: `executes / finalized`。Info DAT: `status`（starting / downloading model /
listening / error...）。

## 注意

- **macOS 26 以降専用**（SpeechAnalyzer）。それ未満では status が "requires macOS 26" になる
- `cookEveryFrameIfAsked` — 出力をどこかで使って（表示して）いないと cook されず音声が
  流れない（DAT Execute で監視する等）
- ロード直後にカスタムパラメータが見えないことがある → `Re-Init Plugin` をパルス

## ビルド

```
./build.sh    # → build/SpeechTextDAT.plugin（Swift ヘルパ dylib を同梱）
```
