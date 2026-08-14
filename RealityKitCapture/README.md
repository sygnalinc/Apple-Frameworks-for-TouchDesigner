# RealityKit Capture SOP

**English** | [日本語](#日本語)

## English

**Reconstructs a 3D mesh from a folder of photographs** (RealityKit Object Capture, macOS 12+).
Put photos taken all the way around an object (20+ recommended, overlap required) in Image Folder,
pulse Start, and after a few minutes the mesh is **output as SOP geometry** and saved to file.

### Measured (M2)

- **The full pipeline was verified with the Middlebury templeRing dataset** (47 photos around a
  temple model, 640x480): reconstruction finished in about a minute (Preview detail) → USDZ
  (450 KB) → converted to OBJ → **1416 points / 2835 triangles** confirmed visually in a render
- The dataset and mesh are bundled at `Assets/templeRing/` and `Assets/temple_scan.obj`
- With an unsuitable image set (photos that do not overlap) it correctly returns processError

### Texture

- On completion the **baked texture inside the usdz is extracted automatically as
  `<output name>_tex0.png`**, and `map_Kd` in the `.mtl` is rewritten to match (so TD and other
  tools can read it directly)
- The SOP outputs **UVs (texture coordinates)** (the OBJ's separate v/vt indices are resolved by
  splitting points at UV seams)
- **Applying it in TD**: Movie File In TOP → `_tex0.png`, set that as the Color Map of a Phong
  MAT, and assign the MAT to the Geometry COMP. The texture path can be referenced by expression
  from the **`texture` row of the Info DAT** (`op('photo_info')[1,1]` etc.)

### Parameters

| Name | Description |
|---|---|
| Image Folder | Photo folder (JPEG/HEIC — e.g. a walk-around shot on an iPhone) |
| Output File | Where to save. **`.obj` is recommended (only obj is displayed in the SOP)**; `.usdz` also works |
| Detail | Preview / Reduced / Medium (default) / Full |
| Start / Cancel | Start / abort the reconstruction (pulse) |

Info CHOP: `executes / progress (0–1) / points`.
Info DAT: `texture` (path of the extracted texture) / `status` (JSON). Progress also appears in
the warning text.

### Notes

- **PhotogrammetrySession can only output USDZ directly** (specifying `.obj` gives invalidOutput —
  measured). When you ask for `.obj`, the plugin makes a temporary USDZ and converts it with
  ModelIO (the same-named `.usdz` is left behind as well)
- Processing takes minutes. TD itself is never blocked
- The SOP outputs vertices, triangles and UVs (no normals — add them with a Facet SOP or Attribute
  Create SOP if needed)

### Build

```
cd RealityKitCapture && ./build.sh   # → build/RealityKitCaptureSOP.plugin (Swift helper bundled)
```

## 日本語

**写真フォルダから3Dメッシュを再構成**(RealityKit Object Capture・macOS 12+)。
物体を一周撮った写真(20枚以上推奨・オーバーラップ必須)を Image Folder に置き、
Start をパルス → 数分の処理後、メッシュを**SOPジオメトリとして出力**+ファイル保存。

### 実測(M2)

- **Middlebury templeRing データセット(寺院模型を一周47枚・640x480)で
  フルパイプライン検証済み**: 約1分(Preview詳細)で再構成完了 →
  USDZ(450KB)→ OBJ変換 → **SOP出力 1416点/2835三角形** をレンダリングで視認
- データセットとメッシュは `Assets/templeRing/` と `Assets/temple_scan.obj` に同梱
- 雑多な画像セット(重なりのない写真)では正しく processError を返すことも確認済み

### テクスチャ

- 再構成完了時、**usdz内の焼き込みテクスチャを `<出力名>_tex0.png` として自動抽出**し、
  `.mtl` の `map_Kd` も書き換える(TD・他ツールから直接読める)
- SOP は **UV(テクスチャ座標)付き**で出力する(OBJのv/vt分離はUVシームで点を分割して解決)
- **TDでの貼り方**: Movie File In TOP に `_tex0.png` → Phong MAT の Color Map に指定 →
  Geometry COMP の Material へ。テクスチャパスは **Info DAT の `texture` 行**から
  式で参照できる(`op('photo_info')[1,1]` 等)

### パラメータ

| 名前 | 内容 |
|---|---|
| Image Folder | 写真フォルダ(JPEG/HEIC。iPhoneで一周撮影したもの等) |
| Output File | 保存先。**`.obj` 推奨(SOP表示は obj のみ)**。`.usdz` も可 |
| Detail | Preview / Reduced / Medium(既定)/ Full |
| Export Point Cloud (3DGS PLY) | **点群を3DGS形式の .ply で書き出す**(macOS 14+)。**3DGSの生成ではない**(下記) |
| Point Cloud PLY File | .ply の保存先 |
| Point Size | 粒(等方ガウシアン)の半径 = 最近傍距離の中央値 × この係数(既定1.5) |
| Start / Cancel | 再構成の開始・中断(パルス) |

Info CHOP: `executes / progress(0〜1)/ points`。
Info DAT: `texture`(抽出テクスチャのパス)/ `splat`(書き出したplyパス)/ `splat_points` / `status`(JSON)。進捗は警告文にも出る。

## 点群を 3DGS形式の .ply で書き出す

> **これは「3DGS(ガウシアンスプラッティング)の生成」ではありません。**
> Object Capture が出す**疎な点群を、3DGSのファイル形式に詰めて書き出すだけ**の機能です。
> 目的は RealityKit Splat TOP(3DGSレンダラ)で点群を柔らかい粒として表示すること。
> 実験中(出力先の Splat TOP が macOS 27+ で実験中)。メッシュ再構成は従来どおり検証済み。

`Export Point Cloud (3DGS PLY)` をオンにすると、メッシュと同時に `PhotogrammetrySession` の
**pointCloud リクエスト**を実行し、点群を **3DGS形式(INRIA互換)の .ply** として書き出す。

**本物の3DGSとの違い(実装が何をしていないか)**:

| 3DGSの要素 | 本物(学習ベース) | この機能 |
|---|---|---|
| 生成手順 | 多視点画像から**最適化(学習)** | **学習なし**(SfMの疎点群をそのまま座標に) |
| 共分散(形) | 点ごとに**異方性**を学習 | **等方の固定値**(半径=最近傍距離の中央値×係数) |
| 不透明度 | 点ごとに学習 | **全点固定**(0.95) |
| 回転 | 点ごとに学習 | **恒等**(無回転) |
| 色 | 高次SHで**視点依存** | **SH DC項のみ**(どの角度でも同じ色) |
| 点数 | 数十万〜数百万 | **SfM疎点群のまま**(templeRing 47枚で約1650点) |

つまり中身は**点群**で、3DGSを名乗れるのは**ファイルレイアウトだけ**です。見た目も
「柔らかい丸い粒の集まり」で、学習ベース3DGSのような精細な再現にはなりません。

- 座標は3DGS慣例のY下向きで書くため、RealityKit Splat TOP・他の3DGSビューアでそのまま正立
- **Appleの Gaussian Splat 学習API(写真→本物の3DGS)は macOS 27 でも非公開**
  (`CorePhotogrammetry` 内部のみ)。本物が欲しい場合は現時点では外部ツール
  (INRIA実装・Postshot 等)で学習した .ply を **RealityKit Splat TOP に直接読ませる**のが正解。
  公開されたらこの機能を置き換える

### 注意

- **PhotogrammetrySession の直接出力は USDZ のみ**(`.obj` 指定は invalidOutput・実測)。
  `.obj` 指定時はプラグインが一時USDZ→ModelIOでOBJ変換する(同名の .usdz も残る)
- 処理は分単位のじっくり系。TD本体はブロックしない
- SOP出力は頂点+三角形+UV(法線は含まない。必要なら Facet SOP / Attribute Create SOP で)

### ビルド

```
cd RealityKitCapture && ./build.sh   # → build/RealityKitCaptureSOP.plugin(Swiftヘルパ同梱)
```
