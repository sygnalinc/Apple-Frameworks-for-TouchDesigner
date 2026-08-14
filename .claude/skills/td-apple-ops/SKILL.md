---
name: td-apple-ops
description: Apple Frameworks for TouchDesigner のカスタムOP(Vision Pose / Vision Face / Vision Hand / CoreML / LLM AFM / LLM MLX / Speech Transcribe / Metal Upscale / Screen Capture 等)を**使って**TouchDesignerのプロジェクトを組むときに使う。導入手順、OPの選び方、非同期OP特有の配線ルール(cookを回す・Info CHOPの読み方・Flip・Aspect Correct UVs)、インスタンシングで映像に重ねる型、モデルの入手、症状別トラブルシュートを網羅。プラグイン自体の実装・改修は td-apple-plugin を使う。
---

# Apple Frameworks for TouchDesigner を使う

macOS のオンデバイスML/メディア機能を TouchDesigner のカスタムOPとして提供する
プラグイン集(`sygnalinc/Apple-Frameworks-for-TouchDesigner`)の **利用者向け** ガイド。

> **プラグインを作る/直す側なら [td-apple-plugin](../td-apple-plugin/SKILL.md) を使うこと。**
> こちらは「既にあるOPでプロジェクトを組む」ためのもの。

## トピック別リファレンス

- [wiring.md](wiring.md) — 全OP共通の配線ルールと定番レシピ(cookを回す・Info CHOP診断・
  Flip・Aspect Correct UVs → Ortho Width=1 のインスタンシング・骨格線・マスク合成)
- [troubleshooting.md](troubleshooting.md) — 症状別の原因と直し方(黒画面・検出0・
  Unknown operator type・invalid opType name・音がノイズ・重い)

## まず確認すること

1. **macOS 専用**。Apple Silicon 推奨。機能によってはより新しい macOS が要る(各READMEに明記)
2. **導入**: [Releases](https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner/releases)
   の DMG から `.plugin` を
   `~/Library/Application Support/Derivative/TouchDesigner099/Plugins/` へコピー →
   **TouchDesigner を再起動**。再起動しないと OP Create Dialog に出ない。
   **必要なものだけコピーするよう勧めること** — TD は次の起動時に**プラグイン1つずつ
   許可ダイアログ**を出すので、全部入れると起動直後に大量のダイアログを閉じることになる
   (許可はプラグインごとに記憶される。あとから足せる)
3. **利用例は `demo.toe`**。`/project1` 直下に 1オペレータ = 1コンテナで並んでいる。
   使いたいOPのコンテナを丸ごとコピーするのが最短
4. **外部モデルが要るOPがある**(CoreML TOP/CHOP/DAT、CoreML SAM2、CoreML ImageGen、LLM MLX)。
   入手先とファイル名は **`models/README.md`** にある。モデル本体はリポジトリに入っていない

## OPの選び方

**ルートREADMEの一覧表を正とする**(ここに転記すると必ず陳腐化する)。
[README.ja.md](../../../README.ja.md) のカテゴリ表から選び、各プラグインの README で
パラメータ・出力仕様・実測値・注意を読む。

TD標準OPの代替を探しているなら、README の「Nvidia専用OPの macOS 代替として」表が出発点:

| やりたいこと | TD標準(Win+NVIDIA) | 代替 |
|---|---|---|
| 人物ポーズ推定 | Body Track CHOP | Vision Pose(チャンネル形式が互換) |
| 超解像アップスケール | Nvidia Upscaler TOP | Metal Upscale |
| オプティカルフロー | Optical Flow TOP | Vision Flow |
| 顔トラッキング | Face Track CHOP | Vision Face |

## 使うときに外さない5つのルール

1. **出力をどこかで使わないと cook されない。**
   全OPが `cookEveryFrameIfAsked`。ビューアも下流も無い状態では動かず、「壊れている」ように
   見える(特に音声・翻訳・LLM系)。Null を置いてビューアをアクティブにするか、
   Execute DAT の `onFrameEnd` で毎フレーム cook させる → [wiring.md](wiring.md)

2. **結果は1〜2フレーム遅れる。**
   推論はワーカースレッドで走り cook をブロックしない設計。厳密な同期が要る用途では
   遅延を見込む。フレーム落ちの有無は **Info CHOP** で確認する(`analyzes` が `executes` に
   追従していれば落ちていない)

3. **`Flip Image Vertically` は Vision/ML 系だけが持ち、既定 On のままでよい。**
   TDのテクスチャは bottom-up なので、これを切ると Vision が検出0になる。
   向きに依存しない Metal Upscale などはそもそもこのパラメータを持たない

4. **uv を映像に重ねるなら `Aspect Correct UVs` を On。**
   On にすると `tx = u-0.5` / `ty = v-0.5` のインスタンシングが
   **カメラの Ortho Width = 1 のまま**ぴったり重なる。Off(既定)は生の0〜1画像座標
   → [wiring.md](wiring.md)

5. **重いML系OPを何個も同時に走らせない。**
   ANE の取り合いで数倍遅くなる(実測: YOLO 38ms→262ms)。必要なときだけ `Active` を入れる

## チャンネル名の書式(検出スロット系)

複数検出のOPは `body{i}` `hand{i}` `face{i}` `animal{i}` のスロットで出す。**区切り文字が2種類ある**:

```
body1:valid                  ← スロット直下は コロン
body1/nose:u                 ← 関節などは スラッシュ + コロン
body1/nose:confidence
```

`body1/valid` は存在しない。ここを間違えると「検出0」と誤診する。

## Non-Commercial 版の制限

無償の Non-Commercial は**解像度が 1280x1280 に制限される**。Metal Upscale・
Cinematic Video・ImageIO File In・CI RAW/HDR・Screen Capture・PDFKit・CoreText は
これを超える出力をしうる。**このリポジトリは NC 環境で検証していない** ので、
問題が出たら出力解像度を下げる。詳細はルートREADMEの「必要環境」節。
