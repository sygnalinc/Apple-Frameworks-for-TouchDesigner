# Multipeer In / Out CHOP + iPhone センサーアプリ

**iPhone/iPad をワイヤレスセンサーにする**。MultipeerConnectivity で名前付き float
チャンネルのバイナリを低遅延(unreliable)で毎フレーム送受信する。テキスト用
[Multipeer In/Out DAT](../Multipeer/) の数値(CHOP)版。サーバー不要・同一ローカル
ネットワークで自動接続。

**送受信の向きが名前で分かるよう2オペレータに分割**:

| OP | opType | 役割 | 入出力 |
|---|---|---|---|
| **Multipeer In** CHOP | `Multipeerin` | ピア → TD **受信** | 入力なし。受信chを動的生成して出力 |
| **Multipeer Out** CHOP | `Multipeerout` | TD → ピア **送信** | 入力CHOPの各chを送信。出力は `connected` 1ch |

## 実測(M2)

- 擬似送信ピア(macOS)から4chパケットを送り、**In CHOP** が
  `gyro_x / gyro_y / accel_z / touch` のチャンネルを動的生成し値を受信することを確認
  (accel_z=0.98・touch=1.0 が一致)
- 受信は unreliable(低遅延)。パケットの各フィールド名がそのままチャンネル名になる

## 受信チャンネル(iOSアプリ送信時・In CHOP)

`gyro_x/y/z`(角速度)・`accel_x/y/z`(重力除去済み加速度)・`gravity_x/y/z`・
`roll/pitch/yaw`・`heading`・`touch`(0/1)・`touch_x/touch_y`(0〜1)

複数台つなぐ場合は In CHOP の **Prefix Peer Name** をオンにするとチャンネル名が
`<端末名>/gyro_x` のように分離される。

## ワイヤープロトコル(TDMP・リトルエンディアン)

```
"TDMP"(4B) | uint16 count | count×{ uint8 nameLen, name(UTF8), float32 value }
```

CHOP と iOS アプリで共通。In が受信・Out が送信する。

## パラメータ

- **In**: Active / Peer Name / Service Type(既定 `td-sensor`)/ Prefix Peer Name
- **Out**: Active / Peer Name / Service Type(既定 `td-sensor`)

## iOS サンプルアプリ(ios/TDSensor)

CoreMotion の gyro/accel/gravity/attitude/heading + タッチパッドを送信する SwiftUI アプリ。
Service Type は `td-sensor`(In CHOP の既定と一致)。ビルド手順は下記。

- Xcode で `ios/TDSensor` を開き、実機ターゲットで Run(モーションは実機のみ)
- Info.plist に3キーが必要: ローカルネットワーク使用許可 /
  Bonjour services(`_td-sensor._tcp`)/ モーション使用許可

## 注意

- **In と Out を同じ Mac に同時に置くと、ピアから見て2ピアになる**(それぞれ別セッション)。
  センサー受信だけなら In のみを置くのが最小構成
- 初回は macOS の**ローカルネットワーク許可**ダイアログが出ることがある
- opType はファミリー間で重複可(DAT と CHOP が同名 `Multipeerin`/`Multipeerout` で共存)

## ビルド

```
cd MultipeerCHOP && ./build.sh   # → build/MultipeerInCHOP.plugin, build/MultipeerOutCHOP.plugin
```
