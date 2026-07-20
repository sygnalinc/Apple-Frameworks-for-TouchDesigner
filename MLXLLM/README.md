# MLX LLM DAT

Apple の **MLX** フレームワーク（[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)）で
Gemma / Qwen / Llama 等の量子化LLMを **完全ローカル・オンデバイス**で走らせる DAT。
API課金なし・オフライン動作（モデルは初回のみ Hugging Face から自動ダウンロード）。

## AFM Core との違い

| | AFM Core DAT | MLX LLM DAT |
|---|---|---|
| バックエンド | Apple Intelligence（FoundationModels） | Apple MLX（mlx-swift-lm） |
| モデル | 端末付属の固定 ~3B | 任意の mlx-community モデル（Gemma 4 等）を選択 |
| 有効化 | 設定でApple Intelligenceが必要 | 不要（Apple Siliconのみ） |
| ダウンロード | OSが管理 | 初回のみHFから取得（`~/.cache/huggingface` 等） |

## アーキテクチャ

重い推論（Metal・多GBモデル）は同梱の**ヘルパ実行ファイル `mlxllm-helper` を別プロセス**
として起動し、JSON-lines プロトコルで通信する。理由:

- MLX の Metal リソースバンドル（`mlx-swift_Cmlx.bundle`）解決や rpath が dylib 同梱だと壊れやすい
- 多GBモデル + Metal をプロセス隔離し、クラッシュ/OOMでTDを巻き込まない
- 停止時にモデルのメモリを確実に解放できる

cook は絶対にブロックしない: ヘルパの stdout はワーカースレッドで読み、最新状態を出力する。

## 出力

会話履歴テーブル `index | role | text`。user / assistant が交互に並び、生成中は最後の
assistant 行がトークンで伸びる。Info CHOP は `executes / busy / ready / progress / turns`、
Info DAT は `status`。

## パラメータ

| パラメータ | 説明 |
|---|---|
| Model | mlx-community のリポジトリID（既定 `mlx-community/gemma-4-e2b-it-4bit`） |
| System Instructions | システムプロンプト |
| Prompt | 入力 |
| Temperature | 0〜2（既定 0.7） |
| Max Tokens | 生成上限（既定 512） |
| Keep Context | オンでマルチターン（会話文脈を保持） |
| Max Rows | 出力する会話履歴の最大行数 |
| Load Model | モデルをロード（初回はダウンロード） |
| Submit | 生成 |
| Reset Conversation | 会話文脈をリセット |

## 使い方

1. Model に mlx-community のモデルIDを入れる（既定は最小の Gemma 4 E2B 4bit）
2. **Load Model** をパルス → 初回は Info DAT の status が `downloading model` になり、
   Info CHOP `progress` が 0→100 へ。完了で `ready`
3. Prompt を書いて **Submit** → assistant 行がストリーミングで伸びる
4. Keep Context オンなら続けて Submit で会話が続く。Reset で文脈クリア

## 実測（M2）

- モデル: `mlx-community/gemma-4-e2b-it-4bit`（E2B・4bit、DL約3.3GB）
- TD内でロード（キャッシュ済み）→ `ready`、Submit で**トークンをストリーミング**しながら
  会話テーブルへ。2文の回答（約35トークン）が**約1秒**＝インタラクティブ速度
- マルチターン（Keep Context）で文脈保持を確認（「Red」→「別の色」→「Blue」）

## 注意

- **Apple Silicon 専用**（MLX は Metal を使う）
- 初回モデルダウンロードに時間がかかる（回線次第）。2回目以降はキャッシュから高速起動
- モデルの量子化・サイズで速度と品質が変わる。大きいモデルはメモリを要する

## ビルド

```sh
./build.sh
```

初回は mlx-swift（Metal）+ swift-syntax（マクロ）のコンパイルで数分〜十数分かかる。
