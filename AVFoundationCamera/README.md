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

- Whether Exposure / Focus **Locked** actually holds the image. `lockForConfiguration` succeeds and
  the mode reads back correctly, but the visual effect has not been confirmed

### Parameters

| Parameter | Meaning |
|---|---|
| Active | Opens / closes the capture session |
| Device | Camera, held by `uniqueID` |
| Refresh Devices | Re-enumerate |
| Format | Resolution × pixel format × fps, from the device's own list |
| Exposure / Focus | Continuous Auto or Locked |
| Center Stage | The only video effect an app can set. Portrait Effect and Studio Light are read-only (no setter on macOS) and are reported on the Info CHOP |

Info CHOP: `executes / frames / running / width / height / formats / cameras / center_stage /
portrait_effect / studio_light / active_w / active_h`. `width`/`height` are the frames that
arrived; `active_w`/`active_h` are what the device says its format is — the pair tells you whether
a format request took effect.

Info DAT: one row per format — `index / width / height / pixel / max_fps`.

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

- Exposure / Focus の **Locked** が実際に画を固定するか。`lockForConfiguration` は成功し、
  モードの読み戻しも正しいが、映像上の効果は未確認

### パラメータ

| パラメータ | 意味 |
|---|---|
| Active | キャプチャセッションの開閉 |
| Device | カメラ。`uniqueID` で保持 |
| Refresh Devices | 再列挙 |
| Format | 解像度 × 画素形式 × fps。デバイス自身が申告する一覧から選ぶ |
| Exposure / Focus | Continuous Auto または Locked |
| Center Stage | アプリから設定できる唯一のビデオエフェクト。Portrait / Studio Light は setter が無く読み取り専用で、状態は Info CHOP に出る |

Info CHOP: `executes / frames / running / width / height / formats / cameras / center_stage /
portrait_effect / studio_light / active_w / active_h`。`width`/`height` は**届いたフレーム**、
`active_w`/`active_h` は**デバイスが持っているフォーマット**で、両者を見ると指定が効いたか判別できる。

Info DAT: フォーマット1件=1行で `index / width / height / pixel / max_fps`。

### 注意

- **AVFoundation はエラーを返さず Objective-C 例外を投げる。** fps から自分で作った `CMTime` を
  `setActiveVideoMinFrameDuration:` に渡したら TouchDesigner ごと落ちた。現在はフレーム持続時間を
  システムの `AVFrameRateRange` からそのまま取り、設定呼び出しはすべて例外で包んでいる
- **素の CLI はカメラ権限を取れない**ので、検証は TD 内で行うか、署名した .app にする必要がある

### ビルド

```bash
cd AVFoundationCamera && ./build.sh
```
