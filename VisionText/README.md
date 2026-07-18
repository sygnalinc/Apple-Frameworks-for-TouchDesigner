# Vision Text DAT — OCR / テキスト認識（macOS）

TOP の映像から文字（`VNRecognizeTextRequest`）を認識し、テキスト領域ごとに
テーブル出力する TD ネイティブのカスタム DAT。日本語・英語ほか多言語・完全オンデバイス。

実測: Text TOP の日英混在テキスト（AIR BAND 2026 / エアバンド採点中 / SCORE 88421）を
全行正しく認識。

## 出力テーブル

```
text            | confidence | u      | v      | width  | height
AIR BAND 2026   | 1.000      | 0.4984 | 0.6361 | 0.6000 | 0.1111
エアバンド採点中 | 0.500      | ...
```

- 1行 = 1テキスト領域。u,v は領域バウンディングボックスの**中心**（0〜1・左下原点）
- 行は**読み順**（上→下、同じ高さは左→右）

## パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| TOP | — | 解析する映像の TOP パス |
| Active | On | 解析の有効/無効 |
| Recognition Level | Accurate | Accurate（高精度・1解析 100ms 級）/ Fast（低精度・高速） |
| Languages | ja-JP en-US | 認識言語（空白区切り・優先順）。空なら Vision の既定 |
| Language Correction | On | 言語モデルによる補正 |
| Min Confidence | 0.3 | これ未満の信頼度の領域は出力しない |
| Flip Image Vertically | **On** | TD の TOP ダウンロードは上下逆のため既定 On |

Info CHOP: `executes / submits / analyzes / regions / analyze_ms`。

## 注意

- `cookEveryFrameIfAsked` — 出力をどこかで使って（表示して）いないと解析が回らない
- 日本語の認識言語指定は `ja-JP` を Languages の先頭に置くと精度が上がる

## ビルド

```
./build.sh    # → build/VisionTextDAT.plugin
```
