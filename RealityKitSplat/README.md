# RealityKit Splat TOP

**3D Gaussian Splatting(.ply)を真のガウシアンスプラットとして描画**する TOP。
macOS 27 で公開された RealityKit の `GaussianSplatComponent` / `GaussianSplatResource` を使い、
`RealityRenderer` でオフスクリーン描画して TOP に出す。USD / USDZ / Reality のメッシュシーンも
同じノードでロードできる(従来機能)。

- 3DGS .ply(INRIA形式)は**自前パース**して `LowLevelBuffer` へ投入する
  (Apple のドキュメント通り、フレームワークにファイルローダは無い)
- scale(log値)/ opacity(logit)は生値のまま渡し、`scaleActivation = .exponential` /
  `opacityActivation = .sigmoid` にレンダラ側で評価させる
- 色は SH DC項(f_dc_0..2・degree 0)。**view-dependent な高次SH(f_rest_*)は未投入**
  (degree 1〜3 のバッファレイアウトが公開ドキュメントに無いため。見た目は DC のみでも良好)
- カメラはオービット式(Distance は**コンテンツ半径の倍率**・自動フレーミング)。
  フレーミングは外れ値に強い「各軸中央値+距離70パーセンタイル」(3DGSの遠方背景splat対策)
- 3DGS は Y下向き規約なので **X軸180°回転で自動正立**。追加の `Content Rotate` で任意調整可

## 実測(M2・macOS 27.0)

| 項目 | 値 |
|---|---|
| 実3DGSシーン(369,085 splats・91MB .ply) | パース+リソース構築 数秒(非同期・cook非ブロック) |
| 描画 1280×720 | **splatレンダ 約44fps**(TD本体 60fps 維持・cook約0.8ms) |
| USDZ メッシュ(temple_scan) | 従来どおりレンダ(IBL+平行光) |

## パラメータ

| 名前 | 説明 |
|---|---|
| Active | 描画のOn/Off |
| Scene File | `.ply`(3DGS)/ `.usd` `.usdz` `.reality`。空ならデフォルトの箱シーン |
| Max Splats | .ply のサブサンプル上限(等間隔間引き。既定50万) |
| Resolution W / H | 出力解像度 |
| Camera Distance | コンテンツ半径に対する倍率 |
| Camera Yaw / Pitch / FOV | オービットカメラ |
| Auto Rotate | 自動回転(deg/s) |
| Content Rotate | コンテンツの追加回転(deg・XYZ)。.ply は自動でX180°正立済み |
| Look Target Offset | 注視点のオフセット |
| Background Color | 背景色 |
| Flip Vertically | TD正立用の上下反転(既定On) |

Info CHOP: `executes / frames / render_rc / loaded / splats`。
`frames` が `executes` に追従していればフレーム落ちなし。ロード状況・エラーは Warning に表示。

## 注意(ハマりどころ)

- **macOS 27 以降必須**(.ply の splat 描画)。26 以前では status にエラーを返す(クラッシュしない)。
  USD/USDZ のメッシュ描画は macOS 15+ で動く
- **opacity 等に NaN/Inf が1つでも混ざるとシーン全体が描画されない**
  (`GSAsset: NaN/Inf detected` ログ)。本プラグインはパース時に NaN/Inf を除去・置換する
- `LowLevelBuffer` の capacity には**アライメント要件**がある(素の count×12 だと
  `invalid(bufferCapacity:)`)。256B境界へ切り上げて確保している
- ply のクォータニオンは `rot_0..3` = **w,x,y,z** 順。RealityKit へは **x,y,z,w** で渡す
- 対応plyは `binary_little_endian` の float プロパティのみ(INRIA 3DGS 標準出力)
- サンプル素材: `Assets/gs_sample.ply`(gitignore・大容量のためコミットしない)

## ビルド

```bash
./build.sh   # → build/RealityKitSplatTOP.plugin(ad-hoc署名まで)
```

Swiftヘルパ(`RealityKitSplatHelper.swift`)を epoch 付き dylib にして同梱。
インストールは `~/Library/Application Support/Derivative/TouchDesigner099/Plugins/` へコピー → TD再起動。
