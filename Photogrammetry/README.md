# Photogrammetry SOP

**写真フォルダから3Dメッシュを再構成**(RealityKit Object Capture・macOS 12+)。
物体を一周撮った写真(20枚以上推奨・オーバーラップ必須)を Image Folder に置き、
Start をパルス → 数分の処理後、メッシュを**SOPジオメトリとして出力**+ファイル保存。

## 実測(M2)

- **Middlebury templeRing データセット(寺院模型を一周47枚・640x480)で
  フルパイプライン検証済み**: 約1分(Preview詳細)で再構成完了 →
  USDZ(450KB)→ OBJ変換 → **SOP出力 1416点/2835三角形** をレンダリングで視認
- データセットとメッシュは `Assets/templeRing/` と `Assets/temple_scan.obj` に同梱。
  sample.toe の `/project1/photogrammetry_demo` にデモネットワークあり
- 雑多な画像セット(重なりのない写真)では正しく processError を返すことも確認済み

## パラメータ

| 名前 | 内容 |
|---|---|
| Image Folder | 写真フォルダ(JPEG/HEIC。iPhoneで一周撮影したもの等) |
| Output File | 保存先。**`.obj` 推奨(SOP表示は obj のみ)**。`.usdz` も可 |
| Detail | Preview / Reduced / Medium(既定)/ Full |
| Start / Cancel | 再構成の開始・中断(パルス) |

Info CHOP: `executes / progress(0〜1)/ points`。進捗と状態は警告文にJSONで出る。

## 注意

- **PhotogrammetrySession の直接出力は USDZ のみ**(`.obj` 指定は invalidOutput・実測)。
  `.obj` 指定時はプラグインが一時USDZ→ModelIOでOBJ変換する(同名の .usdz も残る)
- 処理は分単位のじっくり系。TD本体はブロックしない
- SOP出力は頂点+三角形のみ(テクスチャはOBJ/USDZファイル側にある。
  絵付きで使う場合は生成された USDZ/OBJ を通常のジオメトリ読込で)

## ビルド

```
cd Photogrammetry && ./build.sh   # → build/PhotogrammetrySOP.plugin(Swiftヘルパ同梱)
```
