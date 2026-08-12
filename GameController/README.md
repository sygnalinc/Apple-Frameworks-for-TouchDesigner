# GameController CHOP

**English** | [日本語](#日本語)

## English

Gamepad input from PS5 (DualSense) / Xbox / MFi controllers via the GameController framework.
A modern replacement for TD's built-in Joystick CHOP, with analog triggers, motion sensors and
rumble (CoreHaptics vibration).

### Output channels

`connected / a b x y / l1 r1 l2 r2 (analog) / lstickx y / rstickx y / dpadx y /
menu options / lstickbtn rstickbtn` (plus `gravity xyz / accel xyz / rot xyz` when Motion is on)

### Parameters

| Name | Description |
|---|---|
| Controller Index | 0–7 (multiple controllers) |
| Motion Sensors | Adds 9 motion channels on pads that have sensors. See below — `gravity*` stays 0 on most pads |
| Rumble | Continuous vibration 0–1 (supported pads only, via CoreHaptics). **Only runs while the CHOP cooks** — a short pattern is re-armed each cook, so it stops on its own if cooking stops |
| Pulse | **One-shot vibration** — press to fire a single haptic pattern. Independent of `Rumble`; firing one while the pad is rumbling does not disturb it |
| Pulse Style | `Tap` / `Click` / `Thud` / `Double Tap` / `Buzz` |
| Pulse Intensity / Sharpness | Strength (0–1) and how hard-edged it feels (0–1) |
| Pulse Gap | Spacing of `Double Tap`, in seconds. **Widen it until you hear two hits** — how long the actuator keeps ringing varies by pad |

### Motion sensors

**`gravity*` staying 0 is not a bug.** Apple's docs say some controllers cannot separate gravity
from user acceleration. Switch Pro-style and DualShock-style pads are in that group; Xbox-style
pads have no motion sensors at all.

| Channel | Pad can separate | Pad cannot separate |
|---|---|---|
| `gravity*` | gravity vector | **0** |
| `accel*` | user acceleration (gravity removed) | **total acceleration (gravity included)** |
| `rot*` | angular velocity, rad/s | angular velocity, rad/s |

So **`accel*` always carries something** as long as the pad has sensors, and `rot*` is usually the
most useful signal on a gyro pad. Check what you actually have in the Info CHOP: `hasmotion` /
`hasgravity` / `hasrotation` / `sensorsactive`. If `hasmotion` is 0 the op warns you — an
Xbox-mode pad has no sensors, so try Nintendo Switch mode.

Sensors stay off until asked for (they drain the battery), so **the first frame after switching
Motion Sensors on still reads 0**.

### Haptic presets

**CoreHaptics has no named presets.** It gives you two event types (transient / continuous) and a
few parameters; the familiar feels are built from those. `Pulse Style` does **not** move the
Intensity / Sharpness sliders — it changes the pattern, and the sliders always apply on top.

| Style | Continuous length | Hits |
|---|---|---|
| `Click` | 0.03 s | 1 |
| `Tap` | 0.08 s | 1 |
| `Double Tap` | 0.06 s | 2, spaced by **Pulse Gap** (default 0.26 s) |
| `Thud` | 0.22 s | 1 |
| `Buzz` | 0.40 s | 1 |

**How long a pad keeps ringing varies, so `Double Tap` needs tuning.** 0.20 s split cleanly into two
hits on an Xbox-mode pad (rotating motors) but still read as one in Nintendo Switch mode (HD rumble,
linear actuators). `Pulse Gap` exists to dial that in — widen it until you hear two.

**The styles differ by length and hit count, not by texture.** Pads that are just two rumble
motors (Xbox-style) largely ignore `Sharpness`, so a transient-only pattern makes `Tap` and `Click`
feel identical. Each style therefore layers a transient (for pads that support it) over a short
continuous event (what the motors actually reproduce).

Add your own by editing `playPulse`.

### Measured (M2 / macOS 26.6, XPT compact Bluetooth gamepad)

`connected` goes to 1 (it is set only when `extendedGamepad` is non-nil, so it means a real pad
is present), and **all 18 input channels respond**: `a` `b` `x` `y`, `l1` `r1`, the analog
triggers `l2` `r2`, `dpadx` `dpady`, `menu` `options`, both stick clicks, and all four stick axes
at full ±1.00 scale.

**Sampling a button from outside TD will miss it.** Polling the CHOP every few hundred
milliseconds drops presses shorter than the interval — that is a measurement artifact, not an
unmapped button. Latch the maximum inside TD instead:

```python
# Execute DAT, onFrameEnd
def onFrameEnd(frame):
    d = op('..').fetch('probe', {})
    for c in op('gamecontroller1').chans():
        d[c.name] = max(d.get(c.name, 0.0), abs(c.eval()))
```

Rumble and Pulse are both confirmed on a pad in Xbox mode — including `Double Tap` reading as two
hits, and no crash when the pad switches modes. Rumble **only runs while the CHOP cooks**: a short
pattern is re-armed on each cook, so setting `Rumble` back to 0 — or the node simply not cooking —
stops the motor within about a second. (Earlier the pattern lasted an hour, so a pad could keep
buzzing after the value went back to 0 if nothing cooked the CHOP.)

Bluetooth pads appear in `[GCController controllers]` once paired with macOS.

**A plain command-line process sees zero controllers even while TouchDesigner sees one** —
GameController discovery needs a GUI app, so debug from inside TD rather than a standalone binary.

**CoreHaptics raises ObjC exceptions, it does not just return an `NSError`.** Calling `stopAtTime:`
on a player whose engine has stopped throws, and an ObjC exception unwinding into C++ terminates
the process — switching the pad between Switch and Xbox mode (a disconnect and reconnect as a
different device) crashed TouchDesigner this way. Every CoreHaptics call here is wrapped in
`@try`/`@catch`, the engine is rebuilt when the controller changes, and `stoppedHandler` /
`resetHandler` flag it as dead so the next cook drops the stale references.

### Example

`/project1/GameController` in `demo.toe` uses this CHOP to fly a camera through a 3D scene —
its own camera view, a third-person view, a live input panel and scene switching in one container.
The wiring and controls are written up in the `note` DAT inside it.

What matters for **using the CHOP**:

| You want | Channels |
|---|---|
| Continuous control (move / turn / zoom) | `lstickx/y`, `rstickx/y`, `l2`, `r2` (analog) |
| Fire once per press | `a` `b` `x` `y` `menu` `options` — detect the **rising edge** yourself |
| Act while held | use the value directly |
| Snap steps | `dpadx`, `dpady` (digital ±1) |

- **Rising-edge detection is on you.** The CHOP only reports the current value, so keep the
  previous one and test `value > 0.5 and prev <= 0.5`
- **Some pads have no stick click** (`lstickbtn` / `rstickbtn`). Don't put essential controls there
- **Don't write `Rumble` every frame.** A script that sets it to 0 each cook makes the slider
  impossible to drag by hand — it snaps back before you feel anything. Pulse it, then clear it once
- To draw a panel that lights up on press, fold the CHOP to `1ch × Nsample` with a **Shuffle
  (Sequence All Channels)** before feeding a GLSL TOP array — wiring it directly gives one texel
  per *sample*, so 19ch × 1sample arrives as a single texel

### Build

```
cd GameController && ./build.sh   # → build/GameControllerCHOP.plugin
```

## 日本語

PS5(DualSense)/ Xbox / MFi ゲームパッド入力(GameController framework)。
TD標準 Joystick CHOP のモダン代替。アナログトリガー・モーションセンサー・
ランブル(CoreHaptics振動)対応。

### 出力チャンネル

`connected / a b x y / l1 r1 l2 r2(アナログ)/ lstickx y / rstickx y / dpadx y /
menu options / lstickbtn rstickbtn`(+ Motion時 `gravity xyz / accel xyz / rot xyz`)

### パラメータ

| 名前 | 内容 |
|---|---|
| Controller Index | 0〜7(複数台) |
| Motion Sensors | センサーを持つパッドで9chを追加。下記参照 — `gravity*` は多くのパッドで0のまま |
| Rumble | 0〜1 の連続振動(対応パッドのみ・CoreHaptics)。**cook されている間だけ続く** — 短いパターンを毎cook掛け直しているので、cook が止まれば自然に止まる |
| Pulse | **単発の振動**。押すと1回だけ鳴る。`Rumble` とは別プレイヤーなので、連続振動中に撃っても邪魔しない |
| Pulse Style | `Tap` / `Click` / `Thud` / `Double Tap` / `Buzz` |
| Pulse Intensity / Sharpness | 強さ(0〜1)と当たりの硬さ(0〜1) |
| Pulse Gap | `Double Tap` の間隔(秒)。**2回に聞こえるまで広げる** — 余韻の長さはパッドによって違う |

### モーションセンサー

**`gravity*` が 0 のままなのは不具合ではない。** Apple のドキュメントが明言しているとおり、
**重力と動きを分離できないパッドがある**。Switch Pro 系・DualShock 系がその側で、
Xbox 系はそもそもセンサーを持たない。

| チャンネル | 分離できるパッド | 分離できないパッド |
|---|---|---|
| `gravity*` | 重力ベクトル | **0** |
| `accel*` | 重力を除いた動き | **重力込みの合計加速度** |
| `rot*` | 角速度(rad/s) | 角速度(rad/s) |

したがって**センサーさえあれば `accel*` には必ず値が入る**。ジャイロ付きパッドでは `rot*` が
一番使いやすい。何が取れているかは Info CHOP の `hasmotion` / `hasgravity` / `hasrotation` /
`sensorsactive` で確認する。`hasmotion` が 0 のときは警告が出る(Xbox モードのパッドは
センサーが無いので Nintendo Switch モードを試す)。

センサーは電池を食うので既定では止まっており、**On にした直後の1フレームは 0 のまま**。

### 振動のプリセットについて

**CoreHaptics に名前付きのプリセットは無い。** あるのはイベント2種(transient / continuous)と
少数のパラメータで、よくある触感はそこから組み立てる。`Pulse Style` を変えても
**Intensity / Sharpness のスライダーは動かない** — 変わるのはパターンで、スライダーは常に上乗せされる。

| スタイル | continuous の長さ | 打数 |
|---|---|---|
| `Click` | 0.03秒 | 1 |
| `Tap` | 0.08秒 | 1 |
| `Double Tap` | 0.06秒 | 2(**Pulse Gap** の間隔。既定0.26秒) |
| `Thud` | 0.22秒 | 1 |
| `Buzz` | 0.40秒 | 1 |

**余韻の長さはパッドによって違うので、`Double Tap` は調整が要る。** 0.20秒は Xbox モード
(回転モーター)ではきれいに2回に分かれたが、Nintendo Switch モード(HD振動・リニアアクチュエータ)
では1回に聞こえた。`Pulse Gap` はそのための調整用で、2回に聞こえるまで広げる。

**違いは「長さと打数」であって触感の質ではない。** Xbox系のようにモーター2個のパッドは
`Sharpness` をほとんど反映しないので、transient だけのパターンだと `Tap` と `Click` が
区別できない。そのためどのスタイルも transient(対応パッド用)に短い continuous
(モーターが実際に再現する部分)を重ねてある。

増やしたいときは `playPulse` に足す。

### 実測(M2 / macOS 26.6・XPTの小型Bluetoothパッドを接続)

`connected` が 1 になる(`extendedGamepad` が取れたときだけ立てているので、
本当にパッドがある場合のみ 1)。そのうえで **入力18chすべてが反応する**ことを確認した:
`a` `b` `x` `y`、`l1` `r1`、アナログトリガー `l2` `r2`、`dpadx` `dpady`、
`menu` `options`、スティック押し込み2つ、スティック4軸(±1.00 のフルスケール)。

**TDの外からのサンプリングではボタンを取りこぼす。** 数百ms間隔でCHOPをポーリングすると、
それより短い押下は当たらない。**これは測り方の問題であって、割り当てが無いのではない**
(実際に一度これで「動かないボタン」と誤って結論した)。TD内で最大値をラッチしてから読む:

```python
# Execute DAT の onFrameEnd
def onFrameEnd(frame):
    d = op('..').fetch('probe', {})
    for c in op('gamecontroller1').chans():
        d[c.name] = max(d.get(c.name, 0.0), abs(c.eval()))
```

Rumble も Pulse も Xbox モードのパッドで実機確認済み(`Double Tap` が2回と分かること、
モード切替で落ちないことを含む)。Rumble は **cook されている間だけ続く**:
短いパターンを毎cook掛け直しているので、`Rumble` を 0 に戻しても、ノードが cook されなく
なっても、1秒ほどでモーターが止まる。(以前はパターンの長さが1時間だったため、値を0に
戻しても CHOP が cook されなければ鳴りっぱなしになっていた。)

BluetoothのパッドはmacOSとペアリング後に `[GCController controllers]` に現れる。

**素のコマンドラインプロセスからは、TDが認識していてもコントローラが0台に見える** —
GameController の探索は GUI アプリを要求するため、切り分けは単体バイナリではなく TD 内で行う。

**CoreHaptics は NSError を返すのではなく ObjC 例外を投げる。** エンジンが止まった後の
`stopAtTime:` は例外になり、それが C++ 側へ伝わるとプロセスごと終了する。実際に
**パッドの Switch / Xbox モード切替**(切断 → 別デバイスとして再接続)で TouchDesigner が落ちた。
CoreHaptics に触る箇所は全て `@try`/`@catch` で包み、パッドが変わったらエンジンを作り直し、
`stoppedHandler` / `resetHandler` で死亡フラグを立てて次のcookで参照を捨てている。

### ビルド

```
cd GameController && ./build.sh   # → build/GameControllerCHOP.plugin
```

## 利用例(demo.toe)

`/project1/GameController` に、このCHOPで3D空間のカメラを操縦する例を置いてある。
搭載カメラの映像・サードパーソン・入力パネル・シーン切替を1つのコンテナにまとめたもの。
配線と操作の詳細はコンテナ内の `note` DAT に書いてある。

**このCHOPを使う側の要点**:

| やりたいこと | 使うチャンネル |
|---|---|
| 連続量(移動・旋回・ズーム) | `lstickx/y` `rstickx/y` `l2` `r2`(アナログ) |
| 押した瞬間だけ反応 | `a` `b` `x` `y` `menu` `options` を**立ち上がり検出**する |
| 押している間だけ有効 | 値をそのまま使う |
| 方向のスナップ | `dpadx` `dpady`(デジタル ±1) |

- **立ち上がり検出は自前で行う。** CHOPは現在値しか出さないので、前フレームの値を持って
  `value > 0.5 and prev <= 0.5` で見る
- **スティック押し込み(`lstickbtn` / `rstickbtn`)が無いパッドがある。** 必須の操作に割り当てない
- **`Rumble` を毎フレーム書かない。** 毎cook 0 を書くスクリプトがあると、手でスライダーを
  動かしても即座に戻されて振動を確認できない。パルスさせたら**一度だけ**0に戻す
- 押した所が光るパネルを作るなら、CHOPを **Shuffle の Sequence All Channels** で
  `1ch × Nsample` に畳んでから GLSL TOP の Array へ渡す。直結すると texel 数 = **サンプル数**に
  なり、19ch × 1sample は 1 texel しか届かない
