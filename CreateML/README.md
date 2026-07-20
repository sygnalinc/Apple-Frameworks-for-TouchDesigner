# CreateML DAT

Apple の **CreateML** による各種学習タスクを**1つのオペレータに統合**した汎用トレーナ。
`Task` メニューでタスクを切り替え、TD内から**オンデバイス学習**して `.mlmodel` を書き出す。
出力モデルは既存の推論OP([CoreML TOP](../CoreML/) / [CoreML Motion CHOP](../CoreMLMotion/) /
[SoundClass CHOP](../SoundClass/) 等)がそのまま読む。「TD内で集める→ラベル付け→学習→推論」を閉じられる。

- 学習は Swift ヘルパで**非同期**実行。cook は進捗を poll するだけでブロックしない
- 入力は**フォルダ**(ラベル別サブフォルダ)または **CSV**(時系列/表)。Taskごとに使う列/パラメータが変わる
- 進捗・精度・クラス/特徴一覧をテーブル + Info CHOP で表示

## Task 一覧

| Task | CreateMLクラス | 入力 | 用途 / 出力モデルの推論先 |
|---|---|---|---|
| Image Classifier | `MLImageClassifier` | ラベル別**画像フォルダ** | 画像分類 → CoreML TOP |
| Hand Pose Classifier | `MLHandPoseClassifier` | ラベル別**手画像フォルダ** | 手の**形**(静的:ピース/グー) |
| Action Classifier (body) | `MLActionClassifier` | ラベル別**動画フォルダ** | 体の**動き**(CreateMLがVision関節抽出) |
| Hand Action Classifier | `MLHandActionClassifier` | ラベル別**動画フォルダ** | 手の**動き** |
| Sound Classifier | `MLSoundClassifier` | ラベル別**音声フォルダ** | 音分類 → SoundClass CHOP |
| Activity Classifier | `MLActivityClassifier` | **CHOP時系列CSV** | VisionPose/Hand等の数値時系列 → CoreML Motion CHOP |
| Tabular Classifier | `MLClassifier` | **表CSV** | 表データ分類 → CoreML CHOP/DAT |
| Tabular Regressor | `MLRegressor` | **表CSV** | 表データ回帰 |

**ポーズ/ジェスチャの学習ルートは2つ**:
- **フォルダ素材**(Hand Pose / Action / Hand Action): 画像・動画を用意すれば CreateML が自動でVision抽出
- **CHOP録画**(Activity): TDで VisionPose / VisionHand の関節CHOPを録画したCSV。追加素材不要、
  推論は [CoreML Motion CHOP](../CoreMLMotion/) でライブ分類

## 実測(M2)

- **Tabular Classifier**: 合成2特徴×3クラス150行 → **train/val accuracy 1.0**
- **Tabular Regressor**: 合成線形データ → **RMSE 0.12**(metadata付きで書き出し)
- **Activity**: 30収録×80フレーム×4特徴×3クラス → **train 1.0 / val 0.571**、特徴列を自動検出
- **Image**: 3クラスの縞パターン → 学習完走、クラス(checker/horizontal/vertical)を自動列挙
- フォルダ系(Hand Pose / Action / Hand Action / Sound)は Image と同一の `labeledDirectories` +
  `MLJob` 機構を共有(型チェック確認済み)。実素材での精度検証は素材入手後に実施

## 使い方(例: 体のジェスチャを CHOP録画で学習)

1. VisionPose CHOP を録画して CSV 化(1行=1フレーム、列 `recording,label,body1/nose:u,...`。
   `recording` は動作1回ごとに別ID)
2. `Task` = **Activity Classifier**、`Training Path` にそのCSV、`Output Model` に `.mlmodel` パス
3. `Label Column` / `Recording ID Column` を合わせる(既定 label / recording)
4. **Train** をパルス → 完了後、出力 `.mlmodel` を [CoreML Motion CHOP](../CoreMLMotion/) に指定してライブ推論

## 出力(テーブルDAT)

| key | value |
|---|---|
| status | idle / training / done / error / cancelled |
| progress | 0..1 |
| train_accuracy / validation_accuracy | 分類の精度(回帰時は `train_rmse / val_rmse`) |
| classes | クラス名一覧(フォルダ系) |
| features | 使用した特徴列(Activity) |
| model | 書き出した .mlmodel パス |
| error | エラー内容 |

Info CHOP: `executes / progress / train_metric / val_metric / training / done`

## パラメータ

**CreateML ページ**

| パラメータ | 説明 |
|---|---|
| Task | 学習タスク(8種) |
| Training Path | ラベル別フォルダ(Image/HandPose/Action/HandAction/Sound)または CSV(Activity/Tabular) |
| Output Model | 書き出す .mlmodel パス |
| Train / Cancel | 学習の開始 / 中断(パルス) |

**Data ページ**(該当Taskのみ有効)

| パラメータ | 説明 |
|---|---|
| Label Column | ラベル列名(Activity。既定 label) |
| Recording ID Column | 収録ID列名(Activity。動作1回ごとに別ID。既定 recording) |
| Target Column | 目的変数列名(Tabular。既定 target) |
| Feature Columns | 特徴列(カンマ区切り、空=自動) |

**Training ページ**

| パラメータ | 説明 |
|---|---|
| Max Iterations | 学習反復回数(既定25) |
| Prediction Window | 予測窓フレーム数(Action/HandAction/Activity。既定30) |
| Augment: Flip/Crop/Rotation/Blur/Exposure/Noise | データ拡張(Image) |

## 注意

- **CreateML は Swift/Combine専用** → helper dylib 経由(ObjC++から直接不可)
- **Activity はフラットCSVを内部でシーケンス列テーブルへ変換**(`MLActivityClassifier` は
  特徴列がシーケンス型であることを要求)。`recording` 列は**動作1回ごとに別ID**にする
- **Action / Hand Action は動画フォルダ入力**。CreateML が内部で Vision の関節抽出をするため、
  CHOPは使わない。CHOPの関節時系列で学習したいときは **Activity** を使う
- Taskごとに使うパラメータ/列が異なる(ラベルはUIに `(Activity)` `(Tabular)` `(Image)` を明記)。
  無関係なパラメータは無視される
- 各クラス最低10サンプル程度。少ないと精度が出ない/検証が割れる
- 出力 `.mlmodel` は推論OPがコンパイルキャッシュ(`~/Library/Caches/TDAppleML/`)経由で読む

## ビルド

```
cd CreateML && ./build.sh   # → build/CreateMLDAT.plugin(Swiftヘルパ同梱)
```
