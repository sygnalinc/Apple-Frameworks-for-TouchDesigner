# TouchDesigner MCP での実データ検証

ビルドが通っただけでは終わり。**TD MCPで実データまで検証**して初めて完成。

## 検証項目(最低ライン)

1. プラグインがロードされ、カスタムパラメータが生成され、**エラー・警告なし**
2. 出力の**構造**が正しい(CHOPのch数/ch名、DATの行列、TOPの解像度/フォーマット)
3. 出力の**値**が妥当:
   - **TOP** → `render`(旧 get_top_image)で**視認**。深度マップ・マスク・切り抜き等を目で確認
   - **CHOP** → 値をevalして妥当性(例 頭 y≈0.85・足 y≈0.24、440Hz正弦波で centroid=440Hz)
   - **DAT** → テーブル内容を読む(分類ラベル・bbox・payload)
4. **実測値(fps / 生成秒数 / 解像度 / ms)を取り、READMEに書く**。M2 での値を基準とする
5. Info CHOP の `analyzes` が `executes` に追従(フレーム落ちなし)を確認

## 主なMCPツール

- `mcp__touchdesigner__run` — TD内Python実行(検証の主力)
- `mcp__touchdesigner__render` — TOPの画像を取得して視認
- `mcp__touchdesigner__inspect` / `read` / `list` / `map` — ノード状態・値・ネットワーク構造
- `mcp__touchdesigner__create` / `edit` / `set` / `wire` — 検証用ノードの組み立て
- `mcp__touchdesigner__observe` / `docs`

## run(Python実行)ツールの癖 — 必読

- **複数行コードは戻り値が返らない**。値が欲しいときは**単一式**で書く
  (例 `op('x').numChans` のように1式で評価)
- **genexpr / ネストしたdef は外側変数を見られない**。ヘルパ関数を定義せずインラインで書く
- **`time.sleep` は cook を止める**。待ちは run 内 sleep ではなく、**Bash側の sleep ループ**で
  時間を置いてから再度evalする
- 検証ノードは `_codex_*` 等の接頭辞で作り、**検証後に必ず全削除**する
  (`/project1` に検証ノードを残さない)

## テスト素材

- カメラ不要の映像テストは分散素材(5人・5ゾーン級)をループ再生
- 音声テストは `say -v Kyoko` で生成。音楽はTD同梱サンプル
- QR等が要るテストは CoreImage Code TOP で生成して入力(著作物mp3の同梱は避ける)
- 実写真セット(Photogrammetry)は Middlebury templeRing 等の非著作データセット

## 検証しきれないものは正直に書く

- 実機依存(GameControllerの実パッド、Denoiseの対応ハード、iPhone実機Multipeer)や
  素材依存(犬猫のAnimalPose、放物体のTrajectory)は「ビルド・ロード・出力構造は検証済み、
  実値は未検証」と README / 作業ログに明記する。**検証したフリをしない**
