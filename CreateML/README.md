# CreateML DAT

**English** | [日本語](#日本語)

## English

A general-purpose trainer that **unifies Apple's CreateML training tasks into a single operator**.
Switch tasks with the `Task` menu, **train on-device from inside TD** and write out a `.mlmodel`.
The resulting model is read directly by the existing inference operators
([CoreML TOP](../CoreML/) / [CoreML Motion CHOP](../CoreMLMotion/) /
[SoundClass CHOP](../SoundClass/) …), so "collect in TD → label → train → infer" closes the loop.

> **Status: experimental.** Trained end-to-end here (Tabular train/val = 1.0, regression RMSE 0.12,
> Activity, Image) and the output models are read by the inference operators, but it is **not
> shipped in the release DMG** and is unsupported. `PLUGINS.tsv` is the source of truth — build it
> yourself from this folder.

- Training runs **asynchronously** in a Swift helper. Cook only polls progress and never blocks
- Input is either a **folder** (subfolder per label) or a **CSV** (time series / table). Which
  columns and parameters apply depends on the task
- Progress, accuracy and the class/feature lists are shown as a table plus an Info CHOP

### Tasks

| Task | CreateML class | Input | Purpose / where the model runs |
|---|---|---|---|
| Image Classifier | `MLImageClassifier` | **Image folders** per label | Image classification → CoreML TOP |
| Hand Pose Classifier | `MLHandPoseClassifier` | **Hand image folders** per label | Hand **shape** (static: peace, fist) |
| Action Classifier (body) | `MLActionClassifier` | **Video folders** per label | Body **motion** (CreateML extracts joints with Vision) |
| Hand Action Classifier | `MLHandActionClassifier` | **Video folders** per label | Hand **motion** |
| Sound Classifier | `MLSoundClassifier` | **Audio folders** per label | Sound classification → SoundClass CHOP |
| Activity Classifier | `MLActivityClassifier` | **CHOP time-series CSV** | Numeric time series from Vision Pose/Hand → CoreML Motion CHOP |
| Tabular Classifier | `MLClassifier` | **Table CSV** | Tabular classification → CoreML CHOP/DAT |
| Tabular Regressor | `MLRegressor` | **Table CSV** | Tabular regression |

**There are two routes for pose/gesture training**:
- **Folder material** (Hand Pose / Action / Hand Action): supply images or videos and CreateML
  runs the Vision extraction itself
- **CHOP recording** (Activity): a CSV recorded in TD from Vision Pose / Vision Hand joint CHOPs.
  No extra material needed; inference is live via [CoreML Motion CHOP](../CoreMLMotion/)

### Measured (M2)

- **Tabular Classifier**: synthetic 2 features × 3 classes, 150 rows → **train/val accuracy 1.0**
- **Tabular Regressor**: synthetic linear data → **RMSE 0.12** (written with metadata)
- **Activity**: 30 recordings × 80 frames × 4 features × 3 classes → **train 1.0 / val 0.571**,
  feature columns detected automatically
- **Image**: 3 classes of stripe patterns → training completed, classes
  (checker/horizontal/vertical) enumerated automatically
- The folder-based tasks (Hand Pose / Action / Hand Action / Sound) share the same
  `labeledDirectories` + `MLJob` machinery as Image (type-checked). Accuracy on real material will
  be verified once material is available

### Usage (example: training body gestures from a CHOP recording)

1. Record a Vision Pose CHOP into a CSV (one row per frame; columns
   `recording,label,body1/nose:u,...`, with a different `recording` ID per take)
2. `Task` = **Activity Classifier**, `Training Path` = that CSV, `Output Model` = a `.mlmodel` path
3. Match `Label Column` / `Recording ID Column` (defaults: label / recording)
4. Pulse **Train**, then point [CoreML Motion CHOP](../CoreMLMotion/) at the resulting `.mlmodel`
   for live inference

### Output (table DAT)

| key | value |
|---|---|
| status | idle / training / done / error / cancelled |
| progress | 0..1 |
| train_accuracy / validation_accuracy | Classification accuracy (`train_rmse / val_rmse` for regression) |
| classes | Class names (folder-based tasks) |
| features | Feature columns used (Activity) |
| model | Path of the written `.mlmodel` |
| error | Error text |

Info CHOP: `executes / progress / train_metric / val_metric / training / done`

### Parameters

**CreateML page**

| Parameter | Description |
|---|---|
| Task | Training task (8 of them) |
| Training Path | Label folders (Image/HandPose/Action/HandAction/Sound) or a CSV (Activity/Tabular) |
| Output Model | Path of the `.mlmodel` to write |
| Train / Cancel | Start / abort training (pulse) |

**Data page** (only for the relevant task)

| Parameter | Description |
|---|---|
| Label Column | Label column name (Activity; default label) |
| Recording ID Column | Recording ID column (Activity; a different ID per take. Default recording) |
| Target Column | Target column (Tabular; default target) |
| Feature Columns | Feature columns (comma separated; empty = automatic) |

**Training page**

| Parameter | Description |
|---|---|
| Max Iterations | Training iterations (default 25) |
| Prediction Window | Prediction window in frames (Action/HandAction/Activity; default 30) |
| Augment: Flip/Crop/Rotation/Blur/Exposure/Noise | Data augmentation (Image) |

### Notes

- **CreateML is Swift/Combine only** → it goes through a helper dylib (ObjC++ cannot call it)
- **Activity converts a flat CSV into a sequence-column table internally** (`MLActivityClassifier`
  requires the feature columns to be sequence typed). Give **each take its own `recording` ID**
- **Action / Hand Action take video folders.** CreateML runs the Vision joint extraction
  internally, so CHOPs are not involved. To train on joint time series from CHOPs, use
  **Activity**
- Each task uses different parameters and columns (the labels are marked `(Activity)`,
  `(Tabular)`, `(Image)` in the UI). Irrelevant parameters are ignored
- Around ten samples per class minimum; fewer and accuracy suffers or validation splits badly
- The written `.mlmodel` is read by the inference operators through the compile cache
  (`~/Library/Caches/TDAppleML/`)

### Build

```
cd CreateML && ./build.sh   # → build/CreateMLDAT.plugin (Swift helper bundled)
```

## 日本語

Apple の **CreateML** による各種学習タスクを**1つのオペレータに統合**した汎用トレーナ。
`Task` メニューでタスクを切り替え、TD内から**オンデバイス学習**して `.mlmodel` を書き出す。
出力モデルは既存の推論OP([CoreML TOP](../CoreML/) / [CoreML Motion CHOP](../CoreMLMotion/) /
[SoundClass CHOP](../SoundClass/) 等)がそのまま読む。「TD内で集める→ラベル付け→学習→推論」を閉じられる。

> **状態: experimental。** ここで学習まで通している(Tabular train/val=1.0・回帰 RMSE 0.12・
> Activity・Image)し、出力モデルは推論opがそのまま読める。ただし**リリースDMGには入らず**
> サポート対象外。正は `PLUGINS.tsv`。使うにはこのフォルダで自分でビルドする。

- 学習は Swift ヘルパで**非同期**実行。cook は進捗を poll するだけでブロックしない
- 入力は**フォルダ**(ラベル別サブフォルダ)または **CSV**(時系列/表)。Taskごとに使う列/パラメータが変わる
- 進捗・精度・クラス/特徴一覧をテーブル + Info CHOP で表示

### Task 一覧

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

### 実測(M2)

- **Tabular Classifier**: 合成2特徴×3クラス150行 → **train/val accuracy 1.0**
- **Tabular Regressor**: 合成線形データ → **RMSE 0.12**(metadata付きで書き出し)
- **Activity**: 30収録×80フレーム×4特徴×3クラス → **train 1.0 / val 0.571**、特徴列を自動検出
- **Image**: 3クラスの縞パターン → 学習完走、クラス(checker/horizontal/vertical)を自動列挙
- フォルダ系(Hand Pose / Action / Hand Action / Sound)は Image と同一の `labeledDirectories` +
  `MLJob` 機構を共有(型チェック確認済み)。実素材での精度検証は素材入手後に実施

### 使い方(例: 体のジェスチャを CHOP録画で学習)

1. VisionPose CHOP を録画して CSV 化(1行=1フレーム、列 `recording,label,body1/nose:u,...`。
   `recording` は動作1回ごとに別ID)
2. `Task` = **Activity Classifier**、`Training Path` にそのCSV、`Output Model` に `.mlmodel` パス
3. `Label Column` / `Recording ID Column` を合わせる(既定 label / recording)
4. **Train** をパルス → 完了後、出力 `.mlmodel` を [CoreML Motion CHOP](../CoreMLMotion/) に指定してライブ推論

### 出力(テーブルDAT)

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

### パラメータ

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

### 注意

- **CreateML は Swift/Combine専用** → helper dylib 経由(ObjC++から直接不可)
- **Activity はフラットCSVを内部でシーケンス列テーブルへ変換**(`MLActivityClassifier` は
  特徴列がシーケンス型であることを要求)。`recording` 列は**動作1回ごとに別ID**にする
- **Action / Hand Action は動画フォルダ入力**。CreateML が内部で Vision の関節抽出をするため、
  CHOPは使わない。CHOPの関節時系列で学習したいときは **Activity** を使う
- Taskごとに使うパラメータ/列が異なる(ラベルはUIに `(Activity)` `(Tabular)` `(Image)` を明記)。
  無関係なパラメータは無視される
- 各クラス最低10サンプル程度。少ないと精度が出ない/検証が割れる
- 出力 `.mlmodel` は推論OPがコンパイルキャッシュ(`~/Library/Caches/TDAppleML/`)経由で読む

### ビルド

```
cd CreateML && ./build.sh   # → build/CreateMLDAT.plugin(Swiftヘルパ同梱)
```
