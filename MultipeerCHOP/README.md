# Multipeer CHOP + iPhone センサーアプリ

**iPhone/iPad をワイヤレスセンサーにする**。iOS 端末のモーション(ジャイロ・加速度・
姿勢)・画面タッチを、MultipeerConnectivity で Mac の TouchDesigner へ**低遅延で毎フレーム
送信**し、CHOP チャンネルとして受ける。テキスト用 [Multipeer DAT](../Multipeer/) の
数値(CHOP)版。サーバー不要・同一ローカルネットワークで自動接続。

## 実測(M2)

- 擬似送信ピア(macOS)から4chパケットを送り、CHOP が **gyro_x / gyro_y / accel_z / touch
  のチャンネルを動的生成し値を受信**することを確認(accel_z=0.98・touch=1.0 が一致)
- 受信は unreliable(低遅延)モード。パケットの各フィールド名がそのままチャンネル名になる

## 受信チャンネル(iOSアプリ送信時)

`gyro_x/y/z`(角速度)・`accel_x/y/z`(重力除去済み加速度)・`gravity_x/y/z`・
`roll/pitch/yaw`・`heading`・`touch`(0/1)・`touch_x/touch_y`(0〜1)

複数台つなぐ場合は **Prefix Peer Name** をオンにするとチャンネル名が `<端末名>/gyro_x`
のように分離される。

## パラメータ

| 名前 | 内容 |
|---|---|
| Peer Name | 自分の表示名 |
| Service Type | iOSアプリと一致させる(既定 `td-sensor`。1〜15文字・英小文字数字とハイフン) |
| Prefix Peer Name | チャンネル名に送信元名を付ける(複数台の区別) |

入力 CHOP を繋ぐと、その各チャンネルを毎フレーム全ピアへ送る(iPhone を出力先=表示や
ハプティクスにも使える。iOS側の受信実装は別途)。

Info CHOP: `executes / peers / channels`

## ワイヤープロトコル(TDMP)

リトルエンディアン。CHOP と iOS アプリで共通:

```
"TDMP"(4B) | uint16 count | count × { uint8 nameLen, name(UTF8), float32 value }
```

自作の送信側(Arduino+WiFi 等ではなく Apple 系デバイス)を作るときはこの形式に合わせる。

## iOS サンプルアプリのビルド(`ios/TDSensor/`)

Apple Developer アカウント(無料でも実機7日間可)と Xcode が必要。

1. Xcode で **新規プロジェクト → iOS → App**(Interface: SwiftUI、Language: Swift)を作成
2. `ios/TDSensor/` の3ファイル(`TDSensorApp.swift` / `SensorSender.swift` /
   `ContentView.swift`)をプロジェクトに追加(既定の `ContentView.swift` は置き換え)
3. Target の Info に `Info-additions.plist` の3キーを追加:
   - **NSLocalNetworkUsageDescription**(ローカルネットワーク許可)
   - **NSBonjourServices** = `_td-sensor._tcp` / `_td-sensor._udp`
   - **NSMotionUsageDescription**(モーション使用目的)
4. iPhone を USB 接続して実機ビルド(Signing に自分の Apple ID チームを設定)
5. アプリで **Start Sending** → Mac の Multipeer CHOP と同じ Wi-Fi なら自動接続

初回起動時にローカルネットワーク・モーションの許可ダイアログが出る。

## 注意

- **Multipeer は同一ローカルネットワーク(または Bluetooth 圏内)が前提**。会場では
  Mac と iPhone を同じ Wi-Fi(できれば専用 AP)に繋ぐ
- unreliable 送信なのでパケットは落ちうる(センサー値は毎フレーム上書きなので問題ない)
- Service Type は CHOP とアプリで**完全一致**させること

## ビルド(CHOP 本体)

```
cd MultipeerCHOP && ./build.sh   # → build/MultipeerCHOP.plugin
```
