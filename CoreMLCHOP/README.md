# CoreML (CHOP)

**English** | [日本語](#日本語)

> The operator is named **CoreML** (family = CHOP). The general-purpose Core ML TOP / CHOP / DAT
> all share the opType `Coreml` and are told apart by family (colour). Image → image is
> [CoreML TOP](../CoreML/); detection → table is [CoreML DAT](../CoreMLDAT/).
>
> OP名は **CoreML**(family=CHOP)。汎用CoreML推論の TOP/CHOP/DAT は同じ opType `Coreml` に統一され、
> family(色)で区別する。画像→画像は [CoreML TOP](../CoreML/)、検出→テーブルは [CoreML DAT](../CoreMLDAT/)。

## English

Runs any Core ML model with a single image input and flattens its `MLMultiArray` output into CHOP
channels. Aimed at embeddings, keypoints, logits and custom pose models.

The output is `valid / count / value0 ... value{Max Values-1}`. `count` is the model's total
element count; anything past Max Values is dropped. The Info DAT lists the input and every
output spec, the selected feature name, the original shape, the total element count and how many
were returned. If Output Feature Name is empty the first MultiArray output is used.

| Parameter | Description |
|---|---|
| TOP | Image input |
| Active | Inference On/Off |
| Model File | `.mlpackage` / `.mlmodel` / `.mlmodelc` |
| Reload Model | Recompile and reload |
| Compute Units | All / CPU+GPU / CPU Only / CPU+ANE |
| Input Scaling | Scale Fill / Center Crop / Scale Fit |
| Output Feature Name | Feature name when the model has several outputs; empty = the first |
| Max Values | CHOP output limit. Default 256, maximum 65536 |
| Flip Image Vertically | Default On |

Info CHOP: `executes / submits / analyzes / loaded / inference_ms / total_values /
returned_values`. Compiled models are cached in `~/Library/Caches/TDAppleML/`.

**MultiArray values are flattened in the model's own memory order.** Consult the model's spec for
the shape and what each axis means. Models with image output, dictionary output, or more than one
required non-image input are out of scope.

### Build

```sh
cd CoreMLCHOP && ./build.sh
```

## 日本語

画像入力を1つ持つ任意のCore MLモデルを実行し、`MLMultiArray`出力をCHOPへフラット化する
汎用オペレータ。埋め込み、キーポイント、ロジット、カスタム姿勢モデル向け。

出力は`valid / count / value0 ... value{Max Values-1}`。`count`はモデルの全要素数で、
Max Valuesを超える分は切り捨てる。Info DATに入力・全出力仕様、選択feature名、元shape、
全要素数と返却数を出す。Output Feature Nameが空なら最初のMultiArray出力を使用する。

| パラメータ | 内容 |
|---|---|
| TOP | 画像入力 |
| Active | 推論On/Off |
| Model File | `.mlpackage/.mlmodel/.mlmodelc` |
| Reload Model | 再コンパイル・再ロード |
| Compute Units | All / CPU+GPU / CPU Only / CPU+ANE |
| Input Scaling | Scale Fill / Center Crop / Scale Fit |
| Output Feature Name | 複数出力時のfeature名。空なら最初 |
| Max Values | CHOP出力上限。既定256、最大65536 |
| Flip Image Vertically | 既定On |

Info CHOPは`executes/submits/analyzes/loaded/inference_ms/total_values/returned_values`。
モデルコンパイル結果は`~/Library/Caches/TDAppleML/`にキャッシュする。

**MultiArrayの値はモデルのメモリ順をそのままフラット化する。** shapeと軸の意味はモデル仕様を
参照すること。画像出力、辞書出力、複数の非画像入力が必須のモデルは対象外。

### ビルド

```sh
cd CoreMLCHOP && ./build.sh
```
