# Cinematic Video TOP — iPhone Cinematic mode video

**English** | [日本語](#日本語)

## English

Reads the depth, subject and focus information embedded in **Cinematic mode video** shot on an
iPhone (13 and later), using Apple's `Cinematic` framework (macOS 26+).

- **Image output**: the disparity (depth) map, or the frame **re-rendered with a different
  aperture / focus**
- **Metadata output**: focus depth and subject slots come out as **Info CHOP channels**
  (the former **Cinematic Data CHOP** is merged in — point an Info CHOP at this node to get the
  same data)

### Playback

**It plays on its own, like a Movie File In.** `Play` is On by default and the position advances
with the TouchDesigner timeline (`deltaMS`), so pausing the timeline pauses the clip.

| Parameter | |
|---|---|
| `Play` | On (default) = play automatically. Off = scrub by hand with `Position` |
| `Speed` | 1 = real time. Negative values play backwards |
| `Loop` | On (default) = wrap to the start. Off = hold on the last frame |
| `Cue` | Hold at `Cue Point` while this is On |
| `Cue Point` / `Cue Pulse` | Jump to that time in seconds |
| `Position (0..1)` | Manual scrub — **only used while `Play` is Off** |

The requested time is snapped to the source frame grid, otherwise the same frame would be decoded
over and over. The current time is published as the Info CHOP channels `position` (seconds) and
`playing`.

### Color and depth at the same time (`Mode = Both`)

One node, one decode, **frame-locked by construction** — both images come from the same job, so
they can never drift apart.

| | Output |
|---|---|
| **Color buffer 0** | Rendered image (RGBA16Float, full resolution) — the node's normal output |
| **Color buffer 1** | Depth / disparity (Mono32Float, its own resolution) — read it with a **Render Select TOP** (`Buffer Index` = 1) |

The two buffers may have different resolutions and pixel formats; that is explicitly supported.
Measured on M2 with real footage: **1.00x real time, 60 pairs per second** (1920x1080 colour +
512x288 depth).

> **Wire buffer 0 into your chain.** A Render Select TOP reads by *reference*, and a reference
> does **not** pull a cook out of the source. If the only things downstream are Render Select
> TOPs, this operator barely cooks and playback crawls (measured: 4408 cooks on the Render Select
> versus 29 on the source). Connect the node's own output to something — a Null TOP is enough —
> and both buffers update at full rate.

Two separate nodes on the same file also work, but that decodes the file twice and the two
playheads drift; if you do that, set `Play` Off on the second one and drive its `Position` from
the first one's `position` Info CHOP channel.

### Automatic Info CHOP (no setup)

**Just place the operator** and a pre-filled Callbacks DAT (`<node>_callbacks`) is created and
docked to it as a **closed ↓ chip**, exactly like the shader DAT of a GLSL TOP.
**The moment you turn the `Info CHOP` toggle ON, an Info CHOP (`<node>_info`) is created next to
it** (nothing happens if one already exists — there is a duplicate guard). Edit `onInfoCHOP`
inside the chip to change the name or placement.

Everything this operator publishes is numeric — duration, focus distance, subject slots — so it is
an Info **CHOP**, not an Info DAT.

### Image output (Mode)

| Mode | Output | Description |
|---|---|---|
| **Depth** | Mono32Float | Per-frame disparity (depth) map (low resolution) |
| **Rendered** | RGBA16Float | Depth of field **re-rendered** with your Aperture (f-number) and Focus (`CNRenderingSession`) |

Decoding and rendering run on a worker thread and never block cook.

### Info CHOP (metadata — formerly Cinematic Data CHOP)

Metadata for the current Position is pulled from `CNScript` (no pixel decode, so it is cheap):

- Diagnostics: `executes / submits / frames / ready / duration`
- `focus_disparity` — depth of the focal plane at that time
- `focus_strong` — whether the focus decision is strong (user-confirmed)
- `subjects` — number of detected subjects
- `subject{i}/`: `valid` / `type` (1 face, 2 head, 3 torso, 4 cat, 5 dog, 6 ball) / `u,v,w,h`
  (bbox) / `depth` / `trackid`

Wire a **subject depth into the Focus parameter to rack focus live from TD**.

### Parameters

`Cinematic Video (iPhone)` (file) / `Mode` (Depth / Rendered / Both) / `Play` / `Speed` / `Loop` / `Cue` / `Cue Point` /
`Cue Pulse` / `Position (0..1, when Play is off)` / `Aperture (f-number)` /
`Focus Disparity Override` (0 = follow the script) / `Normalize Depth` / `Flip` /
`Max Subjects (Info CHOP)` / `Info CHOP`

### Status (M2 — every feature verified on real Cinematic footage)

Verified against Cinematic video from an iPhone 17 Pro (3840×2160, disparity 512×288):

- ✅ **Depth**: disparity map with near = bright, correctly oriented
- ✅ **Rendered**: bokeh follows the f-number (f/2.0 = heavy background blur ↔ f/16 = sharp),
  confirmed visually. The 3840×2160 re-render runs on the GPU
- ✅ **Info CHOP metadata** (after the merge): duration = 17.26 s, focus_disparity = 2.049,
  focus_strong = 1, two subject slots (bbox, depth 2.03)
- The implementation follows the API of Apple's sample "Playing and editing Cinematic mode video"

### Important: transfer Cinematic video *with* its depth

Transferred the wrong way, a Cinematic clip is **flattened into an ordinary movie and can no
longer be re-focused** (per Apple). The Cinematic framework can only read files that still carry
the depth data.

**Correct iPhone → Mac (AirDrop) procedure**:
1. Select the Cinematic clip in Photos → **Share**
2. **Options** at the top → turn on **All Photos Data** → Done
3. AirDrop, then use the **`.MOV` without the `IMG_E` prefix** inside the folder that appears on
   the Mac (`E` is the baked-in version)

Transferring with All Photos Data off loses the depth (`CNAssetInfo` reports Incomplete).
Any model from iPhone 13 to 17 should be readable by the Cinematic framework when transferred
correctly.

### Notes

- Under **TouchDesigner Non-Commercial** the resolution is capped at 1280x1280. Output above the
  cap is **scaled down automatically** with a warning (without it TD renders garbage). Use a
  commercial license if you need full resolution.

- **Cannot be synthesised.** Real footage shot in Cinematic mode is required
- **macOS 26+ required** (Cinematic framework)
- The disparity track is lower resolution than the video; the depth TOP inherits that resolution
- Time-based decoding uses AVAssetReader, so heavy scrubbing is expensive (AVSampleBufferGenerator
  is a future candidate)
- The old **Cinematic Data CHOP** was merged into this TOP's Info CHOP and removed (2026-07-21)

### Build

```
cd Cinematic && ./build.sh   # → build/CinematicVideoTOP.plugin
```

Ships with the Swift helper `CinematicHelper` (epoch-suffixed dylib name to dodge the cache).

## 日本語

iPhone(13以降)の**Cinematicモード動画**に埋め込まれた深度・被写体・フォーカス情報を扱う。
Apple の `Cinematic` framework(macOS 26+)を使う。

- **映像出力**: 深度(視差)マップ、または **f値/ピントを差し替えて再レンダ**した映像
- **メタデータ出力**: フォーカス深度・被写体スロットを **Info CHOP チャンネル**で出す
  (旧 **Cinematic Data CHOP** を統合。Info CHOP をこのノードに向けるだけで同じデータが得られる)

### 再生

**Movie File In と同じく、置くだけで勝手に再生される。** `Play` は既定 On で、位置は
TouchDesigner のタイムライン(`deltaMS`)に従って進む。タイムラインを止めれば再生も止まる。

| パラメータ | |
|---|---|
| `Play` | On(既定)=自動再生 / Off=`Position` で手動スクラブ |
| `Speed` | 1=実時間。負値で逆再生 |
| `Loop` | On(既定)=先頭へ折り返す / Off=終端で停止 |
| `Cue` | On の間は `Cue Point` で保持 |
| `Cue Point` / `Cue Pulse` | 指定秒へジャンプ |
| `Position (0..1)` | 手動スクラブ。**`Play` が Off のときだけ効く** |

要求時刻はソースのフレーム境界へ量子化している(しないと同じ絵を何度もデコードし直すことになる)。
現在位置は Info CHOP の `position`(秒)と `playing` で読める。

### 色と深度を同時に出す(`Mode = Both`)

1ノード・1回のデコードで、**構造上フレームがずれない**(同じジョブから両方を出しているため)。

| | 出力 |
|---|---|
| **色バッファ 0** | 再レンダ映像(RGBA16Float・フル解像度)= ノードの通常の出力 |
| **色バッファ 1** | 深度/視差(Mono32Float・別解像度)= **Render Select TOP** の `Buffer Index` を 1 にして取る |

2つのバッファは解像度もピクセル形式も別で構わない(SDKが明示的に許している)。
実測(M2・実素材): **実時間の1.00倍・60組/秒**(色1920×1080 + 深度512×288)。

> **バッファ0はワイヤで下流に繋ぐこと。** Render Select TOP は**参照**で読むため、
> **参照は cook を引っ張らない**。下流が Render Select TOP だけだとこのOPはほとんど cook されず、
> 再生が這うように遅くなる(実測: Render Select が4408 cook に対し、参照元は29 cook)。
> ノード自身の出力を何か(Null TOP で十分)に繋げば、両バッファとも全速で更新される。

同じファイルに2ノード当てても出せるが、デコードが2回走り、再生位置も別々に進んでずれる。
やるなら2つ目は `Play` を Off にして、1つ目の Info CHOP `position` から `Position` を駆動する。

### Info CHOP の自動生成(操作不要)

**OPを配置するだけ**で雛形入りの Callbacks DAT(`<node名>_callbacks`)が自動生成され、
GLSL TOP のシェーダDATと同じ**閉じた↓チップ**としてノードにドックされる。
**`Info CHOP` トグルを ON にした瞬間、隣に Info CHOP(`<node名>_info`)が自動生成**される
(既にあれば何もしない=二重生成ガード)。生成位置や名前はチップ内の `onInfoCHOP` を編集して変えられる。

このOPが出すのは尺・フォーカス距離・被写体スロットなど**全て数値**なので、Info DAT ではなく
Info **CHOP** が正しい。

### 映像出力(Mode)

| Mode | 出力 | 内容 |
|---|---|---|
| **Depth** | Mono32Float | フレーム毎の視差(深度)マップ(低解像度) |
| **Rendered** | RGBA16Float | Aperture(f値)と Focus を差し替えて被写界深度を**再レンダ**(`CNRenderingSession`) |

デコード/レンダはワーカースレッドで行い cook をブロックしない。

### Info CHOP(メタデータ・旧 Cinematic Data CHOP)

`CNScript` から時刻(Position)のメタデータを取得(ピクセルデコード不要・低コスト):

- 診断: `executes / submits / frames / ready / duration`
- `focus_disparity` — その時刻の合焦面の深度
- `focus_strong` — フォーカス判断が強い(ユーザー確定)か
- `subjects` — 検出被写体数
- `subject{i}/`: `valid` / `type`(1顔 2頭 3胴体 4猫 5犬 6ボール)/ `u,v,w,h`(bbox)/ `depth` / `trackid`

**subject depth を Focus パラメータに配線 → TDからリアルタイムでピント送り**ができる。

### パラメータ

`Cinematic Video (iPhone)`(ファイル)/ `Mode`(Depth / Rendered / Both)/ `Play` / `Speed` / `Loop` / `Cue` / `Cue Point` /
`Cue Pulse` / `Position (0..1, when Play is off)` / `Aperture (f-number)` /
`Focus Disparity Override`(0=script準拠)/ `Normalize Depth` / `Flip` /
`Max Subjects (Info CHOP)` / `Info CHOP`

### 検証状況(M2・実Cinematic動画で全機能確認済み)

iPhone 17 Pro のCinematic動画(3840×2160・視差512×288)で **全機能を実データ視認**:

- ✅ **Depth**: 手前=近い の視差深度マップを正しく出力
- ✅ **Rendered**: f値でボケが変化(f/2.0=背景大ボケ ↔ f/16=背景くっきり)を視認。
  3840×2160の再レンダをGPUで実行
- ✅ **Info CHOP メタデータ**(統合後): duration=17.26s、focus_disparity=2.049、focus_strong=1、
  被写体2スロット(bbox・depth 2.03)を取得
- 実装は Apple サンプル "Playing and editing Cinematic mode video" の API に準拠

### 重要: Cinematic動画は「深度を保持して転送」する

Cinematic動画は転送方法を誤ると**通常動画に平坦化され、深度・フォーカスを編集できなくなる**
(Apple公式)。Cinematic frameworkが読めるのは深度データ付きのファイルのみ。

**iPhone → Mac(AirDrop)の正しい手順**:
1. 写真アプリでCinematicクリップを選択 → **共有**
2. 上部 **「オプション」** → **「すべての写真データ(All Photos Data)」をオン** → 完了
3. AirDrop → Mac側にできる**フォルダ内の「IMG_E」接頭辞が無い .MOV** を使う(Eは焼き込み版)

「すべての写真データ」をオフで転送すると深度が失われる(= `CNAssetInfo` が Incomplete になる)。
機種(iPhone 13〜17)を問わず、正しく転送すれば Cinematic framework で読める想定。

### 注意

- **TouchDesigner Non-Commercial** では解像度が 1280x1280 に制限される。上限を超える出力は**自動で上限内へ縮小**し、その旨を警告に出す(縮小しないと TD 側で絵が崩れるため)。フル解像度が要るなら商用ライセンスを使う

- **合成不可**。Cinematicモードで撮影した実動画が必要
- **macOS 26+ 必須**(Cinematic framework)
- 視差トラックは映像より低解像度。深度TOPもその解像度
- 時刻指定デコードは AVAssetReader。スクラブ多用時は負荷が上がる(将来 AVSampleBufferGenerator 化候補)
- 旧 **Cinematic Data CHOP** は本TOPのInfo CHOPに統合され廃止(2026-07-21)

### ビルド

```
cd Cinematic && ./build.sh   # → build/CinematicVideoTOP.plugin
```

Swiftヘルパ `CinematicHelper` を同梱(epoch付きdylib名でキャッシュ回避)。
