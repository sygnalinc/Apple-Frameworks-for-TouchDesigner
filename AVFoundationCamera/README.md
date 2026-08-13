# AVF Camera

**English** | [日本語](#日本語)

## English

Opens a camera with AVFoundation and outputs video, with device/format information and camera
controls that TouchDesigner's Video Device In TOP does not expose.

> **Status: experimental, and the headline feature does not work yet.** Explicit format selection is
> ignored by UVC cameras on macOS — see "What does not work" below. Read that before using this.

### What works (measured on M2 / macOS 26.6)

- **Enumerates more cameras than TD.** 6 vs TD's 5 on the same machine — the Continuity **Desk View
  camera** shows up here and not in TD's list
- **Full format table.** The Logicool BRIO reports 35 formats = **212 combinations** of
  resolution × pixel format × frame-rate range, listed in a menu and in the Info DAT. Notably
  **only one combination reaches 60 fps** (1280x720 / 420v); 1920x1080 tops out at 30
- Video output (BGRA, CPU upload) and device identity by `uniqueID`

### What does not work

- **Selecting a format has no effect on a UVC camera.** Setting `AVCaptureDevice.activeFormat`
  is silently ignored — `active_w` / `active_h` in the Info CHOP stay at 1920x1080 no matter which
  entry is chosen. These cameras surface through the legacy CoreMediaIO **DAL** path
  (`AVCaptureDALDevice`), which does not honour `activeFormat`
- The macOS alternative, `AVCaptureSession.sessionPreset`, did not change it either
- **iOS-only APIs**: `AVCaptureSessionPresetInputPriority`, ISO, exposure duration, exposure target
  bias, lens position, white-balance gains and zoom are all unavailable on macOS

### Not yet verified

- Whether Exposure / Focus **Locked** actually holds the image. `lockForConfiguration` succeeds, but
  the standalone probe used to check it had no camera permission, so the visual effect is unproven
- Frame rate is about 19 fps at 1920x1080. Whether that is the camera, the CPU copy or the cook
  is not yet isolated

### Parameters

| Parameter | Meaning |
|---|---|
| Active | Opens / closes the capture session |
| Device | Camera, held by `uniqueID` |
| Refresh Devices | Re-enumerate |
| Format | Resolution × pixel format × fps. **Currently ignored by UVC cameras** |
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

> **状態: experimental。しかも主目的の機能がまだ動いていない。** フォーマットの明示指定は
> macOS の UVC カメラでは無視される(下記「動かないこと」)。使う前にそこを読むこと。

### 動くこと(M2 / macOS 26.6 で実測)

- **TD より多くのカメラを列挙する。** 同じマシンで TD 5台に対し **6台**。Continuity の
  **デスクビューカメラ**はこちらにだけ出る
- **フォーマット表が出る。** Logicool BRIO は 35 フォーマット = 解像度 × 画素形式 ×
  fps レンジで **212 通り**。メニューと Info DAT に並ぶ。**60fps に届く組み合わせは1つだけ**
  (1280x720 / 420v)で、1920x1080 は 30fps 頭打ち
- 映像出力(BGRA・CPUアップロード)と `uniqueID` によるデバイス識別

### 動かないこと

- **UVC カメラではフォーマットを選んでも効かない。** `AVCaptureDevice.activeFormat` の指定が
  黙って無視され、どれを選んでも Info CHOP の `active_w` / `active_h` は 1920x1080 のまま。
  この種のカメラは旧来の CoreMediaIO **DAL** 経路(`AVCaptureDALDevice`)で見えており、
  `activeFormat` に対応していない
- macOS での代替である `AVCaptureSession.sessionPreset` でも変わらなかった。どの経路を通ったか
  計測したところ、**プリセットは実際に適用されていた**(`canSetSessionPreset` が true を返し、
  代入も実行された)にもかかわらず、届くフレームも `activeFormat` も 1920x1080 のままだった
- **UVC / DAL 固有ではない。** 内蔵の FaceTime HD カメラでも同じで、約34fps で流れているが
  1280x720 や 640x480 を選んでも 1920x1080 のまま変わらない
- **iOS 専用の API**: `AVCaptureSessionPresetInputPriority`、ISO、露出時間、露出補正、
  レンズ位置、ホワイトバランスゲイン、ズームはいずれも macOS には存在しない

### まだ検証できていないこと

- Exposure / Focus の **Locked** が実際に画を固定するか。`lockForConfiguration` は成功するが、
  確認に使った単体プローブにカメラ権限が無く、映像上の効果は未確認
- 1920x1080 で約 19 fps。カメラ側か、CPU コピーか、cook かの切り分けが未了

### パラメータ

| パラメータ | 意味 |
|---|---|
| Active | キャプチャセッションの開閉 |
| Device | カメラ。`uniqueID` で保持 |
| Refresh Devices | 再列挙 |
| Format | 解像度 × 画素形式 × fps。**現状 UVC カメラでは無視される** |
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
