# CreateML Image DAT

ラベル付きフォルダ(**サブフォルダ名=クラス**、中に画像)から画像分類モデルを **CreateML で
オンデバイス学習**し、`.mlmodel` を書き出す。**出力モデルは [CoreML TOP](../CoreML/) がそのまま
推論**できるので、TD内で「撮る→ラベル付け→学習→推論」を完結できる。

- 学習は Swift ヘルパで**非同期**実行。cook は進捗を poll するだけでブロックしない
- 転移学習(Vision の scenePrint 特徴抽出器)なので小データでも数秒〜分でANE/GPU学習
- 学習結果の精度・進捗・クラス一覧をテーブル+Info CHOP で表示

## 実測(M2)

- 合成データ(horizontal/vertical/checker の縞パターン・各15枚)で学習 →
  **validation accuracy 1.0**、`.mlmodel`(約13KB)を出力
- 出力モデルを Vision/CoreML でロードして3クラスとも正しく分類(信頼度1.000)を確認
- TDでも Train パルス→status=done、val_acc=1.0、モデル書き出しを確認

## 使い方

1. `Training Folder` に、クラスごとのサブフォルダ(例 `cat/` `dog/`)を持つフォルダを指定。
   各サブフォルダに画像を入れる(1クラス最低10枚目安)
2. `Output Model` に書き出す `.mlmodel` パスを指定
3. **Train** をパルス → 学習開始。progress / accuracy が進む
4. 完了後、出力 `.mlmodel` を **CoreML TOP** の Model に指定して推論

## 出力(テーブルDAT)

| key | value |
|---|---|
| status | idle / training / done / error / cancelled |
| progress | 0..1 |
| train_accuracy / validation_accuracy | 学習/検証精度 |
| classes | クラス名一覧 |
| model | 書き出した .mlmodel パス |
| error | エラー内容 |

Info CHOP: `executes / progress / train_accuracy / validation_accuracy / training / done`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Training Folder | サブフォルダ=ラベルの画像フォルダ |
| Output Model | 書き出す .mlmodel パス |
| Max Iterations | 学習反復回数(既定25) |
| Augment: Flip/Crop/Rotation/Blur/Exposure/Noise | データ拡張(少データ時に有効) |
| Train / Cancel | 学習の開始 / 中断(パルス) |

## 注意

- **CreateML は Swift/Combine専用** → helper dylib 経由(ObjC++から直接不可)
- 学習は重い/長いことがある。進捗を見せ、Cancel で中断可能
- 各クラス最低10枚程度、クラス間で見分けが付く画像を。少ないと精度が出ない/検証が割れる
- 出力 `.mlmodel` は CoreML TOP がコンパイルキャッシュ(`~/Library/Caches/TDAppleML/`)経由で読む

## ビルド

```
cd CreateMLImage && ./build.sh   # → build/CreateMLImageDAT.plugin(Swiftヘルパ同梱)
```
