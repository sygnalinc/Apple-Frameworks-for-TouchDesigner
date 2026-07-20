# Spatial Video DAT / TOP

**MV-HEVC の空間ビデオ(Apple Spatial Video / 立体視)**を TouchDesigner で扱う。
DAT がメタデータ(左右眼・基線・視野角など)、TOP が**左右眼のフレーム**を取り出す。
1フォルダから2バンドル(純ObjC++・Swiftヘルパ無し)。macOS 14+。

## Spatial Video DAT(メタデータ)

映像トラックのフォーマット記述(CMFormatDescription)拡張から立体視情報を key/value 出力:
`codec / width / height / duration / fps / is_spatial / has_left_eye / has_right_eye /
hero_eye / baseline_mm / horizontal_fov_deg / horizontal_disparity_adjustment`。

**実測(M2・iPhone Spatial Video)**: 1920×1080・hvc1・15.5s・30fps、**is_spatial=1・
左右眼あり・baseline 19.255mm・水平FOV 63.4°** を取得。

## Spatial Video TOP(左右眼デコード)

`AVAssetReader` + `AVAssetReaderTrackOutput` に MV-HEVC の**両レイヤー(VideoLayerID 0/1)**を
要求してデコードし、`CMTaggedBufferGroup` から左眼/右眼の CVPixelBuffer を分離して BGRA8 出力。

- `Eye` = **Left / Right / Side-by-Side**(左右連結)
- `Time`(0..1)でスクラブ。デコードはワーカースレッド(cook 非ブロック)

**実測(M2)**: 上記素材で左眼 1920×1080 を取得、左眼中央 px `[0.122,0.122,0.137]` と
右眼中央 px `[0.141,0.161,0.161]` が**視差ぶん異なる**ことを確認(立体視の分離が機能)。

## 出力仕様

- DAT: key/value テーブル。Info CHOP: `executes / is_spatial / width / height / baseline_mm`
- TOP: 選択眼の BGRA8。Info CHOP: `executes / submits / decodes / is_spatial`

## パラメータ

| OP | パラメータ | 説明 |
|---|---|---|
| DAT | Spatial Video File | MV-HEVC .MOV/.MP4 |
| TOP | Spatial Video File | 同上 |
| TOP | Eye | Left / Right / Side-by-Side |
| TOP | Time (0..1) | スクラブ位置 |

## 注意

- **左右眼が要る = MV-HEVC(2レイヤー)素材**。通常のモノラル動画は左眼のみ・is_spatial=0
- iPhone の空間ビデオを Mac へ持ち出すときは、平坦化(通常動画化)されない転送をする
  (Cinematic 素材と同様、共有時のオプションに注意)
- レイヤー0を左眼として扱う(`hero_eye` メタデータも DAT で確認できる)

## ビルド

```
cd SpatialVideo && ./build.sh   # → build/SpatialVideoDAT.plugin + build/SpatialVideoTOP.plugin
```
