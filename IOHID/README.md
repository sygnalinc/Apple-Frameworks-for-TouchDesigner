# IOHID CHOP

`IOHIDManager` で任意のUSB/Bluetooth **HIDデバイス**(ゲームパッド/フットペダル/ノブ/計測器/センサ等)の
raw入力を読み、各要素(usage)の値をCHOPチャンネルとして出力する。バックグラウンドスレッドの run loop で
値変化コールバックを受け、cook は最新値をスナップショットするだけ(非ブロック)。

## パラメータ

| パラメータ | 説明 |
|---|---|
| Active | 有効 |
| Usage Page / Usage | 対象デバイスの絞り込み(0=任意)。例: Generic Desktop=1, Joystick=4, Gamepad=5 |
| Vendor ID / Product ID | 特定製品の絞り込み(0=任意) |

出力: `p{page}_u{usage}_c{cookie}`(各入力要素の値)。Info CHOP: `executes / elements / open`

## 注意

- **modern macOS では HID 入力に「入力監視(Input Monitoring)」権限(TCC)が要る**。未許可だと
  デバイス/要素が0件になる(システム設定 > プライバシーとセキュリティ > 入力監視 で TouchDesigner を許可)
- チャンネルは接続デバイスの Input 要素(Misc/Button/Axis)から生成される
- GameController CHOP はゲームパッド専用の高レベルAPI。HID CHOP は任意HIDの raw アクセス

## ビルド
```
cd HID && ./build.sh
```
