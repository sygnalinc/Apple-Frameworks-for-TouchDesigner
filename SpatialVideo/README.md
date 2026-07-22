# Spatial Video TOP

**MV-HEVC の空間ビデオ(Apple Spatial Video / 立体視)**を TouchDesigner で扱う。
**左右眼のフレーム**を映像出力し、メタデータ(基線・視野角など)は **Info CHOP / Info DAT** で出す
(旧 **Spatial Video DAT** を統合)。純ObjC++・Swiftヘルパ無し。macOS 14+。

## Info DAT の自動生成(操作不要)

**OPを配置するだけ**で雛形入りの Callbacks DAT(`<node名>_callbacks`)が自動生成され、
GLSL TOP のシェーダDATと同じ**閉じた↓チップ**としてノードにドックされる。
**`Info DAT` トグルを ON にした瞬間、隣に Info DAT(`<node名>_info`)が自動生成**される
(既にあれば何もしない=二重生成ガード)。生成位置や名前はチップ内の `onInfoDAT` を編集して変えられる。

## 映像出力(左右眼デコード)

`AVAssetReader` + `AVAssetReaderTrackOutput` に MV-HEVC の**両レイヤー(VideoLayerID 0/1)**を
要求してデコードし、`CMTaggedBufferGroup` から左眼/右眼の CVPixelBuffer を分離して BGRA8 出力。

- `Eye` = **Left / Right / Side-by-Side**(左右連結)
- `Time`(0..1)でスクラブ。デコードはワーカースレッド(cook 非ブロック)

## メタデータ(旧 Spatial Video DAT)

映像トラックのフォーマット記述(CMFormatDescription)拡張から立体視情報を取得:

- **Info CHOP**(数値): `executes / submits / decodes / is_spatial / width / height / duration /
  fps / baseline_mm / horizontal_fov_deg / disparity_adjustment / has_left_eye / has_right_eye`
- **Info DAT**(key/value・文字列含む全項目): `codec / width / height / duration / fps /
  is_spatial / has_left_eye / has_right_eye / hero_eye / baseline_mm / horizontal_fov_deg /
  horizontal_disparity_adjustment`

Info CHOP / Info DAT をこのノードに向けるだけで旧DATと同じ情報が得られる。

## 実測(M2・iPhone Spatial Video)

- 映像: 左眼 1920×1080 を取得、左眼中央 px `[0.122,0.122,0.137]` と右眼中央 px
  `[0.141,0.161,0.161]` が**視差ぶん異なる**ことを確認(立体視の分離が機能)
- メタデータ(統合後): 1920×1080・hvc1・15.5s・30fps、**is_spatial=1・左右眼あり・
  baseline 19.255mm・水平FOV 63.4°・disparity_adjustment 200** を Info CHOP/Info DAT で取得

## パラメータ

| パラメータ | 説明 |
|---|---|
| Spatial Video File | MV-HEVC .MOV/.MP4 |
| Eye | Left / Right / Side-by-Side |
| Time (0..1) | スクラブ位置 |

## 注意

- **左右眼が要る = MV-HEVC(2レイヤー)素材**。通常のモノラル動画は左眼のみ・is_spatial=0
- iPhone の空間ビデオを Mac へ持ち出すときは、平坦化(通常動画化)されない転送をする
  (Cinematic 素材と同様、共有時のオプションに注意)
- レイヤー0を左眼として扱う(`hero_eye` は Info DAT で確認できる)
- 旧 **Spatial Video DAT** は本TOPのInfo CHOP/Info DATに統合され廃止(2026-07-21)

## ビルド

```
cd SpatialVideo && ./build.sh   # → build/SpatialVideoTOP.plugin
```
