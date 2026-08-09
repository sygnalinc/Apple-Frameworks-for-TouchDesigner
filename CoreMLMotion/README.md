# CoreML Motion CHOP

**English** | [日本語](#日本語)

## English

Loads an **activity classification model** (`MLActivityClassifier`) trained with the
[CreateML DAT](../CreateML/) (Activity task) and **classifies gestures live** by buffering the
input CHOP (Vision Pose channels and the like) over the prediction window. The output is a
probability per class plus confidence and predicted (argmax index). Recurrent state is updated
every frame.

- Inference runs on Core ML (ANE/GPU). Cook only hands over the latest window and never blocks
- The **feature channel names, prediction window and class labels are read from the model
  description** — no manual setup
- Input CHOP channels are matched to the model's feature names **by name** (connect Vision Pose
  directly)

### Measured (M2)

- Loaded a 3-class model (circle/wave/still, window 30) trained with CreateML
- Live circular motion → `prob_circle=1.0` / `confidence=1.0` / `predicted=0`
- Horizontal oscillation (wave) → `prob_wave=1.0` / `predicted=2`. Gesture switches are tracked
  in real time

### Usage

1. Connect the CHOP to classify (e.g. Vision Pose) to the input. **Channel names must match
   training**
2. Point `Model` at the `.mlmodel` written by CreateML
3. Prediction starts once the buffer reaches the window (`buffered` = Prediction Window)
4. The largest `prob_<class>` is the current gesture. `Reset` clears the buffer and state

### Output (CHOP)

| Channel | Description |
|---|---|
| prob_&lt;class&gt; | Probability per class (as many as the model has) |
| confidence | Probability of the most likely class |
| predicted | Index of the most likely class (argmax) |
| buffered | Frames currently buffered (prediction starts when it reaches the window) |

Info CHOP: `executes / predictions / window / num_classes`

### Parameters

| Parameter | Description |
|---|---|
| Model | The `.mlmodel` trained with CreateML |
| Reset | Clear the buffer and recurrent state (pulse) |

### Notes

- **Input channel names must match the feature column names of the training CSV** (matching is by
  name). Features that don't match are filled with 0
- **The prediction window is whatever training used** (read from the model description). Nothing
  is output while `buffered < window`
- Models with a recurrent state input have `stateOut` fed back every frame, so right after a
  gesture change the previous window still influences the result. Use `Reset` to cut it off
- `.mlmodel` files are read through the compile cache (`~/Library/Caches/TDAppleML/`)

### Build

```
cd CoreMLMotion && ./build.sh   # → build/CoreMLMotionCHOP.plugin
```

## 日本語

[CreateML DAT](../CreateML/)(Activity タスク)で学習した**動作分類モデル**(`MLActivityClassifier`)を
ロードし、入力CHOP(VisionPose 等のチャンネル)を**予測窓ぶんバッファしてライブでジェスチャ分類**する。
出力はクラスごとの確率 + confidence + predicted(argmax index)。recurrent state を毎フレーム更新する。

- 推論は CoreML(ANE/GPU)。cook は最新窓を渡すだけでブロックしない
- モデルの入力記述から**特徴チャンネル名・予測窓・クラスラベルを自動取得**。手動設定不要
- 入力CHOPのチャンネル名をモデルの特徴名と**名前一致**でマッチ(VisionPose 等をそのまま接続)

### 実測(M2)

- CreateML で学習した3クラスモデル(circle/wave/still・窓30)をロード
- ライブの円運動入力 → `prob_circle=1.0` / `confidence=1.0` / `predicted=0`
- 横振動(wave)入力 → `prob_wave=1.0` / `predicted=2`。ジェスチャの切替をリアルタイムに追従

### 使い方

1. 分類したい CHOP(例 VisionPose)を入力に接続。**学習時と同じチャンネル名**であること
2. `Model` に CreateML DAT が書き出した `.mlmodel` を指定
3. バッファが窓(`buffered` が Prediction Window)に達すると予測が始まる
4. `prob_<class>` の最大クラスが現在のジェスチャ。`Reset` でバッファ/状態をクリア

### 出力(CHOP)

| チャンネル | 説明 |
|---|---|
| prob_&lt;class&gt; | クラスごとの確率(学習モデルのクラス数ぶん) |
| confidence | 最尤クラスの確率 |
| predicted | 最尤クラスの index(argmax) |
| buffered | 現在バッファ済みフレーム数(窓に達すると予測開始) |

Info CHOP: `executes / predictions / window / num_classes`

### パラメータ

| パラメータ | 説明 |
|---|---|
| Model | CreateML で学習した .mlmodel |
| Reset | バッファと recurrent state をクリア(パルス) |

### 注意

- **入力チャンネル名は学習CSVの特徴列名と一致**が必須(名前でマッチ)。不一致の特徴は0で埋まる
- **予測窓は学習時と同じ**になる(モデル記述から自動取得)。窓が埋まるまで `buffered < window` は無出力
- state 入力(recurrent)を持つモデルは `stateOut` を毎回フィードバック。ジェスチャ切替直後は
  数フレーム前の窓の影響が残る。明示的に切りたい場合は `Reset`
- `.mlmodel` はコンパイルキャッシュ(`~/Library/Caches/TDAppleML/`)経由で読む

### ビルド

```
cd CoreMLMotion && ./build.sh   # → build/CoreMLMotionCHOP.plugin
```
