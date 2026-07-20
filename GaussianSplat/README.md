# Gaussian Splat SOP

**3D Gaussian Splatting の `.ply`**(INRIA形式: x,y,z,nx,ny,nz,f_dc_*,f_rest_*,opacity,scale_*,rot_*)を
直接パースし、**TDの色付き点群(SOP)**として出力する。TDはこれをネイティブに描画できる。
巨大ファイル(数十〜数百MB)対応のため**パースはワーカースレッド**で行い、cook はブロックしない。

## なぜSOPなのか

Apple RealityKit(macOS 26)は **RealityRenderer が点群(UsdGeomPoints)を描画しない**(実測: 点群USDは
ロードされるが描画されず黒)。また **3DGS の .ply → splat USDZ 変換の公開APIは無い**(ModelIOも
3DGSの多数プロパティで破損)。そこで .ply を自前パースして **TDの点群**にするのが確実な経路。
真のガウシアン(異方性カーネル)描画ではなく、**splat中心の色付き点群**として可視化する。

## 実測(M2)

- 実 3DGS `.ply`(369085頂点・91MB)を Maxpoints=150000 で **184543点**にパース。色は球面調和のDC項から
  復元(pt0=(0.58,0.47,0.44)、pt1000=(0.30,0.31,0.29) と点ごとに変化)、opacity/pscaleも点属性で出力

## 出力(SOP)

点群 + 点属性 `Cd`(色3・SH DCから `0.5+0.2821*f_dc`)/ `pscale`(点サイズ・`exp(scale_0)`)/
`opacity`(`sigmoid(opacity)`)。Point SOP や Render で色付き点群として描画する。Info CHOP: `executes / points`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Splat File | 3DGS の `.ply` |
| Max Points | 間引き後の目標点数(大きいファイルの負荷調整) |

## 注意

- INRIA系 3DGS の `.ply`(`f_dc_*`/`opacity`/`scale_*` を持つ)を想定。ヘッダのプロパティ名で
  オフセットを動的解決する
- 座標系はソース依存(大きい座標のことがある)。Transform SOP で正規化する
- 真のガウシアン描画が要るなら splat入りUSDZ + RealityKit(要Appleのsplat USDスキーマ)を待つ

## ビルド
```
cd GaussianSplat && ./build.sh
```
