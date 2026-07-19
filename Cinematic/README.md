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

## 検証状況(M2・実Cinematic動画で全機能確認済み)

iPhone 17 Pro のCinematic動画(3840×2160・視差512×288)で **全機能を実データ視認**:

- ✅ **Cinematic Data(CHOP)**: focus_disparity=0.75、被写体4個(猫=pet depth 2.0、物体 depth 0.18)を取得
- ✅ **Cinematic Video / Depth**: 手前=近い の視差深度マップを正しく出力
- ✅ **Cinematic Video / Rendered**: f値でボケが変化(f/2.0=背景大ボケ ↔ f/16=背景くっきり)を視認。
  3840×2160の再レンダをGPUで実行
- 実装は Apple サンプル "Playing and editing Cinematic mode video" の API に準拠

## 重要: Cinematic動画は「深度を保持して転送」する

Cinematic動画は転送方法を誤ると**通常動画に平坦化され、深度・フォーカスを編集できなくなる**
(Apple公式)。Cinematic frameworkが読めるのは深度データ付きのファイルのみ。

**iPhone → Mac(AirDrop)の正しい手順**:
1. 写真アプリでCinematicクリップを選択 → **共有**
2. 上部 **「オプション」** → **「すべての写真データ(All Photos Data)」をオン** → 完了
3. AirDrop → Mac側にできる**フォルダ内の「IMG_E」接頭辞が無い .MOV** を使う(Eは焼き込み版)

「すべての写真データ」をオフで転送すると深度が失われる(= `CNAssetInfo` が Incomplete になる)。
機種(iPhone 13〜17)を問わず、正しく転送すれば Cinematic framework で読める想定。

## 注意

- **合成不可**。Cinematicモードで撮影した実動画が必要
- **macOS 26+ 必須**(Cinematic framework)
- 視差トラックは映像より低解像度。深度TOPもその解像度
- 時刻指定デコードは AVAssetReader。スクラブ多用時は負荷が上がる(将来 AVSampleBufferGenerator 化候補)

## ビルド

```
cd Cinematic && ./build.sh   # → build/CinematicCHOP.plugin + build/CinematicTOP.plugin
```

1フォルダから2バンドルを生成(共有ヘルパ `CinematicHelper` を各バンドルに同梱)。
