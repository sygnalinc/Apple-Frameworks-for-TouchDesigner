# AVF Camera

**English** | [日本語](#日本語)

## English

Opens a camera with AVFoundation and outputs video, with device/format information and camera
controls that TouchDesigner's Video Device In TOP does not expose.

> **Status: experimental.** Format selection works, but it only works if the format is applied
> **after** `startRunning` — see "Choosing a format" below.

### What works (measured on M2 / macOS 26.6)

- **Enumerates more cameras than TD.** 6 vs TD's 5 on the same machine — the Continuity **Desk View
  camera** shows up here and not in TD's list
- **Full format table.** The Logicool BRIO reports 35 formats = **212 combinations** of
  resolution × pixel format × frame-rate range, listed in a menu and in the Info DAT. Notably
  **only one combination reaches 60 fps** (1280x720 / 420v); 1920x1080 tops out at 30
- Video output (BGRA, CPU upload) and device identity by `uniqueID`

### Choosing a format

**`activeFormat` only takes effect if you set it after `startRunning`.** AVFoundation re-decides the
format when the session starts, so anything set earlier is overwritten. All eight orderings were
tried in a signed probe app; only one works:

| When the format is applied | Result |
|---|---|
| Session preset, before adding the input / inside the configuration block / after commit | 1920x1080 — ignored |
| `activeFormat`, before adding the input / inside the configuration block / after commit | 1920x1080 — ignored |
| **`activeFormat`, after `startRunning`** | **1280x720 — works** |
| `videoSettings` width/height keys | 1280x720, but that is output scaling: the camera still runs at its old format and frame rate |

`sessionPreset` never worked, even though `canSetSessionPreset` returned true and the assignment
ran. This is not specific to UVC — the built-in FaceTime HD camera behaves identically.

### What is not available on macOS

**iOS-only APIs**: `AVCaptureSessionPresetInputPriority`, ISO, exposure duration, exposure target
bias, lens position, white-balance gains and zoom. Exposure and focus can only be switched between
continuous-auto and locked.

### Frame rate

Selecting `1280x720 / 420v / 60 fps` yields about **33 fps** in TD. The signed probe app, with a
delegate that does almost nothing, measured **39 fps** on the same format — so the ceiling is the
camera or its driver, not this plugin. Receiving is double-buffered (the callback fills a back
buffer outside the lock and only swaps under it), which is the right shape regardless.

### Not yet verified

- Whether AVFoundation's Exposure / Focus **Locked** actually holds the image. `lockForConfiguration`
  succeeds and the mode reads back correctly, but the visual effect has not been confirmed. On a USB
  camera the UVC page is the better route anyway — that one is measured

### UVC controls (USB cameras)

macOS gives an app no manual exposure, so this plugin talks to the camera directly over USB using
the standard USB Video Class control requests (IOKit). **No entitlement and no root are required.**

Measured on a Logicool BRIO: reading the exposure time gave `GET_CUR=312` / `MIN=3` / `MAX=2047`
(units of 100 µs), switching AE Mode to manual and writing `100` (10.0 ms) read back correctly, and
the original values restored cleanly.

Verified end to end on a Logicool BRIO. All 13 controls came back `get+set` with real ranges —
exposure `3..2047` (units of 100 µs), focus `0..255`, zoom `100..500`, the Processing Unit group
`0..255`, white balance `2000..7500` K. Writing a value and reading it back matched exactly, and the
image responded:

| Exposure Time | Mean brightness of the frame |
|---|---|
| 100 (10 ms) | 0.040 |
| 300 | 0.135 |
| 900 | 0.276 |
| 1800 | 0.372 |

Saturation — a Processing Unit control, the group that a hardcoded unit ID silently breaks — moved
the per-pixel chroma from 0.004 at 0, through 0.006 at 128, to 0.013 at 255.

Three things about UVC that are easy to get wrong, all found the hard way:

- **The Processing Unit ID is not always 2.** On the BRIO it is **3** (the Camera Terminal is 1).
  Hardcoding it makes brightness, contrast, saturation, sharpness, gain and white balance all look
  unsupported. The IDs are read from the device's configuration descriptor, which — usefully —
  can be read **without opening the device**
- **Control transfers only answer while the camera is streaming.** Probing at the moment the device
  is selected returns `kIOReturnNotResponding` (0xe00002ed) for everything. The probe therefore
  waits for the first frame
- **Do not use GET_MIN/GET_MAX to decide whether a control exists.** Bitmap controls such as AE Mode
  do not implement them, so that test drops them. Support is decided from GET_CUR, with GET_INFO
  (bit 0 = readable, bit 1 = writable) as a refinement. GET_INFO must be requested with
  `wLength = 1`, not the control's own length

**The USB device is only opened for the duration of a transfer.** `USBDeviceOpen` is exclusive, and
holding it open made the camera fight with the system video driver until it **dropped off the USB
bus entirely** and disappeared from AVFoundation's device list — recovering it required a physical
replug. Descriptors are read without opening, and the device is opened only when there is actually
something to read or write.

Which controls a camera implements varies by model. Set **Info DAT** to `UVC Controls` to see the
support table (`usb_status`, the discovered unit IDs, the last USB error, and per-control
`supported / min / max / current`). Unsupported controls are greyed out. Non-USB cameras — the
built-in FaceTime HD, virtual cameras, Continuity — have no VID/PID, so the whole page is disabled
and the video path is unaffected.

### Video-call effects

Of the effects in Control Center, an app can set exactly two things:

| Effect | From an app |
|---|---|
| **Center Stage** | **Settable** (`isCenterStageEnabled`) |
| **Reactions** (hearts, confetti, …) | **Can be triggered** (`performEffect(for:)`) |
| Portrait, Studio Light, Background, Reactions-enabled | **Read-only** — no setter exists |

They are not in **AppIntents** either: the framework's camera symbols are `CameraCaptureIntent`,
`StartCameraCaptureIntent` and `FlipCameraIntent`, which are for publishing *your own* app's camera
feature to Siri and Shortcuts. Nothing there controls system video effects.

The read-only states are reported on the Info CHOP, so a TD project can still react to the user
having turned Portrait on.

### Parameters

| Parameter | Meaning |
|---|---|
| Active | Opens / closes the capture session |
| Device | Camera, held by `uniqueID` |
| Refresh Devices | Re-enumerate |
| Format | Resolution × pixel format × fps, from the device's own list |
| Exposure / Focus | Continuous Auto or Locked |
| Center Stage | See "Video-call effects" |
| Reaction / Send Reaction | Triggers a Control Center reaction |
| UVC page | Per-control values read from the camera when it starts streaming. Edit and they are sent; unsupported ones are greyed out |
| Apply UVC Values / Read From Camera | Force a resend / re-probe and pull the camera's current values back into the parameters |
| Info DAT | `Formats` or `UVC Controls` |

Info CHOP: `executes / frames / running / width / height / formats / cameras / center_stage /
portrait_effect / studio_light / active_w / active_h`. `width`/`height` are the frames that
arrived; `active_w`/`active_h` are what the device says its format is — the pair tells you whether
a format request took effect.

Info DAT: `Formats` gives one row per format (`index / width / height / pixel / max_fps`);
`UVC Controls` gives the USB status, the discovered unit IDs, the last USB error and one row per
control (`control / supported / min / max / current`).

### Notes

- **AVFoundation throws Objective-C exceptions instead of returning errors.** Handing
  `setActiveVideoMinFrameDuration:` a `CMTime` built from a float fps crashed TouchDesigner
  outright. Frame durations now come from the system's own `AVFrameRateRange`, and every
  configuration call is wrapped
- A bare command-line tool cannot get camera permission, so probes must run inside TD (or be
  packaged as a signed .app)

### Build

```bash
cd AVFoundationCamera && ./build.sh
```

---

## 日本語

AVFoundation でカメラを開いて映像を出し、あわせて TouchDesigner の Video Device In TOP が
持っていないデバイス情報とカメラ制御を扱う。

> **状態: experimental。** フォーマット選択は動く。ただし **`startRunning` の後**に適用しないと
> 効かない(下記「フォーマットの選び方」)。

### 動くこと(M2 / macOS 26.6 で実測)

- **TD より多くのカメラを列挙する。** 同じマシンで TD 5台に対し **6台**。Continuity の
  **デスクビューカメラ**はこちらにだけ出る
- **フォーマット表が出る。** Logicool BRIO は 35 フォーマット = 解像度 × 画素形式 ×
  fps レンジで **212 通り**。メニューと Info DAT に並ぶ。**60fps に届く組み合わせは1つだけ**
  (1280x720 / 420v)で、1920x1080 は 30fps 頭打ち
- 映像出力(BGRA・CPUアップロード)と `uniqueID` によるデバイス識別

### フォーマットの選び方

**`activeFormat` は `startRunning` の後に設定しないと効かない。** セッション開始時に
AVFoundation がフォーマットを決め直すため、それより前の指定はすべて上書きされる。
署名したプローブアプリで8通りの順序を総当たりし、通るのは1つだけだと確認した。

| フォーマットを適用する場所 | 結果 |
|---|---|
| sessionPreset を 入力追加前 / 設定ブロック内 / commit 後 | 1920x1080 — 無視される |
| `activeFormat` を 入力追加前 / 設定ブロック内 / commit 後 | 1920x1080 — 無視される |
| **`activeFormat` を `startRunning` の後** | **1280x720 — 効く** |
| `videoSettings` に幅高さ | 1280x720 になるが出力側のスケーリング。カメラは元のフォーマットと fps のまま |

`sessionPreset` は最後まで効かなかった(`canSetSessionPreset` が true を返し代入も実行されている
にもかかわらず)。UVC 固有ではなく、内蔵の FaceTime HD カメラでも同じ挙動だった。

### macOS に無いもの

**iOS 専用の API**: `AVCaptureSessionPresetInputPriority`、ISO、露出時間、露出補正、レンズ位置、
ホワイトバランスゲイン、ズーム。露出とフォーカスは auto / locked の切り替えだけができる。

### フレームレート

`1280x720 / 420v / 60 fps` を選ぶと TD で約 **33 fps**。ほとんど何もしないデリゲートを持つ
プローブアプリでも同じフォーマットで **39 fps** だったので、**上限はカメラ側**でありこの
プラグインの問題ではない。受信は二重バッファにしてある(コールバックはロックの外で裏バッファに
詰め、交換だけをロック内で行う)。これは実効fpsに関わらず正しい形。

### まだ検証できていないこと

- AVFoundation 側の Exposure / Focus の **Locked** が実際に画を固定するか。`lockForConfiguration` は
  成功しモードの読み戻しも正しいが、映像上の効果は未確認。USB カメラなら UVC ページの方が確実
  (こちらは実測済み)

### UVC コントロール(USB カメラ)

macOS はアプリに手動露出を許していないので、標準の USB Video Class のコントロール転送(IOKit)で
カメラを直接叩いています。**特別な権限も root も不要**です。

Logicool BRIO で実測: 露出時間が `GET_CUR=312` / `MIN=3` / `MAX=2047`(100µs 単位)で読め、
AE モードを手動にして `100`(10.0ms)を書き込むと読み戻しも一致、元の値への復元もできました。

**Logicool BRIO で通しで確認済み**。13 コントロールすべてが `get+set` で、範囲も実物どおり —
露出 `3..2047`(100µs 単位)、フォーカス `0..255`、ズーム `100..500`、Processing Unit 群 `0..255`、
色温度 `2000..7500` K。書いた値は読み戻しても一致し、映像も追従しました。

| Exposure Time | フレームの平均輝度 |
|---|---|
| 100 (10 ms) | 0.040 |
| 300 | 0.135 |
| 900 | 0.276 |
| 1800 | 0.372 |

彩度(Processing Unit 側 = ユニット ID を決め打ちすると黙って壊れる側)も、0 で 0.004・128 で 0.006・
255 で 0.013 と画素ごとの彩度が動きました。

**間違えやすい点が3つ**あります。いずれも実際に踏んだものです。

- **Processing Unit の ID は 2 とは限らない**。BRIO は **3**(Camera Terminal が 1)。決め打ちすると
  明るさ・コントラスト・彩度・シャープネス・ゲイン・色温度が丸ごと「非対応」に見えます。ID は
  コンフィグレーションディスクリプタから読みます。**これはデバイスを開かずに読める**のが利点
- **コントロール転送はカメラがストリーミングしていないと応答しない**。デバイスを選んだ時点で
  プローブすると全部 `kIOReturnNotResponding`(0xe00002ed)になります。最初のフレームを待ってから
  プローブします
- **対応判定に GET_MIN/GET_MAX を使ってはいけない**。AE モードのようなビットマップ型は実装しないので、
  その判定だと落ちます。GET_CUR を基準にし、GET_INFO(bit0=読める / bit1=書ける)で補います。
  **GET_INFO は `wLength = 1` 固定**で、コントロール自身の長さで要求すると失敗します

**USB デバイスは転送のあいだだけ開きます。** `USBDeviceOpen` は排他アクセスで、開いたまま保持すると
システムのビデオドライバと取り合いになり、**カメラが USB バスから完全に落ちて** AVFoundation の
一覧からも消えました(復帰には物理的な抜き差しが必要)。ディスクリプタは開かずに読み、
実際に読み書きするときだけ開きます。

どのコントロールを持つかは機種によって違います。**Info DAT** を `UVC Controls` にすると対応表
(`usb_status` / 見つかったユニット ID / 直近の USB エラー / コントロールごとの
`supported / min / max / current`)が見えます。非対応のものはグレーアウトされます。
USB でないカメラ(内蔵 FaceTime HD・仮想カメラ・連携カメラ)は VID/PID を持たないのでページごと
無効になり、映像側には影響しません。

### ビデオ通話のエフェクト

コントロールセンターにあるエフェクトのうち、アプリから触れるのは2つだけです。

| エフェクト | アプリから |
|---|---|
| **センターフレーム** | **設定できる**(`isCenterStageEnabled`) |
| **リアクション**(ハート・紙吹雪など) | **発火できる**(`performEffect(for:)`) |
| ポートレート / スタジオ照明 / 背景 / リアクション有効化 | **読み取りのみ** — setter が存在しない |

**AppIntents にもありません**。このフレームワークのカメラ関連は `CameraCaptureIntent` /
`StartCameraCaptureIntent` / `FlipCameraIntent` だけで、これは*自分のアプリの*カメラ機能を
Siri / ショートカットへ公開するためのものです。システムのビデオエフェクトを操作する術はありません。

読み取り専用の状態は Info CHOP に出しているので、「ユーザーがポートレートを入れた」ことに
TD 側から反応することはできます。

### パラメータ

| パラメータ | 意味 |
|---|---|
| Active | キャプチャセッションの開閉 |
| Device | カメラ。`uniqueID` で保持 |
| Refresh Devices | 再列挙 |
| Format | 解像度 × 画素形式 × fps。デバイス自身が申告する一覧から選ぶ |
| Exposure / Focus | Continuous Auto または Locked |
| Center Stage | 「ビデオ通話のエフェクト」を参照 |
| Reaction / Send Reaction | コントロールセンターのリアクションを発火する |
| UVC ページ | ストリーミング開始時にカメラから読んだ値が入る。編集すると送信される。非対応はグレーアウト |
| Apply UVC Values / Read From Camera | 強制的に再送 / プローブし直してカメラの現在値をパラメータへ戻す |
| Info DAT | `Formats` か `UVC Controls` |

Info CHOP: `executes / frames / running / width / height / formats / cameras / center_stage /
portrait_effect / studio_light / active_w / active_h`。`width`/`height` は**届いたフレーム**、
`active_w`/`active_h` は**デバイスが持っているフォーマット**で、両者を見ると指定が効いたか判別できる。

Info DAT: `Formats` はフォーマット1件=1行(`index / width / height / pixel / max_fps`)。
`UVC Controls` は USB の状態・見つかったユニット ID・直近の USB エラーと、コントロール1件=1行
(`control / supported / min / max / current`)。

### 注意

- **AVFoundation はエラーを返さず Objective-C 例外を投げる。** fps から自分で作った `CMTime` を
  `setActiveVideoMinFrameDuration:` に渡したら TouchDesigner ごと落ちた。現在はフレーム持続時間を
  システムの `AVFrameRateRange` からそのまま取り、設定呼び出しはすべて例外で包んでいる
- **素の CLI はカメラ権限を取れない**ので、検証は TD 内で行うか、署名した .app にする必要がある

### ビルド

```bash
cd AVFoundationCamera && ./build.sh
```
