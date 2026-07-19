# RealityKit Splat TOP

RealityKit の `RealityRenderer` で **USD / USDZ / Reality シーンをオフスクリーン描画**し、
TOP として出力する。macOS 26 の RealityKit は **3D Gaussian Splat を描画**できるため、
フォトリアルなスキャン(splat を含む USD)を TouchDesigner に取り込める。通常の PBR メッシュ
USDZ も描画可能。

- **TD標準にない描画対象**(Gaussian Splat / RealityKit の PBR・IBL)を TD のTOPに出す
- カメラは TD パラメータからオービット駆動。読み込んだコンテンツの bounds に**自動フレーミング**
- ファイル未指定時は**デフォルトの手続きシーン(3つの箱)**を描くので、アセット無しでも動作確認できる
- 描画は RealityKit の要求どおり**メインスレッド上**で実行し、GPU完了で画素をコピーする
  非同期方式。cook はブロックしない

## 実測(M2)

- 640×480・デフォルトシーン: **約58fps**(TD本体60fpsに追従、frames が executes に追従)
- USDZ ロード(Apple Pencil サンプル 190KB): 読み込み後フレーム落ちなく描画
- 初回は RealityRenderer / IBL の初期化に数フレーム

## 出力仕様

- TOP: **BGRA8**、解像度は `Resolution W/H`。RealityKit の描画結果(top-down)を `Flip` で
  上下反転して TD 正立に合わせる(既定 On)
- Info CHOP: `executes`(cook回数)・`frames`(描画済みフレーム)・`render_rc`(0=ok)・
  `loaded`(ファイル読込済み=1)

## パラメータ

| パラメータ | 説明 |
|---|---|
| Active | 描画の有効/無効 |
| Scene File | 読み込む USD / USDZ / USDC / Reality ファイル。空でデフォルトの箱シーン |
| Resolution W / H | 出力解像度 |
| Camera Distance (x content radius) | コンテンツ半径に対するカメラ距離倍率(既定 2.6)。**絶対距離ではなく倍率**なので、被写体の大小によらず自動で収まる |
| Camera Yaw / Pitch (deg) | オービット角 |
| Field of View (deg) | 画角 |
| Auto Rotate (deg/s) | Yaw の自動回転速度 |
| Look Target Offset | 注視点をコンテンツ中心から相対的にずらす |
| Background Color | 背景色(RGBA) |
| Flip Vertically | 出力の上下反転(既定 On) |

## 注意・制約

- **RealityRenderer は macOS 15+**、**Gaussian Splat 描画は macOS 26+**。splat を含む USD が必要
- **`RealityRenderer` は `@MainActor` 拘束**。TD の TOP cook はメインスレッドではないため、
  描画は `DispatchQueue.main` 経由で本物のメインスレッドへ回す(TDのメインランループがpumpする)
- **Gaussian Splat 専用のロードAPIは存在しない**。splat は USD/USDZ に含めて `Entity(contentsOf:)`
  で読み込み、RealityKit が内部的に描画する(= このTOPは splat 専用ではなく、RealityKit が
  読める USD シーン全般を描く)
- **`visualBounds` はコンテンツをシーンへ追加した後に取得する**。エンティティ自体はスケール
  しない(ロード物の内部トランスフォームと複合して破綻するため)。フレーミングは**カメラ側**で行う
- PBR メッシュを見せるため簡易 IBL(equirectグラデ)+ 平行光を常設。splat/自発光系は影響を受けない
- モデルは同梱しない。各自の USD/USDZ/splat を Scene File に指定する

## ビルド

```
cd RealityKitSplat && ./build.sh   # → build/RealityKitSplatTOP.plugin(Swiftヘルパ同梱)
```

Swift ヘルパ(`RealityKitSplatHelper`)が RealityKit 描画を担当し、C ABI(`rk_`)で ObjC++ の
TOP 本体と繋ぐ。dylib はビルド毎に epoch 名(dyld キャッシュ対策)。
