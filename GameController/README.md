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

### Status

- Build, load, and `connected=0` plus a warning when nothing is attached are all confirmed.
  **Values and rumble on a real gamepad are unverified** (needs checking once a pad is connected)
- Bluetooth pads appear in `[GCController controllers]` after being paired with macOS

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

### 検証状況

- ビルド・ロード・未接続時の`connected=0`/警告表示を確認済み。
  **実機パッドでの値・振動は未検証**(パッド接続後に要確認)
- BluetoothのパッドはmacOSとペアリング後に `[GCController controllers]` に現れる

### ビルド

```
cd GameController && ./build.sh   # → build/GameControllerCHOP.plugin
```

## 利用例(demo.toe)

`/project1/GameController` に**簡易3Dアクション**を組んである。制限時間60秒でキューブを集める。

| 入力 | 動作 |
|---|---|
| 左スティック / W A S D | 移動(カメラの向き基準) |
| 右スティック / Q E | カメラ旋回 |
| A ボタン / Space | ジャンプ |
| Menu ボタン | リスタート |

取得時に `Rumble` で振動する。**パッドが無くてもキーボードで遊べる**ようにしてあるので、
接続前でも動作を確認できる。

ゲームのロジック(移動・ジャンプ・取得判定・スコア・タイマー・カメラ追従)は TD 上で実測済み。
**パッド実機での検証は未実施**(手元にコントローラが無いため)。

### 組むときの注意

- **`soptoPOP` はメッシュ/NURBS を変換しない。** Sphere / Grid SOP の既定 `type` は `mesh` で、
  そのままだと**何も描画されない**。`poly` にすること(Box SOP は既定が `poly`)
- TD のカメラは `ry=0` で -Z を向く。追従カメラはプレイヤーの `+sin/+cos` 側に置く
- Grid SOP は XY 平面。地面にするには Geo ごと `rx=-90`

