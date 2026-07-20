# CreateML Training Recorder CHOP

入力CHOP(VisionPose / VisionHand / SoundFeatures など)の**時系列を、CreateML DAT
(Activity task)がそのまま学習できるCSVデータセットへ収録**する。TD内で「関節/特徴を
録る → ラベル付け → 学習(CreateML)→ ライブ推論(CoreML Motion)」を閉じられる。

## 何ができる

- 入力CHOPの各チャンネルを1フレーム=1行として記録
- `Record` オンの区間を1つの**収録(recording)**として扱い、停止(または Save)で確定
- 複数ラベル・複数テイクを**1つのCSVに追記**していく
- 出力CSVは CreateML DAT の Training Path にそのまま渡せる

## CSV形式

```
recording,label,<feat0>,<feat1>,...
r1784543258_0,wave,0.159413,0.241992,0.121700
r1784543258_0,wave,0.005060,0.117324,-0.224520
...
r1784543258_1,circle,...
```

- **recording** = 1収録=1系列のID(Save / Record停止ごとに採番。セッションtag付きで衝突回避)
- **label** = そのジェスチャ/動作のラベル(パラメータ)
- **feature列** = 入力CHOPのチャンネル名(カンマは `_` に置換)

CreateML DAT の Activity task はこの `recording` 列で系列化し、`label` を教師、残りを
特徴量として学習する。

## 実測(M2)

- noise CHOP 3ch(ax/ay/az)入力、`wave` 8フレーム + `circle` 6フレームを収録 →
  `recording,label,ax,ay,az` ヘッダ・2 recordings・14データ行のCSVを生成
- CreateML DAT(Activity)がそのまま読める列構成であることを確認

## 出力(ステータスCHOP)

`recording`(0/1) / `frames`(現在収録のフレーム数) / `channels`(入力ch数) /
`recordings`(確定済み収録数) / `rows`(書き込んだ総行数) / `buffered`(未確定バッファ行数)

## パラメータ

| パラメータ | 説明 |
|---|---|
| Output CSV | 追記先CSVパス |
| Label | 収録のラベル |
| Record | オンの区間を1収録として記録 |
| Auto Save On Stop | Record停止時に自動確定(既定On) |
| Save Recording | 現在バッファを手動で確定(パルス) |
| Clear File | CSVをヘッダのみに初期化(パルス) |
| Frame Stride | Nフレームに1回だけ記録 |
| Sample | 入力の Last / First サンプルを記録 |

## 注意

- **CHOP入力を読むため CHOP** として実装(DATはCHOP入力を受けられない)。VisionPose等の
  CHOPを直接接続する
- 収録中は毎フレームcookする(`cookEveryFrame`)。出力(ステータス)を使っていなくても記録される
- 特徴列数(入力ch数)が既存CSVと変わると警告。別データセットにするなら Clear File

## ビルド

```
cd CreateMLTrainingRecorder && ./build.sh   # → build/TrainingRecorderCHOP.plugin
```
