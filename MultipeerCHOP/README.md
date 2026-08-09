# Multipeer In / Out CHOP + iPhone sensor app

**English** | [日本語](#日本語)

## English

**Turns an iPhone/iPad into a wireless sensor.** Named float channels are sent and received every
frame as low-latency (unreliable) binary over MultipeerConnectivity. This is the numeric (CHOP)
counterpart of the text-oriented [Multipeer In/Out DAT](../MultipeerDAT/). No server; peers on the
same local network connect automatically.

**Split into two operators so the direction is obvious from the name**:

| OP | opType | Role | I/O |
|---|---|---|---|
| **Multipeer In** CHOP | `Multipeerin` | peer → TD, **receive** | No input. Creates received channels dynamically |
| **Multipeer Out** CHOP | `Multipeerout` | TD → peer, **send** | Sends each channel of the input CHOP. Outputs one `connected` channel |

### Measured (M2)

- Sending a 4-channel packet from a mock peer (macOS), the **In CHOP** dynamically created
  `gyro_x / gyro_y / accel_z / touch` and received the values (accel_z = 0.98, touch = 1.0 match)
- Reception is unreliable (low latency). Each field name in the packet becomes the channel name

### Received channels (from the iOS app, In CHOP)

`gyro_x/y/z` (angular velocity), `accel_x/y/z` (gravity removed), `gravity_x/y/z`,
`roll/pitch/yaw`, `heading`, `touch` (0/1), `touch_x/touch_y` (0–1)

With several devices, turn on **Prefix Peer Name** on the In CHOP and channel names are separated
as `<device name>/gyro_x`.

### Wire protocol (TDMP, little endian)

```
"TDMP" (4B) | uint16 count | count × { uint8 nameLen, name (UTF8), float32 value }
```

Shared by the CHOP and the iOS app. In receives it, Out sends it.

### Parameters

- **In**: Active / Peer Name / Service Type (default `td-sensor`) / Prefix Peer Name
- **Out**: Active / Peer Name / Service Type (default `td-sensor`)

### iOS sample app (ios/)

A SwiftUI app that sends CoreMotion gyro/accel/gravity/attitude/heading plus a touchpad. The
service type is `td-sensor` (matching the In CHOP's default). **An Xcode project is included.**

#### Building for a device right away

1. Open `ios/TDSensor.xcodeproj` in Xcode (the simulator build is verified — BUILD SUCCEEDED)
2. TDSensor target → Signing & Capabilities, pick your own **Team** (automatic signing)
3. Select a physical iPhone/iPad and **Run** (motion sensors only work on a device)
4. Turn on "send" in the app; on the Mac set the **Multipeer In CHOP**'s Service Type to
   `td-sensor` and it connects automatically

- Bundle ID: `tokyo.sygnal.tdsensor` (change if you like) / iOS 16+ / iPhone and iPad
- The three required Info.plist keys (local network permission, Bonjour `_td-sensor._tcp` and
  `_td-sensor._udp`, motion permission) are already set

#### Regenerating the project (optional)

The source layout is managed by `ios/project.yml` (XcodeGen). To rebuild the `.xcodeproj`:

```
brew install xcodegen        # if you don't have it
cd MultipeerCHOP/ios && xcodegen generate
```

The generated `.xcodeproj` opens directly in Xcode, so xcodegen is normally unnecessary.

### Notes

- **Putting In and Out on the same Mac makes it look like two peers** (they are separate
  sessions). For sensor reception only, In alone is the minimal setup
- macOS may show a **local network permission** dialog the first time
- opTypes may collide across families (the DAT and CHOP coexist as `Multipeerin`/`Multipeerout`)

### Build

```
cd MultipeerCHOP && ./build.sh   # → build/MultipeerInCHOP.plugin, build/MultipeerOutCHOP.plugin
```

## 日本語

**iPhone/iPad をワイヤレスセンサーにする**。MultipeerConnectivity で名前付き float
チャンネルのバイナリを低遅延(unreliable)で毎フレーム送受信する。テキスト用
[Multipeer In/Out DAT](../MultipeerDAT/) の数値(CHOP)版。サーバー不要・同一ローカル
ネットワークで自動接続。

**送受信の向きが名前で分かるよう2オペレータに分割**:

| OP | opType | 役割 | 入出力 |
|---|---|---|---|
| **Multipeer In** CHOP | `Multipeerin` | ピア → TD **受信** | 入力なし。受信chを動的生成して出力 |
| **Multipeer Out** CHOP | `Multipeerout` | TD → ピア **送信** | 入力CHOPの各chを送信。出力は `connected` 1ch |

### 実測(M2)

- 擬似送信ピア(macOS)から4chパケットを送り、**In CHOP** が
  `gyro_x / gyro_y / accel_z / touch` のチャンネルを動的生成し値を受信することを確認
  (accel_z=0.98・touch=1.0 が一致)
- 受信は unreliable(低遅延)。パケットの各フィールド名がそのままチャンネル名になる

### 受信チャンネル(iOSアプリ送信時・In CHOP)

`gyro_x/y/z`(角速度)・`accel_x/y/z`(重力除去済み加速度)・`gravity_x/y/z`・
`roll/pitch/yaw`・`heading`・`touch`(0/1)・`touch_x/touch_y`(0〜1)

複数台つなぐ場合は In CHOP の **Prefix Peer Name** をオンにするとチャンネル名が
`<端末名>/gyro_x` のように分離される。

### ワイヤープロトコル(TDMP・リトルエンディアン)

```
"TDMP"(4B) | uint16 count | count×{ uint8 nameLen, name(UTF8), float32 value }
```

CHOP と iOS アプリで共通。In が受信・Out が送信する。

### パラメータ

- **In**: Active / Peer Name / Service Type(既定 `td-sensor`)/ Prefix Peer Name
- **Out**: Active / Peer Name / Service Type(既定 `td-sensor`)

### iOS サンプルアプリ(ios/)

CoreMotion の gyro/accel/gravity/attitude/heading + タッチパッドを送信する SwiftUI アプリ。
Service Type は `td-sensor`(In CHOP の既定と一致)。**Xcode プロジェクト同梱**。

#### すぐ実機ビルドする

1. `ios/TDSensor.xcodeproj` を Xcode で開く(シミュレータビルドは検証済み・BUILD SUCCEEDED)
2. TDSensor ターゲット → Signing & Capabilities で自分の **Team** を選ぶ(自動署名)
3. iPhone/iPad 実機を選んで **Run**(モーションセンサーは実機のみ動作)
4. アプリで「送信 On」→ Mac 側で **Multipeer In CHOP** の Service Type を `td-sensor` にすれば自動接続

- Bundle ID: `tokyo.sygnal.tdsensor`(必要に応じて変更可)/ iOS 16+ / iPhone・iPad
- Info.plist に必要3キー(ローカルネットワーク許可 / Bonjour `_td-sensor._tcp`・`_td-sensor._udp` /
  モーション許可)は設定済み

#### プロジェクトの再生成(任意)

ソース構成は `ios/project.yml`(XcodeGen)で管理。`.xcodeproj` を作り直す場合:

```
brew install xcodegen        # 未導入なら
cd MultipeerCHOP/ios && xcodegen generate
```

生成済み `.xcodeproj` は Xcode で直接開けるので、通常 xcodegen は不要。

### 注意

- **In と Out を同じ Mac に同時に置くと、ピアから見て2ピアになる**(それぞれ別セッション)。
  センサー受信だけなら In のみを置くのが最小構成
- 初回は macOS の**ローカルネットワーク許可**ダイアログが出ることがある
- opType はファミリー間で重複可(DAT と CHOP が同名 `Multipeerin`/`Multipeerout` で共存)

### ビルド

```
cd MultipeerCHOP && ./build.sh   # → build/MultipeerInCHOP.plugin, build/MultipeerOutCHOP.plugin
```
