# Multipeer In / Out DAT

**English** | [日本語](#日本語)

## English

**Local peer-to-peer text messaging between Macs, iPhones and iPads** (MultipeerConnectivity).
Peers advertising the same Service Type discover and connect to each other automatically. No
server; Wi-Fi / wired / Bluetooth are chosen automatically. The numeric (sensor) counterpart is
[Multipeer In/Out CHOP](../MultipeerCHOP/).

**Split into two operators so the direction is obvious from the name**:

| OP | opType | Role | I/O |
|---|---|---|---|
| **Multipeer In** DAT | `Multipeerin` | Receive | No input. A `type/peer/message` table (connected peers + received history) |
| **Multipeer Out** DAT | `Multipeerout` | Send | Sends the input DAT as TSV. Outputs `status/peers/sends` diagnostics |

### Measured (M2)

- On one machine, **Out (td-mac-out) → In (td-mac)** connected automatically and the contents of
  Out's input DAT arrived in In's table (following the two-node send/receive test of the older
  bidirectional version)

### Usage

- Receiving: place a **Multipeer In DAT** and connected peers plus received messages appear in the
  table
- Sending: connect the DAT you want to send to a **Multipeer Out DAT**'s input. Auto Send sends on
  every content change, or pulse Send manually
- For two-way traffic, put both In and Out on each machine (they are separate sessions)
- On iOS: any small app or Playground using MultipeerConnectivity with the same serviceType will
  connect

### Parameters

- **In**: Active / Peer Name / Service Type (1–15 chars, lowercase letters, digits and hyphens) /
  Max Messages
- **Out**: Active / Peer Name / Service Type / Auto Send On Change / Send

### Notes

- macOS may show a **local network permission** dialog the first time
- Invitations go one way only, decided by lexical order of the display names (to prevent double
  connections). Avoid identically named peers
- opTypes may collide across families (the CHOP and DAT coexist as `Multipeerin`/`Multipeerout`)

### Build

```
cd MultipeerDAT && ./build.sh   # → build/MultipeerInDAT.plugin, build/MultipeerOutDAT.plugin
```

## 日本語

**Mac/iPhone/iPad 間のローカルP2Pテキストメッセージング**(MultipeerConnectivity)。
同じ Service Type のピアを自動発見・自動接続する。サーバー不要・Wi-Fi/有線/Bluetooth
自動選択。数値(センサー)版は [Multipeer In/Out CHOP](../MultipeerCHOP/)。

**送受信の向きが名前で分かるよう2オペレータに分割**:

| OP | opType | 役割 | 入出力 |
|---|---|---|---|
| **Multipeer In** DAT | `Multipeerin` | 受信 | 入力なし。`type/peer/message` テーブル(接続ピア+受信履歴) |
| **Multipeer Out** DAT | `Multipeerout` | 送信 | 入力DATをTSV化して送信。出力は `status/peers/sends` の診断 |

### 実測(M2)

- 同一マシン上で **Out(td-mac-out)→ In(td-mac)** が自動接続し、Out の入力DAT内容が
  In 側のテーブルに届くことを確認(旧・双方向版の 2 ノード送受信テストを踏襲)

### 使い方

- 受信: **Multipeer In DAT** を置くと、接続ピアと受信メッセージがテーブルに出る
- 送信: **Multipeer Out DAT** の入力に送りたいDATを接続。Auto Send で内容変化時に自動送信、
  または Send パルスで手動送信
- 双方向にやり取りしたい場合は各マシンに In と Out を両方置く(別セッションになる)
- iOS側: MultipeerConnectivity で同じ serviceType を名乗る簡単なアプリ/Playground で繋がる

### パラメータ

- **In**: Active / Peer Name / Service Type(1〜15文字・英小文字数字とハイフン)/ Max Messages
- **Out**: Active / Peer Name / Service Type / Auto Send On Change / Send

### 注意

- 初回は macOS の**ローカルネットワーク許可**ダイアログが出ることがある
- 表示名の辞書順で片方向のみ招待する(二重接続防止)。同名ピアは避ける
- opType はファミリー間で重複可(CHOP と DAT が同名 `Multipeerin`/`Multipeerout` で共存)

### ビルド

```
cd MultipeerDAT && ./build.sh   # → build/MultipeerInDAT.plugin, build/MultipeerOutDAT.plugin
```
