# examples 用の学習データ

`sample.toe` の `/project1/examples` にある **CreateML** / **CoreML Motion** の利用例が使う
学習データ。学習済みモデル(`.mlmodel`)は規約によりコミットしないので、以下で再生成する。

| ファイル | 用途 |
|---|---|
| `sample_tabular.csv` | CreateML 例の Tabular Classifier 学習データ(f1,f2 → target A/B/C) |
| `sample_motion.csv` | CoreML Motion 例の動作モデル学習データ(x0,y0,x1,y1 → circle/wave/still) |
| `sample_motion.mlmodel` | 上記から学習した動作モデル(**gitignore**・下記で再生成) |

## モデルの再生成(CoreML Motion 例)

1. `CreateML` DAT を1つ作る(または examples/CreateML を流用)
2. `Task` = **Activity Classifier**、`Training Path` = `Assets/ml_examples/sample_motion.csv`
3. `Output Model` = `Assets/ml_examples/sample_motion.mlmodel`、`Label Column` = `label`、
   `Recording ID Column` = `recording`
4. **Train** をパルス → 完了後、examples/CoreMLMotion の `Coremlmotion1` が読み込む

CreateML 例(Tabular)は `sample_tabular.csv` を直接使い、Train パルスで即学習できる。
