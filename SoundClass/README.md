# Sound Class CHOP — 音の分類（macOS / SoundAnalysis）

オーディオ CHOP 入力（Audio Device In / Audio File In 等）をストリーム解析し、
**笑い声・拍手・歓声・犬の鳴き声・警報音など300種類以上**の音分類
（`SNClassifySoundRequest`・Apple 組込みモデル）の信頼度をチャンネル出力する。
**独自の Core ML 音響分類モデル（.mlmodel / .mlmodelc）への差し替えも可能**。

実測（M2 / TD 標準の音楽サンプル）: `music 0.83 / synthesizer 0.65 / ...` と的確に分類。

## 出力

- `Classes` パラメータに列挙したクラスID（空白区切り）ごとに1チャンネル（信頼度 0〜1）
- **全クラスのランキング上位10は Info DAT に出る** — クラスIDが分からなくても、
  実際に音を鳴らして Info DAT を見ながら欲しいIDを拾って `Classes` に足せばよい
- 結果の更新間隔は `Window (sec) × (1 - Overlap)`（既定 1秒×0.5 = 0.5秒ごと）。
  チャンネルは最新値を保持する（滑らかにしたい場合は後段に Lag/Filter CHOP）

クラスIDの例: `applause cheering laughter music speech singing shout whistling
finger_snapping dog cat siren car_horn knock door telephone_bell ...`

## パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| Active | On | 解析の有効/無効 |
| Classes | applause cheering laughter music speech | 出力するクラスID（空白区切り） |
| Custom Core ML Model | — | 独自の音響分類モデル。`.mlmodel` はロード時に自動コンパイル |
| Window (sec) | 1.0 | 解析ウィンドウ長（短いほど反応が速く精度は下がる） |
| Overlap Factor | 0.5 | ウィンドウの重なり（大きいほど更新が細かい） |

## 注意

- 入力はチャンネル0のみ使用（ステレオはミックスせず L を見る。必要なら前段で Math CHOP 等でモノ化）
- 本 CHOP は `cookEveryFrameIfAsked` — **出力をどこかで使って（表示して）いないと cook されず
  音声が流れない**。エクスポート/参照/CHOP Execute 等で毎フレーム評価される状態で使うこと
- Info CHOP（動作診断）: `executes / results / samplerate`。`results` が増えていれば解析が回っている

## ビルド

```
./build.sh    # → build/SoundClassCHOP.plugin
```

使い方は [ルート README](../README.md) 参照（CPlusPlus CHOP でロード or Plugins フォルダへ）。
