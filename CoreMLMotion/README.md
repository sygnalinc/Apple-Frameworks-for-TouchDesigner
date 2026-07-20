# CoreML Motion CHOP

[CreateML Motion DAT](../CreateMLMotion/) で学習した**動作分類モデル**(`MLActivityClassifier`)を
ロードし、入力CHOP(VisionPose 等のチャンネル)を**予測窓ぶんバッファしてライブでジェスチャ分類**する。
出力はクラスごとの確率 + confidence + predicted(argmax index)。recurrent state を毎フレーム更新する。

- 推論は CoreML(ANE/GPU)。cook は最新窓を渡すだけでブロックしない
- モデルの入力記述から**特徴チャンネル名・予測窓・クラスラベルを自動取得**。手動設定不要
- 入力CHOPのチャンネル名をモデルの特徴名と**名前一致**でマッチ(VisionPose 等をそのまま接続)

## 実測(M2)

- CreateML Motion で学習した3クラスモデル(circle/wave/still・窓30)をロード
- ライブの円運動入力 → `prob_circle=1.0` / `confidence=1.0` / `predicted=0`
- 横振動(wave)入力 → `prob_wave=1.0` / `predicted=2`。ジェスチャの切替をリアルタイムに追従

## 使い方

1. 分類したい CHOP(例 VisionPose)を入力に接続。**学習時と同じチャンネル名**であること
2. `Model` に CreateML Motion DAT が書き出した `.mlmodel` を指定
3. バッファが窓(`buffered` が Prediction Window)に達すると予測が始まる
4. `prob_<class>` の最大クラスが現在のジェスチャ。`Reset` でバッファ/状態をクリア

## 出力(CHOP)

| チャンネル | 説明 |
|---|---|
| prob_&lt;class&gt; | クラスごとの確率(学習モデルのクラス数ぶん) |
| confidence | 最尤クラスの確率 |
| predicted | 最尤クラスの index(argmax) |
| buffered | 現在バッファ済みフレーム数(窓に達すると予測開始) |

Info CHOP: `executes / predictions / window / num_classes`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Model | CreateML Motion で学習した .mlmodel |
| Reset | バッファと recurrent state をクリア(パルス) |

## 注意

- **入力チャンネル名は学習CSVの特徴列名と一致**が必須(名前でマッチ)。不一致の特徴は0で埋まる
- **予測窓は学習時と同じ**になる(モデル記述から自動取得)。窓が埋まるまで `buffered < window` は無出力
- state 入力(recurrent)を持つモデルは `stateOut` を毎回フィードバック。ジェスチャ切替直後は
  数フレーム前の窓の影響が残る。明示的に切りたい場合は `Reset`
- `.mlmodel` はコンパイルキャッシュ(`~/Library/Caches/TDAppleML/`)経由で読む

## ビルド

```
cd CoreMLMotion && ./build.sh   # → build/CoreMLMotionCHOP.plugin
```
