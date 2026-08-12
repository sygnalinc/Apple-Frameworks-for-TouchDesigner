# GameController CHOP

**English** | [日本語](#日本語)

## English

Gamepad input from PS5 (DualSense) / Xbox / MFi controllers via the GameController framework.
A modern replacement for TD's built-in Joystick CHOP, with analog triggers, motion sensors and
rumble (CoreHaptics vibration).

### Output channels

`connected / a b x y / l1 r1 l2 r2 (analog) / lstickx y / rstickx y / dpadx y /
menu options / lstickbtn rstickbtn` (plus `gravity xyz / accel xyz` when Motion is on)

### Parameters

| Name | Description |
|---|---|
| Controller Index | 0–7 (multiple controllers) |
| Motion Sensors | Output gravity/acceleration on supported pads (DualSense etc.) |
| Rumble | Continuous vibration 0–1 (supported pads only, via CoreHaptics) |

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

Rumble fires (the example pulses it on pickup) but the vibration itself was not independently
confirmed.

Bluetooth pads appear in `[GCController controllers]` once paired with macOS.

**A plain command-line process sees zero controllers even while TouchDesigner sees one** —
GameController discovery needs a GUI app, so debug from inside TD rather than a standalone binary.

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
menu options / lstickbtn rstickbtn`(+ Motion時 `gravity xyz / accel xyz`)

### パラメータ

| 名前 | 内容 |
|---|---|
| Controller Index | 0〜7(複数台) |
| Motion Sensors | 対応パッド(DualSense等)の重力/加速度を出力 |
| Rumble | 0〜1 の連続振動(対応パッドのみ・CoreHaptics) |

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

Rumble は発火している(利用例が取得時にパルスしている)が、振動そのものは未確認。

BluetoothのパッドはmacOSとペアリング後に `[GCController controllers]` に現れる。

**素のコマンドラインプロセスからは、TDが認識していてもコントローラが0台に見える** —
GameController の探索は GUI アプリを要求するため、切り分けは単体バイナリではなく TD 内で行う。

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
- 押した所が光るパネルを作るなら、CHOPを **Shuffle の Sequence All Channels** で
  `1ch × Nsample` に畳んでから GLSL TOP の Array へ渡す。直結すると texel 数 = **サンプル数**に
  なり、19ch × 1sample は 1 texel しか届かない
