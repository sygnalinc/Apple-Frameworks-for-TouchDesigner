# Live Photo TOP

Live Photo(静止画HEIC + ペア動画MOV)を `PHLivePhoto` として検証し、その**動画コンポーネントの任意時刻
フレーム**を BGRA8 TOP に出力する(Live Photo の「全フレーム」へのアクセス)。cook はブロックせずワーカーで抽出。

## パラメータ

| パラメータ | 説明 |
|---|---|
| Still File | 静止画(HEIC/JPG) |
| Paired Video | ペア動画(MOV) |
| Time | 動画内の時刻(0..1) |

Info CHOP: `executes / is_live_photo / duration / submits`

## 注意

- **Live Photo の実素材(image + paired video)が必要**。Still+Video が揃うと `PHLivePhoto` として検証し
  `is_live_photo=1`。動画のフレームは AVFoundation で抽出する
- 高度な編集(効果を全フレームに適用して再レンダ)は `PHLivePhotoEditingContext` を使う想定(拡張ポイント)
- Photos ライブラリのアセットを使う場合は Photos の TCC 権限が要る

## ビルド
```
cd LivePhoto && ./build.sh
```
