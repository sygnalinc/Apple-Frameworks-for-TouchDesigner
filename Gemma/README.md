# Gemma DAT

Google Gemma 4をTouchDesignerからローカル実行するDAT。`llama-server`のOpenAI互換APIへ非同期接続し、生成中のテキストを会話テーブルへストリーミングする。モデルはリポジトリへ含めない。

## 構成と実測

- 推奨開始モデル: Gemma 4 E2B Instruct Q4（モデルメモリ目安2.9GB）またはE4B Q4（4.5GB）
- 12B Q4は約6.7GB、26B-A4B Q4は約14.4GB、31B Q4は約17.5GB。TDとの同時利用では空きユニファイドメモリを確保する
- Apple Siliconではllama.cppのMetal GPUオフロードを使用（`GPU Layers=99`）
- 実測速度はモデル取得後、対象Macで追記する

## セットアップ

```sh
brew install llama.cpp
```

公式GGUF（例: `ggml-org/gemma-4-E2B-it-GGUF`）をHugging Faceから取得し、`GGUF Model Path`へ指定する。`Start Local Server`を押し、Info DATが`server starting`になった後に`Submit`する。すでにサーバーを起動している場合は`Endpoint`だけ設定すればよい。

## 出力

| 列 | 内容 |
|---|---|
| index | 会話ターン番号 |
| role | `user` / `assistant` |
| text | 入力またはストリーミング生成結果 |

Info CHOP: `executes`, `busy`, `turns`, `server`。Info DAT: `status`。

## 注意

- 完全ローカル。Google APIキーは不要
- モデルファイルはGit/LFSへ追加しない
- 音声入出力などGemma 4の全モダリティではなく、初期版はテキスト会話を対象とする
- TDは出力が参照されないとcookしないため、生成中はDATを表示するかDAT Execute等で毎フレームcookさせる

## ビルド

`./build.sh` → `build/GemmaDAT.plugin`
