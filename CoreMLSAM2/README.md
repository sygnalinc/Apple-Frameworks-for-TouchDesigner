# CoreML SAM2 TOP

Apple公式変換の **SAM 2.1(Segment Anything Model 2)** で、**指定した点にある任意の
オブジェクトのマスク**を生成する。VisionSubject(全被写体自動)と違い「どれを抜くか」を
Prompt Point で指定できる。マウス/タッチ座標を流せば「観客が触れたものを切り抜く」演出に。

## 実測(M2・tiny・OilDrums 1280x720)

- 画像エンコード **約390ms**(フレーム変化時のみ)・マスクデコード **約40ms**(プロンプト
  変化時のみ)→ 静止画では**点を動かすだけで25fps級のインタラクティブ選択**
- 初回はANEコンパイルで数秒〜十数秒(2回目以降キャッシュ)
- 点を左端のドラム缶→中央の赤いドラム缶へ移動すると、それぞれ単体が正しく選択された
  (score 0.99 / 0.74)

## モデルの入手

```
https://huggingface.co/apple/coreml-sam2.1-tiny   (3点セット・計80MB)
→ *ImageEncoder*.mlpackage / *PromptEncoder*.mlpackage / *MaskDecoder*.mlpackage を
  同じフォルダ(例 models/)に置き、Model Folder に指定(名前パターンで自動発見)
small/baseplus/large も同名パターンなら差し替え可能。
```

## 出力

最高スコア候補のソフトマスク(sigmoid・**Mono32Float・256x256**)。
入力解像度に合わせるには Fit TOP、硬いマスクは Threshold TOP。

## パラメータ

| 名前 | 内容 |
|---|---|
| Model Folder | 3モデルが入ったフォルダ |
| Prompt Point | 選択したい位置(uv・左下原点) |
| Use Background Point / Background Point | 除外したい位置(誤選択の抑制) |
| Compute Units | All / CPU+GPU |
| Flip Image Vertically | 既定On(必須) |

Info CHOP: `executes / submits / analyzes / encode_ms / decode_ms / score / loaded`

## 注意

- **プロンプト座標はモデル内部で1024x1024ピクセル空間**(正規化0〜1ではない・実測)。
  プラグイン内で変換済みなのでパラメータはuvのままでよい
- 入力は1024x1024にsquashリサイズされる(アスペクト比は歪むが座標対応は単純)
- 動画入力では毎フレーム再エンコード(約2.5fps)。リアルタイム追従には
  VisionTrack で追った点を Prompt Point に食わせる合わせ技が有効

## ビルド

```
cd CoreMLSAM2 && ./build.sh   # → build/CoreMLSAM2TOP.plugin
```
