# Cinematic — iPhone Cinematicモード動画

iPhone(13以降)の**Cinematicモード動画**に埋め込まれた深度・被写体・フォーカス情報を扱う
2プラグイン。Apple の `Cinematic` framework(macOS 26+)を使う。

- **Cinematic Data(CHOP)** — メタデータを数値で出す(フォーカス深度・被写体スロット)
- **Cinematic Video(TOP)** — 深度(視差)マップ、または **f値/ピントを差し替えて再レンダ**した映像を出す

両者は共有Swiftヘルパ(`CinematicHelper`)で動画を時刻指定デコードする。

## Cinematic Data(CHOP)

`CNScript` から時刻(Position)のメタデータを取得(ピクセルデコード不要):

- `focus_disparity` — その時刻の合焦面の深度
- `focus_strong` — フォーカス判断が強い(ユーザー確定)か
- `subjects` — 検出被写体数
- `subject{i}/`: `valid` / `type`(1顔 2頭 3胴体 4猫 5犬 6ボール)/ `u,v,w,h`(bbox)/ `depth` / `trackid`

## Cinematic Video(TOP)

| Mode | 出力 | 内容 |
|---|---|---|
| **Depth** | Mono32Float | フレーム毎の視差(深度)マップ(低解像度) |
| **Rendered** | RGBA16Float | Aperture(f値)と Focus を差し替えて被写界深度を**再レンダ**(`CNRenderingSession`) |

- **CHOP の subject depth を TOP の Focus に配線 → TDからリアルタイムでピント送り**
- デコード/レンダはワーカースレッドで行い cook をブロックしない

## パラメータ

**共通**: `Cinematic Video (iPhone)`(ファイル)/ `Position (0..1)`(再生位置=時刻)

**CHOP**: `Max Subjects`
**TOP**: `Mode` / `Aperture (f-number)` / `Focus Disparity Override`(0=script準拠)/ `Normalize Depth` / `Flip`

## 検証状況(M2)

- **両プラグインのロード・パラメータ生成・チャンネル構造・File未指定の安全動作を確認**
  (CHOP=83ch、TOP=Depth/Rendered各パラメータ、クラッシュ・エラーなし)
- **実Cinematic動画での深度・再レンダ・被写体メタデータの視覚検証は未実施**。
  iPhone 17 Pro の実動画2本で試したが、いずれも**新形式**で `CNAssetInfo` が読めず(下記「対応形式」)、
  検証には旧形式(iPhone 13〜16)の動画が必要。実装は Apple サンプル
  "Playing and editing Cinematic mode video" の API に準拠

## 対応形式(重要)

- **対応するのは「旧Cinematicモード」形式(iPhone 13〜16)**。この形式は分離した**視差トラック**
  (`cinematicDisparityTrack`)とメタデータトラックを持ち、`CNAssetInfo` で読める
- **iPhone 17以降の「新Cinematic video」形式は現状読めない**(実機で確認)。新形式は単層HEVC
  (hvc1)で分離視差トラックが無く、macOS 26.4 SDK の `Cinematic` framework(`CNAssetInfo`)は
  `Incomplete` を返す。**新形式から深度を取り出す公開macOS APIが現状存在しない**ため、対応は
  Apple が読み取りAPIを出すまで保留(このプラグインは旧形式向けの足場として残す)
- 深度が今すぐ要るなら、ポートレート写真の深度は [ImageIO Depth](../ImageIODepth/) /
  [ImageIO PointCloud](../ImageIOPointCloud/) が iPhone 写真で動作する

## 注意

- **合成不可**。旧Cinematicモードの実動画が必要
- **macOS 26+ 必須**(Cinematic framework)
- 視差トラックは映像より低解像度。深度TOPもその解像度
- 時刻指定デコードは AVAssetReader。スクラブ多用時は負荷が上がる(将来 AVSampleBufferGenerator 化候補)

## ビルド

```
cd Cinematic && ./build.sh   # → build/CinematicCHOP.plugin + build/CinematicTOP.plugin
```

1フォルダから2バンドルを生成(共有ヘルパ `CinematicHelper` を各バンドルに同梱)。
