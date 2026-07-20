# ImageIO PointCloud SOP

写真(HEIC等)に埋め込まれた**深度/視差(AVDepthData)**を、カメラ内部パラメータ(あれば)
または画角から**逆投影して3Dポイントクラウド**にする SOP。RGBから色もサンプルする。

- ポートレート写真の深度から立体点群を作り、パーティクル/インスタンス描画に使える
- 抽出・逆投影はワーカースレッドで行い cook をブロックしない
- AVDepthData のキャリブレーションがあれば内部パラメータ(fx/fy/cx/cy)を使用、無ければ Horizontal FOV から近似

## 実測(M2)

- 合成視差HEIC(256×256・DisparityFloat16)から Step=2・DepthScale=2.0 で **16384点(128×128)** を生成
- **Z範囲 −1.0〜−0.04 が視差(0.5〜0.02)× DepthScale(2.0)と厳密一致**(逆投影が正しい)
- 色サンプル・パーティクルシステム出力・FOVフォールバック(has_calibration=0)を確認
- **キャリブレーション付き実写真での内部パラメータ経路は、深度付き実写真が未入手のため未検証**
  (経路は実装済み。AVDepthData の intrinsicMatrix を参照)

## 出力仕様

- SOP: ポイント(+色)+ パーティクルシステム。点数 = 有効深度画素 / Step²(Max Points で制限)
- Info CHOP: `executes / submits / builds / points / has_calibration`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Image File | 深度/視差を含む HEIC 等 |
| Sample Step | 間引き(2で1/4の点数)。負荷と密度のバランス |
| Max Points | 点数上限 |
| Depth Scale | 深度値のスケール(シーンの大きさ調整) |
| Disparity → Depth (1/x) | 視差を距離(1/視差)へ変換。Depthデータならオフ |
| Horizontal FOV | キャリブレーション無し時の画角(内部パラメータの近似) |
| Sample Color from RGB | RGB画像から各点の色をサンプル |
| Apply EXIF Orientation | EXIFの向きを深度・色・内部パラメータへ適用(既定On) |
| Flip Vertically | Y反転(既定 Off) |

## 注意

- 深度/視差はポートレートモード等の写真にのみ含まれる(通常写真は不可・Warning)
- **EXIF Orientation(1〜8)を適用**して点群を正立させる。iPhoneの縦写真は横センサー+
  Orientation=6 で保存されるため、未対応だと点群が横倒しになる。深度・色・カメラ内部パラメータ
  (焦点距離の入替え+主点の写像)をまとめて回転させる
- 視差データは近似的に 1/視差 で距離化。正確な距離にはキャリブレーションと基線長が必要
- [ImageIO File In](../ImageIOFileIn/) と同じ補助データ抽出を使う(深度をTOPで見たい場合はそちら)

## ビルド

```
cd ImageIOPointCloud && ./build.sh   # → build/ImageIOPointCloudSOP.plugin
```
