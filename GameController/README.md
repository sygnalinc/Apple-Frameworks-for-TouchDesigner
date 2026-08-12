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

`/project1/GameController` in `demo.toe` flies a camera drone around a small city. The screen
shows the drone's own camera (centre top), the third-person view of the drone being flown (bottom
left), and a live panel of the controller (bottom right) with telemetry between them.

Left stick / WASD moves horizontally relative to the nose; right stick yaws (X) and tilts the
gimbal (Y); R2/L2 climb and descend; R1/L1 widen and narrow the FOV; A levels the gimbal, B
boosts, X snaps to top-down, Y returns to origin; the D-pad snaps altitude and heading; Menu /
Options / R resets. It falls back to the keyboard when no pad is attached.

Input is applied as **acceleration with exponential damping**, not as a direct position change —
that is what gives it the inertia that reads as a drone. See the Japanese section below for the
orientation convention that keeps forward/right from coming out inverted.

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

`/project1/GameController` に**ドローン飛行デモ**を組んである。3D空間のカメラを操縦する。

| 画面 | 内容 |
|---|---|
| 中央上 `CAMERA` | カメラが撮っている映像(`render_pov`) |
| 左下 `THIRD PERSON` | 操縦している様子(`render_tps`)。カメラ本体はこちらにだけ写る |
| 右 `CONTROLS` | 操作方法(`help` = CoreText TOP) |
| 右下 | 入力パネル。押したボタン・スティック・トリガーが光る |
| 中央下 | テレメトリ(ALT / SPD / FOV / HDG / GIMBAL) |

**カメラの操縦**(`drone` DAT)

| 入力 | 動作 |
|---|---|
| 左スティック 前後 / W S | **カメラが向いている方向へ進む**(チルト込み)。見上げれば上昇、真下を向けば降下 |
| 左スティック 左右 / A D | 水平に平行移動(自動でバンクする) |
| 右スティック X / Q E | **バンク旋回**(倒した量ぶん傾き、その傾きで旋回する)。単独のヨーは無い |
| 右スティック Y | チルト(カメラの俯仰)。上に倒すと見上げる |
| R2 / Space, L2 / Shift | 上昇 / 下降 |
| L1 / R1、Z / X | FOV 望遠 / 広角(L1=望遠) |
| Options | **サードパーソンのビュー切替**(CHASE / TOP / MAP) |
| Menu / R | リセット |

**シーン(VJ)**(`vj` DAT)

| 入力 | 動作 |
|---|---|
| A / `1` | ワイヤーフレーム切替 |
| B / `2` | **オーディオ連動**(ビルの高さが音に反応)切替 |
| X / `3` | カラーパレット送り(4種) |
| Y / `4` | ストロボ(低域のレベルでビルが発光)切替 |
| 十字 上下 / `5` `6` | 連動の強さ − / + |
| `7` / `8` | ビルの本数 − / +(20〜200) |
| 十字 左右 / `9` | 街を作り直す(シード送り) |

**パッドが無くてもキーボードだけで飛ばせる。**

### 広さの設定

| | 値 |
|---|---|
| 水平の行動半径 `RANGE` | 170 |
| 高度上限 `ALTMAX` | 220 |
| FOV `FOVMIN` / `FOVMAX` | 18 / **160**(広角側を広く取ってある) |
| 地面・グリッド | 440×440(45分割 = 1マス約10単位) |
| 街 | ビル半径 126・既定180本(20〜400) |

**行動範囲だけ広げると地面の外に出てしまう。** `RANGE` を変えたら地面・グリッド・街の広がりも
一緒に見直すこと。実測で確認: x=165(端)でも地面が続き、FOV 160 の超広角、高度 220 からの
全景いずれも破綻しない。

### サードパーソンのビュー(Options で切替)

| モード | 内容 |
|---|---|
| `CHASE` | 斜め後ろから。**本体と同じ高さに置くので視線は常に水平**(見下ろさない) |
| `TOP` | 本体の真上(高さ28)から真下。**回転せず平行移動だけ**で追う |
| `MAP` | 原点の真上210から真下。街全体が入る(FOV 70 で幅約294単位) |

`CHASE` の**向きは Look At でカメラ本体に固定している**ので、位置の追従が遅れても**必ず画面中央に
写る**。**高さは補間せず本体と同じ値を入れる**ため、Look At の向きは必ず水平になる
(実測: 前方ベクトルの y = 0.000 / 仰角 0.00度)。

`TOP` / `MAP` は Look At を外して `rx = -90` 固定(真下向きは Look At だと up ベクトルが定まらない)。

> **Look At は「向き」を決めるが、`rx`/`ry`/`rz` はその上から適用される。** `TOP`/`MAP` で入れた
> `rx = -90` を戻さずに `CHASE` へ戻ると **90度ロールした絵**になる。`CHASE` に入るとき
> `rx`/`ry`/`rz` を 0 に戻すこと。
>
> **検証は前方ベクトルだけでは足りない** — 90度ロールしても前方は水平のままなので気づけない。
> **上ベクトルが (0,1,0) か**を見る(実測: 修正前 (0.392, 0, −0.920) / 修正後 (0.000, 1.000, 0.000))。
**水平方向だけ補間し、高さは固定オフセット**。ビューを変えた瞬間は補間せず**スナップ**させる。

`MAP` では機体が数ピクセルにしかならない。**位置を確認するのは `TOP`**。

### バンク旋回

**右スティック左右**で旋回する。倒した量を目標のバンク角にし、`BANKLERP`(4.0/秒)で追従させる:

```python
st['roll'] += (-turn * BANKMAX - st['roll']) * min(1.0, BANKLERP * dt)
st['yaw']  += (st['roll'] / BANKMAX) * BANKTURN * dt
```

**旋回量を入力ではなく「今の傾き」に比例させている**のが要点で、こうすると**傾きが戻れば旋回も
自然に止まり**、アナログの倒し量がそのまま旋回速度になる。**単独のヨーは持たない**
(旋回は必ずバンクを伴う)。

**実測**(結合の確認): `roll` = 0.80 を入れて中立に戻すと roll は 0.16 → 0.03 → 0.007 と減衰し、
yaw は +0.33 → +0.40 → +0.41 rad と回って収束する(合計 約24度)。倒し続けている間は
目標バンクを保つので `BANKTURN`(1.9 rad/秒)で回り続ける。

画面の CONTROLS にキーボードは載せていない。キーボードは W A S D / Q E(バンク旋回)/ Space / Shift /
Z X(FOV)/ `1`–`4`(シーン)/ `5` `6`(強さ)/ `7` `8`(本数)/ `9`(街の作り直し)/
R(リセット)。

**スティック押し込み(L3/R3)は使っていない** — 付いていないパッドがあるため。

### オーディオ連動(VJ)

`audio`(Audio File In)は **TD 同梱のサンプル曲を `app.installFolder` からのパス式で参照**している。
著作物なのでリポジトリにはコピーしていない。**Audio Device Out は繋いでいないので音は鳴らず**、
解析にだけ使う。`spectrum`(Audio Spectrum)は Output = **Set Manually** で 128 サンプル。

**実測**: バンド値は中央値 0.005〜0.04 / 上位10% 0.02〜0.27 / 最大 0.6。**線形に使うと大半の
ビルが動かない**ので `(mag * 6) ** 0.6` のガンマで小さい値を持ち上げている。立ち上がりは即時・
落ちは 12%/frame。`amt` = 2.0 での実測で、ビルの高さが 17.2 → 27.3 のように大きく動く。

**Script CHOP は入力が無いと毎フレーム cook しない。** 音連動中は `vj` DAT が `city` を
force cook する。

シーンの状態は storage `'vj'` に置き、`city` の Script CHOP がそれを読んでビルを作る。
マテリアル(ワイヤーフレーム / パレット)は**値が変わったときだけ**当てている。

### 飛行のさせ方

入力は**加速度として与え、毎フレーム `exp(-DAMP*dt)` で減衰させている**。位置を直接動かすより
慣性が出てドローンらしくなる。機体の roll はスティック入力を補間したもので、
進行方向へバンクして見える。

**前進はカメラが向いている方向そのもの**(チルト込み):

```
Ry(yaw) * Rx(gim) * (0,0,-1) = (-cos(gim)sin(yaw), sin(gim), -cos(gim)cos(yaw))
```

平行移動(左右)と R2/L2 の昇降は水平・鉛直のまま。**検証**: 4通りの `yaw`/`gim` でこの式と
`cam.worldTransform` の前方軸を比べ、差は **6.4e-08 以下**(float の丸め)。見上げ(`gim` +0.40)で
y成分 +0.389、真下(`gim` -1.20)で -0.932 と、意図どおり上下する。

### バンク(旋回の傾き)

`L1` で左へ、`R1` で右へ `roll` を rate 操作し、**離すと `BANKLERP`(3.2/秒)で水平へ戻る**。
本体とカメラは親子付けしてあるので、バンクすると **POV の水平線もそのまま傾く**(ダッチアングル)。

**`geo_camera` の Rotate Order は `zxy`(= Ry·Rx·Rz)にしてある。** これは見た目の好みではなく必須:

| Rotate Order | `rz` を 0 → 30度 にしたときの前方ベクトル |
|---|---|
| `xyz`(既定・= Rz·Ry·Rx) | (−0.604, −0.342, −0.720) → **(−0.352, −0.598, −0.720)** |
| `zxy`(= Ry·Rx·Rz) | (−0.604, −0.342, −0.720) → **(−0.604, −0.342, −0.720)** |

既定の `xyz` だと `rz` が最後に効くので**世界のZ軸まわり**に回り、バンクさせると**視線方向まで
変わってしまう**。`zxy` なら roll を最初に適用するので**カメラの光軸まわり**になり、前方ベクトルは
roll で一切変わらない(bank 0 / +25 / −40度で差 **2.8e-08**)。前進の式
`Ry(yaw)·Rx(gim)·(0,0,-1)` も、バンクしていて正しいままになる。

以前は平行移動の入力から自動でバンクさせていたが、手動操作と競合するので廃止した。

**検証**: `roll` = 0.55 rad を入れて離すと **0.3秒で 1.8度、1秒で 0.1度**まで戻る。
カメラの上ベクトルの傾きは `geo_camera.rz` と一致する(31.51度で確認)。

### 画面レイアウトを1つの GLSL にまとめている

Transform TOP と Composite TOP を並べる代わりに、`screen`(GLSL TOP)がピクセル座標を見て
2枚のレンダを矩形へ貼り、枠とキャプションを描いている。**位置と枠線を数値で決められ、
ノードも増えない**。キャプションはシェーダ内の 5×7 ビットマップ(A–Z)。

**自機を POV に写さないのは Render TOP の `geometry`** で分けている
(`render_pov` は `geo_grid geo_ground geo_city`、`render_tps` は `*`)。

飛んでいる本体は**ビデオカメラの形**(本体+ハンドル+レンズ鏡筒+フード+ビューファインダ)。
**単色の Constant MAT だと立体が見えず箱にしか見えない**ので Phong にしてある。
サードパーソンは真後ろではなく**斜め後ろ**(`TPSSIDE`)から見ていて、レンズの向きが分かる。

### 本体と搭載カメラは親子付けする

**搭載カメラは `geo_camera` の子にしてある**(`cam` の Xform Source = `Specify` /
Parent Object = `geo_camera`)。`cam` 自身は `tx,ty,tz = (0, 0, -0.95)` でレンズ前玉に固定、
回転は 0。**本体を動かすだけでカメラが付いてくるので、姿勢のずれが構造的に起きない。**

最初は位置と回転を Python で両方に書いていて、しかも本体の `rx` は移動による前後の傾き、
カメラの `rx` はジンバル角と**別物を入れていた**(ロールも本体が全量・カメラが 0.35 倍)。
**同じ値を2箇所で維持する作りは、いずれずれる。**

**検証**: 任意の `rx`/`ry`/`rz` を本体に入れて両者の `worldTransform` を比べると、
**回転成分の差は `0.000e+00`(ビット一致)**、カメラ位置は常にレンズ軸上ちょうど 0.95。

> 向きの一致を `acos(dot)` で測ると **`dot`≒1 付近で誤差が拡大し、0.01〜0.02度の嘘の差**が出る。
> 実際これで「まだ僅かにずれている」と誤読しかけた。**行列の要素を直接比べること。**

### 画面右下の入力パネル

`padflat`(Shuffle)→ `padview`(GLSL TOP)→ `screen` で右下に重ねている。押したボタン・
倒したスティック・トリガーの踏み具合がそのまま光るので、**配線の確認にもそのまま使える**。

- **GLSL TOP の Array に CHOP を直結すると texel 数 = サンプル数**になる。19ch×1sample の
  CHOP は 1 texel しか渡らないので、**Shuffle の Sequence All Channels で 1ch×19sample**
  に畳んでから渡す
- 文字(A/B/X/Y/L/R)はシェーダ内の **5×7 ビットマップ**で描いている
- 点灯の見た目は、19ch の Constant CHOP にダミー値を入れて `array0chop` を一時的に
  差し替えて検証した(**パッドを押してもらわなくても確かめられる**)

**GameController は「印字」でボタンを返す**(印字 A = `a`)。したがってパネルのラベルは
チャンネルに固定でよく、**パッドごとに変わるのは配置のほう**:

| | 上 | 左 | 右 | 下 |
|---|---|---|---|---|
| 任天堂配列 | X | Y | A | B |
| Xbox配列 | Y | X | B | A |

パネルは手元のパッド(任天堂配列)の配置に合わせてある。`menu` / `options` の2つのピルも同様で、**左が options(小さい四角)、右が menu(＋)**。Xbox配列を使うなら `padview` の
シェーダで A と B、X と Y のオフセットを入れ替える。

**ここは一度間違えた**: 「印字とチャンネル名がずれている」と考えてラベルのほうを入れ替えたが、
実際にずれていたのは配置だけで、ラベルを入れ替えたせいで**押したボタンと光る場所の両方が
食い違った**。仕様を推測で決めず、実機で「どのボタンを押すとどの ch が立つか」を先に確かめること。

### 組むときの注意

- **`soptoPOP` はメッシュ/NURBS を変換しない。** Sphere / Grid SOP の既定 `type` は `mesh` で、
  そのままだと**何も描画されない**。`poly` にすること(Box SOP は既定が `poly`)
- **向きの規約を1箇所に決めて全部それに合わせる。** ここでは
  「ヨー yaw に対して 前方 `F = (-sin, 0, -cos)` / 右 `R = (cos, 0, -sin)`」とし、
  機体も `ry=0` で -Z を向くように組んだ。決めずに書くと**前後や左右が逆になる**
  (実際に左スティックYと右スティックXが逆になっていた)
- **ノードをリネームすると Geometry COMP の Instance OP 参照が外れる**(`None` になる)。
  リネーム後は必ず張り直す。実際に街のビルが1棟も出なくなった
- **Geometry COMP の `material` が未設定だと白で描かれる。** マテリアル側の色をいくら変えても
  効かないので、色が反映されないときはまず `material` を疑う
- **`phongMAT` の色は `diffr` / `diffg` / `diffb`**(`diffuser` ではない)
- **Grid SOP は線を作れない**(`type` は poly/mesh/nurbs/bezier のみ)。グリッド線は面を
  **Wireframe MAT** で描く。`Wire Width` は macOS では効かない(線は常に1px)ので、
  太い線が要るなら板ポリゴン(リボン)にする
- Grid SOP は XY 平面。地面にするには Geo ごと `rx=-90`
