# Translate DAT — オンデバイス翻訳（macOS 15+ / Translation framework）

入力 DAT のテキストを **Apple の Translation framework でオンデバイス翻訳**する
TD カスタム DAT。**SpeechText DAT を入力に繋ぐとリアルタイム字幕翻訳**になる
（文字起こし→翻訳まで完全ローカル）。

実測: ja→en で3行テーブルを翻訳（"こんにちは、エアバンドへようこそ。"
→ "Hello, welcome to Airband."）。訳文はキャッシュされ同じ原文は再翻訳しない。

## 動作モード

- **入力 DAT あり**: ヘッダに `text` 列があればその列（無ければ列0）を翻訳し、
  **同じ形のテーブル**で出力（対象列を訳文に差し替え。翻訳中の行は空文字）。
  SpeechText の `index | text | final` をそのまま流せるドロップイン設計
- **入力 DAT なし**: `Text` パラメータを翻訳して `source | target` の1行を出力

## パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| Active | On | 翻訳の有効/無効 |
| Source Language | Japanese (ja) | 原文の言語（**対応約20言語のリストから選択**） |
| Target Language | English US (en) | 訳文の言語（同上） |
| Text (No-Input Mode) | — | 入力 DAT が無いときの原文 |
| Clear Cache | — | 訳文キャッシュをクリア（再翻訳させる） |

Info DAT: `status`（loading language pair / ready / translate error 等）。

対応言語（Apple翻訳アプリと同一セット・メニューに内蔵）: 日本語 / 英語(米・英) /
中国語(簡・繁) / 韓国語 / スペイン語 / フランス語 / ドイツ語 / イタリア語 /
ポルトガル語(伯) / ロシア語 / アラビア語 / オランダ語 / タイ語 / ベトナム語 /
ポーランド語 / トルコ語 / インドネシア語 / ヒンディー語 / ウクライナ語。
非英語ペアは内部で英語ピボットのため両言語のモデルが必要。

## 注意

- **言語ペアのモデルが未導入だと初回に自動ダウンロード**が走る（ja→en 実測 約5分。
  その間 status は loading のまま。事前に「翻訳」アプリ等で言語をダウンロードしておくと速い）
- `cookEveryFrameIfAsked` — 出力をどこかで使って（表示して）いないと翻訳が進まない

## 実装メモ（重要なワークアラウンド2つ）

1. **TranslationSession は SwiftUI 専用**（公開イニシャライザ無し・.translationTask 経由のみ）。
   ヘルパ内で**ほぼ不可視の 2x2px・alpha 0.01 のウインドウ**に NSHostingView を貼り、
   translationTask のクロージャ内でワークキューを回し続けてセッションを保持する。
   完全な画面外や alpha 0 だと task が発火しないので注意
2. **TD は同一パスの plugin バイナリ/依存 dylib をプロセス内でキャッシュ**するため、
   開発中の反復はビルドごとに dylib 名を変える（build.sh が自動で行う）＋
   プラグインをバージョン付きパスにコピーしてロードする。通常利用では気にしなくてよい

## ビルド

```
./build.sh    # → build/TranslateDAT.plugin（Swift ヘルパ dylib 同梱）
```
