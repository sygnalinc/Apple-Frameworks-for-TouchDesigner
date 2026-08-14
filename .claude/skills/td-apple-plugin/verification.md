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
- **exec スコープなので、内包表記やネストした def から「外側で定義した変数」が見えない**
  (`NameError`)。回避は2択:
  1. 短いものはインラインで書く(ヘルパ関数を作らない)
  2. **処理全体を1つの関数に入れて最後に呼ぶ**。関数のローカル同士なら普通に見えるので、
     長いスクリプトはこちらが確実
     ```python
     def build():
         w, h = 720, 1280
         for i in range(8):
             ...            # w, h が見える
     build()
     ```
- **`time.sleep` は cook を止める**。待ちは run 内 sleep ではなく、**Bash側の sleep ループ**で
  時間を置いてから再度evalする
- 検証ノードは `_codex_*` 等の接頭辞で作り、**検証後に必ず全削除**する
  (`/project1` に検証ノードを残さない)

## TDのノード操作でつまずくところ

- **カスタムOPの生成は `create('<OpType>TOP', name)`**(先頭大文字の opType + FAMILY大文字の
  文字列)。`create(coretextTOP, ...)` のような Python 型定数は**カスタムOPには存在しない**
  → `NameError`。標準OPだけが `coretextTOP` 形式の定数を持つ
- **base COMP を親側のTOPに繋ぐ**ときは `connect(comp)` ではなく
  **`connect(comp.outputConnectors[0])`**(`connect(comp)` は型エラー)。
  COMPに出力コネクタが出るのは、中に Out TOP がある場合
- **シーケンスのブロック追加は `op.seq.<name>.numBlocks = N`**。
  `op.par.<name> = N` では増えない(ヘッダparの値は「追加ブロック数」なので0のまま見える)
- `par.pixeldat` などのOP参照パラメータは、**OPオブジェクトではなくパス文字列**を入れると確実
- `glslmultiTOP` を Python で create すると `<name>_pixel/_info/_compute` が**自動でドック生成**
  される。自分で同名DATを作ると `_pixel1` にリネームされるので、**自動生成された方に書く**

## demo.toe の利用例コンテナは cook が止めてある

`demo.toe` の各利用例(base COMP)は **`allowCooking = False`** が既定
(全部を常時 cook すると全例のML推論が同時に走るため)。この状態では:

- 中の Movie File In は **128x128 のまま**(=非ロード)
- MCP から `cook(force=True)` しても**中身は cook されない**
- CHOP から読めた値は**前に cook されたときの残留値**。実測と勘違いしやすい

検証するときは **一時的に True にして cook → 確認 → False に戻す**:

```python
c = op('/project1/VisionFace')
c.allowCooking = True
...  # cook して確認
c.allowCooking = False
```

## テスト素材

- カメラ不要の映像テストは分散素材(5人・5ゾーン級)をループ再生
- 音声テストは `say -v Kyoko` で生成。音楽はTD同梱サンプル
- QR等が要るテストは CI Code TOP で生成して入力(著作物mp3の同梱は避ける)
- 実写真セット(Photogrammetry)は Middlebury templeRing 等の非著作データセット

## 検証しきれないものは正直に書く

- 実機依存(GameControllerの実パッド、Denoiseの対応ハード、iPhone実機Multipeer)や
  素材依存(犬猫のAnimalPose、放物体のTrajectory)は「ビルド・ロード・出力構造は検証済み、
  実値は未検証」と README / 作業ログに明記する。**検証したフリをしない**
