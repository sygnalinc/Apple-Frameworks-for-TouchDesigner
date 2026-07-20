# CreateML Motion DAT

録画した**時系列CHOP系列**(VisionPose 等の関節チャンネル + `label` 列 + `recording` 列)の
CSV から、**動き/ジェスチャの分類モデル**を CreateML(`MLActivityClassifier`)で
**オンデバイス学習**し `.mlmodel` を書き出す。出力モデルは [CoreML Motion CHOP](../CoreMLMotion/)
でライブ推論する。TD内で「動きを録る→ラベル付け→学習→リアルタイム認識」を完結できる。

- 学習は Swift ヘルパで**非同期**実行。cook は進捗を poll するだけでブロックしない
- 入力は**フラットCSV**(1行=1フレーム)。収録IDでグループ化して内部でシーケンス列テーブルへ変換
- 特徴列は**任意**(VisionPose の `body1/nose:u` 等をそのまま列名に)。空欄で label/recording 以外を自動採用

## 実測(M2)

- 合成4特徴(x0,y0,x1,y1)・30収録×80フレーム・3クラス(circle/wave/still)で学習 →
  **done・約1秒**、`.mlmodel`(約983KB)を出力
- 出力モデルを CoreML Motion CHOP でライブ推論し、circle→`prob_circle=1.0`、wave→`prob_wave=1.0` を確認
- 実運用では VisionPose の 68ch(34関節×u,v)を特徴にすれば分離はさらに明確になる

## 使い方

1. VisionPose 等の CHOP を録画して CSV 化する。列は例:
   `recording,label,body1/nose:u,body1/nose:v,...`(1行=1フレーム、`recording` は動作1回ごとに別ID)
2. `Training CSV` にそのCSVを指定
3. `Output Model` に書き出す `.mlmodel` パスを指定
4. `Label Column` / `Recording ID Column` を合わせる(既定 `label` / `recording`)
5. `Feature Columns` は空欄で自動(label/recording 以外の全列)。特定列だけならカンマ区切りで指定
6. **Train** をパルス → 学習開始。完了後、出力 `.mlmodel` を **CoreML Motion CHOP** の Model に指定

## 出力(テーブルDAT)

| key | value |
|---|---|
| status | idle / training / done / error / cancelled |
| progress | 0..1 |
| train_accuracy / validation_accuracy | 学習/検証精度 |
| features | 使用した特徴列 |
| model | 書き出した .mlmodel パス |
| error | エラー内容 |

Info CHOP: `executes / progress / train_accuracy / validation_accuracy / training / done`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Training CSV | 録画した時系列CHOPのCSV(1行=1フレーム) |
| Output Model | 書き出す .mlmodel パス |
| Feature Columns | 特徴列(カンマ区切り、空=label/recording以外を自動) |
| Label Column | ラベル列名(既定 label) |
| Recording ID Column | 収録ID列名(既定 recording。動作1回ごとに別ID) |
| Prediction Window | 予測窓フレーム数(既定30)。CoreML Motion CHOP と揃える |
| Max Iterations | 学習反復回数(既定25) |
| Train / Cancel | 学習の開始 / 中断(パルス) |

## 注意

- **CreateML は Swift/Combine専用** → helper dylib 経由(ObjC++から直接不可)
- **`MLActivityClassifier` はフラット表を受け付けない**。特徴列がシーケンス型(1収録=1行、
  各特徴が `[Double]`)のテーブルを要求する。ヘルパが収録IDでグループ化して変換している
- `recording` 列は**動作1回ごとに別ID**にする(全フレーム同一IDだと1サンプル扱いで学習不能)
- 1クラスあたり最低10収録程度。`Prediction Window` は推論側と必ず一致させる
- ラベルの偏り・収録数不足だと validation が割れる。実データは VisionPose の全関節を特徴に

## ビルド

```
cd CreateMLMotion && ./build.sh   # → build/CreateMLMotionDAT.plugin(Swiftヘルパ同梱)
```
