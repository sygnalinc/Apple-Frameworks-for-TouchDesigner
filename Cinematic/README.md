# Cinematic Video TOP — iPhone Cinematicモード動画

iPhone(13以降)の**Cinematicモード動画**に埋め込まれた深度・被写体・フォーカス情報を扱う。
Apple の `Cinematic` framework(macOS 26+)を使う。

- **映像出力**: 深度(視差)マップ、または **f値/ピントを差し替えて再レンダ**した映像
- **メタデータ出力**: フォーカス深度・被写体スロットを **Info CHOP チャンネル**で出す
  (旧 **Cinematic Data CHOP** を統合。Info CHOP をこのノードに向けるだけで同じデータが得られる)

## Info DAT の自動生成(操作不要)

**OPを配置するだけ**で雛形入りの Callbacks DAT(`<node名>_callbacks`)が自動生成され、
GLSL TOP のシェーダDATと同じ**閉じた↓チップ**としてノードにドックされる。
**`Info DAT` トグルを ON にした瞬間、隣に Info DAT(`<node名>_info`)が自動生成**される
(既にあれば何もしない=二重生成ガード)。生成位置や名前はチップ内の `onInfoDAT` を編集して変えられる。

## 映像出力(Mode)

| Mode | 出力 | 内容 |
|---|---|---|
| **Depth** | Mono32Float | フレーム毎の視差(深度)マップ(低解像度) |
| **Rendered** | RGBA16Float | Aperture(f値)と Focus を差し替えて被写界深度を**再レンダ**(`CNRenderingSession`) |

デコード/レンダはワーカースレッドで行い cook をブロックしない。

## Info CHOP(メタデータ・旧 Cinematic Data CHOP)

`CNScript` から時刻(Position)のメタデータを取得(ピクセルデコード不要・低コスト):

- 診断: `executes / submits / frames / ready / duration`
- `focus_disparity` — その時刻の合焦面の深度
- `focus_strong` — フォーカス判断が強い(ユーザー確定)か
- `subjects` — 検出被写体数
- `subject{i}/`: `valid` / `type`(1顔 2頭 3胴体 4猫 5犬 6ボール)/ `u,v,w,h`(bbox)/ `depth` / `trackid`

**subject depth を Focus パラメータに配線 → TDからリアルタイムでピント送り**ができる。

## パラメータ

`Cinematic Video (iPhone)`(ファイル)/ `Mode` / `Position (0..1)`(再生位置。内部で秒に変換)/
`Aperture (f-number)` / `Focus Disparity Override`(0=script準拠)/ `Normalize Depth` / `Flip` /
`Max Subjects (Info CHOP)`

## 検証状況(M2・実Cinematic動画で全機能確認済み)

iPhone 17 Pro のCinematic動画(3840×2160・視差512×288)で **全機能を実データ視認**:

- ✅ **Depth**: 手前=近い の視差深度マップを正しく出力
- ✅ **Rendered**: f値でボケが変化(f/2.0=背景大ボケ ↔ f/16=背景くっきり)を視認。
  3840×2160の再レンダをGPUで実行
- ✅ **Info CHOP メタデータ**(統合後): duration=17.26s、focus_disparity=2.049、focus_strong=1、
  被写体2スロット(bbox・depth 2.03)を取得
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

- **TouchDesigner Non-Commercial** では解像度が 1280x1280 に制限される。上限を超える出力は**自動で上限内へ縮小**し、その旨を警告に出す(縮小しないと TD 側で絵が崩れるため)。フル解像度が要るなら商用ライセンスを使う

- **合成不可**。Cinematicモードで撮影した実動画が必要
- **macOS 26+ 必須**(Cinematic framework)
- 視差トラックは映像より低解像度。深度TOPもその解像度
- 時刻指定デコードは AVAssetReader。スクラブ多用時は負荷が上がる(将来 AVSampleBufferGenerator 化候補)
- 旧 **Cinematic Data CHOP** は本TOPのInfo CHOPに統合され廃止(2026-07-21)

## ビルド

```
cd Cinematic && ./build.sh   # → build/CinematicVideoTOP.plugin
```

Swiftヘルパ `CinematicHelper` を同梱(epoch付きdylib名でキャッシュ回避)。
