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
- 再生は **Movie File In と同じ** `Play` / `Speed` / `Loop` / `Cue` / `Play Mode`。
  デコードはワーカースレッド(cook 非ブロック)

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
| Eye | Left / Right / Side-by-Side / **Left + Right (2 buffers)** |
| Play Mode | Sequential(自前の時計)/ Locked to Timeline(タイムライン追従)/ Specify Index |
| Play / Speed / Loop | 再生・速度(負で逆再生)・ループ |
| Cue / Cue Point / Cue Pulse | キュー保持・キュー点(秒)・ジャンプ |
| Position (0..1) | Play が Off のときの手動スクラブ |

## 1つのTOPから左右を別々に取り出す

`Eye = Left + Right (2 buffers)` にすると、**1回のデコードで**カラーバッファ
**0 = 左眼 / 1 = 右眼** に出す。バッファ1以降は **Render Select TOP** で取り出す。

インスタンスを2つ置いて Left / Right にするより有利な点:

- **デコードが1回で済む**(2インスタンスは同じファイルを2回デコードする)
- **左右が必ず同じフレーム**になる(別インスタンスだと1フレームずれ得る)

> **Render Select TOP は参照で読むだけで cook を引っ張らない。** 下流が Render Select だけだと
> 参照元がほとんど cook されず再生が這う。**バッファ0(このノードの出力)は Null TOP などで
> ワイヤに繋いでおくこと。**

## 再生(Movie File In 相当)

`Play Mode` は Movie File In と同じ3種:

| モード | 内容 |
|---|---|
| `Sequential` | `deltaMS` ぶんだけ自前で進める。TDのタイムラインを止めれば止まる |
| `Locked to Timeline` | タイムライン位置をそのまま尺へ写す。スクラブに追従し、フレーム単位で再現する |
| `Specify Index` | `Position`(0..1)で手動指定 |

要求時刻は**ソースのfpsでフレーム量子化**している(しないと同じ絵を何度もデコードし直す)。
Info CHOP に `position`(秒)と `playing` を出す。

> **以前は `Time`(0..1)だけだった。** 秒だと思って秒の式を入れると 1.0 にクランプされ、
> 末尾にフレームが無く `No frame at requested time` のまま止まる。この落とし穴ごと
> Movie File In 互換の再生に置き換えた。

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
