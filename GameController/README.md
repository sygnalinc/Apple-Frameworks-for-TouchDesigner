# GameController CHOP

PS5(DualSense)/ Xbox / MFi ゲームパッド入力(GameController framework)。
TD標準 Joystick CHOP のモダン代替。アナログトリガー・モーションセンサー・
ランブル(CoreHaptics振動)対応。

## 出力チャンネル

`connected / a b x y / l1 r1 l2 r2(アナログ)/ lstickx y / rstickx y / dpadx y /
menu options / lstickbtn rstickbtn`(+ Motion時 `gravity xyz / accel xyz`)

## パラメータ

| 名前 | 内容 |
|---|---|
| Controller Index | 0〜7(複数台) |
| Motion Sensors | 対応パッド(DualSense等)の重力/加速度を出力 |
| Rumble | 0〜1 の連続振動(対応パッドのみ・CoreHaptics) |

## 検証状況

- ビルド・ロード・未接続時の`connected=0`/警告表示を確認済み。
  **実機パッドでの値・振動は未検証**(パッド接続後に要確認)
- BluetoothのパッドはmacOSとペアリング後に `[GCController controllers]` に現れる

## ビルド

```
cd GameController && ./build.sh   # → build/GameControllerCHOP.plugin
```
