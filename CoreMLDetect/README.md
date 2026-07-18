# CoreMLDetect DAT

任意の**物体検出 Core ML モデル**(YOLOv3 等)をロードし、入力 TOP の映像から
「**何が・どこに**」を検出してテーブル出力する汎用オペレータ。

役割分担: [CoreML TOP](../CoreML/) は画像/配列出力モデル(深度・スタイル変換等)、
[CoreML CHOP](../CoreMLCHOP/) はベクトル出力モデル、本DATは検出モデル
(`VNRecognizedObjectObservation` を返すもの)を担当。

## 実測(M2・YOLOv3Int8LUT・416x416入力)

- 推論 **約38ms ≈ 26fps**(単独実行時)。バナナ画像で `banana` confidence 0.994
- **他のANE系プラグイン(LLSR等)と同時実行するとANE競合で数倍遅くなる**
  (実測: 同時実行で262ms)。重いML系は同時に走らせすぎない

## モデルの入手

```
https://huggingface.co/apple/coreml-YOLOv3
→ YOLOv3Int8LUT.mlmodel(62MB・COCO 80クラス)を models/ に置き、Model File に指定
```

Ultralytics 等で Core ML 変換した YOLOv8/v11(NMS込みエクスポート)もそのまま使える。

## 出力テーブル

| 列 | 内容 |
|---|---|
| rank | 信頼度順 1始まり |
| label | クラス名(モデル依存。COCO なら person/car/banana 等) |
| confidence | 信頼度 0〜1 |
| u, v | bbox 中心(uv・左下原点 = VisionTrack と同じ規約) |
| w, h | bbox サイズ(uv) |

## パラメータ

| 名前 | 内容 |
|---|---|
| TOP | 入力 TOP |
| Model File | `.mlmodel` / `.mlpackage` / `.mlmodelc` のパス |
| Reload Model | 再読み込み(パルス) |
| Compute Units | All / CPU+GPU / CPU Only / CPU+ANE |
| Input Scaling | Scale Fill(既定)/ Center Crop / Scale Fit |
| Max Detections | 最大検出数(1〜100・既定20) |
| Min Confidence | これ未満は出力しない(既定0.25) |
| Flip Image Vertically | 入力の上下反転(既定On・必須) |

## Info CHOP

`executes / submits / analyzes / analyze_ms / detections / loaded`

## 注意

- **NMS(重複除去)込みでエクスポートされたモデルが対象**。生テンソルを出す検出モデル
  (NMSなしのYOLO等)は `VNRecognizedObjectObservation` にならないため警告が出る
- 検出モデル以外を読ませた場合も警告で知らせる(その場合は CoreML TOP/CHOP を使う)
- モデルのコンパイル結果は `~/Library/Caches/TDAppleML/` に共有キャッシュされる

## ビルド

```
cd CoreMLDetect && ./build.sh   # → build/CoreMLDetectDAT.plugin
```
