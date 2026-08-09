# Network Discovery DAT

**English** | [日本語](#日本語)

## English

**Discovers devices and services on the LAN** and outputs
`service_type / name / hostname / ip4 / ip6 / mac / port / txt / source` as a table. Useful for
inventorying venue equipment, auto-discovering OSC/HTTP devices, or driving a show from network
state.

It **merges two discovery methods**, so it picks up **everything on the LAN**, including devices
that advertise no Bonjour service:

- **Bonjour** (NSNetServiceBrowser): finds devices advertising services, with name / host / port /
  TXT
- **Active IPv4 Scan**: sweeps the subnet to trigger ARP, then reads the ARP table and lists
  **every device that answered, with its MAC** (plus hostnames from reverse DNS/mDNS). This is how
  cameras, IoT gear, Windows machines and other non-Bonjour devices show up

### Mode

| Mode | Description |
|---|---|
| Bonjour services | Bonjour advertisements only |
| Active IPv4 scan | ARP scan only (every device, with MAC) |
| **Both** (default) | Merges the two. The same IP gets its MAC filled into the Bonjour row (`source=bonjour+arp`); ARP-only devices are added as their own rows |

### How the Active IPv4 Scan works

Sending a small UDP packet to each host in the subnet makes the kernel perform **ARP resolution**
first. Only devices that answer end up with a complete ARP entry (one that has a MAC). Reading the
ARP table with `sysctl(NET_RT_FLAGS)` (the equivalent of `arp -an`) then enumerates
"everyone on the LAN" **without ICMP or a privileged socket**. There is no high-level Apple API
for scanning all of IPv4, hence this approach. Reverse lookup uses `getnameinfo` (DNS/mDNS).

**Measured (M2)**: **20 devices** found on a home LAN (192.168.49.0/24). Devices with no Bonjour
advertisement (the router, various endpoints) are listed with MACs; the AppleTV/FireTV (.21) has
the same MAC filled into several Bonjour service rows as `bonjour+arp`; this Mac (.16) merges
`_raop` with its MAC. No errors or warnings.

### Output table — comparable to LanScan Pro

| Column | Description |
|---|---|
| ip4 | IPv4 address |
| mac | MAC address (from the Active Scan) |
| **vendor** | **MAC vendor name** (from the bundled IEEE OUI database — e.g. `BUFFALO.INC` / `Espressif Inc.` / `Amazon Technologies Inc.` / `Hitachi ...` / `Intel Corporate`) |
| **dns_name** | **Unicast reverse-DNS name** (a PTR from the router etc.; anything not `.local`) |
| **mdns_name** | **mDNS name** (`.local` — either the Bonjour resolved name or a forced multicast reverse PTR, so non-advertising devices are covered too) |
| **smb_name** | **NetBIOS/SMB computer name** (Windows/NAS/Samba; unique 0x00) |
| **smb_domain** | **NetBIOS workgroup / domain name** (group 0x00) |
| service_type | Bonjour service type (`_osc._udp.` etc.; empty on ARP-only rows) |
| name | Bonjour service instance name |
| ip6 | IPv6 address (when Bonjour resolves it) |
| port | Port number (from Bonjour) |
| txt | TXT record (`key=value; ...`) |
| source | `bonjour` / `arp` / `self` (this machine) / combinations such as `bonjour+arp+self` |

**MAC vendor (OUI)**: the leading 24/28/36 bits are looked up with longest match. Randomised MACs
(locally administered) are not registered and come back blank (e.g. this machine's
`06:de:d4:...`). The data is `oui.txt` (IEEE MA-L/MA-M/MA-S, about 53000 entries) bundled in the
plugin's `Contents/Resources/`.

**DNS name and mDNS name are separate**: like LanScan Pro, the unicast reverse lookup
(`dns_name`) and the mDNS lookup (`mdns_name`) get their own columns. Routers land in `dns_name`;
Apple / Android / Linux `.local` devices land in `mdns_name`.

**This Mac's own IP/MAC/name is always output regardless of Mode** (with `self` in `source`). If
the same IP also appears via Bonjour or ARP the rows are merged (e.g. `bonjour+arp+self`). With
several `en*` interfaces, each IP is listed.

Rows are sorted by ascending ip4. Info CHOP:
`executes / services / scan_hosts / rows / scanning`

### Measured (M2, home LAN 192.168.49.0/24) — matches LanScan Pro closely

| ip4 | vendor | dns_name | mdns_name |
|---|---|---|---|
| .1 | BUFFALO.INC | ap50c4dd2b6170 | |
| .4 | Amazon Technologies Inc. | | linux-2.local |
| .5 | Hitachi Global Life Solutions | | HITACHI.local |
| .9 | Panasonic Appliances Company | | |
| .16 (this Mac) | (randomized) | | mrt-MacBook-Air.local |
| .23 | Intel Corporate | | |

Vendors and mDNS names both match what LanScan Pro shows.

**SMB name / domain (NetBIOS)**: a NetBIOS Name Service (UDP 137) Node Status (NBSTAT) query
retrieves the computer name and workgroup of Windows / NAS / Samba machines. **The implementation
was verified end to end with a mock responder**, including parsing (`smb_name=NAS-SERVER /
smb_domain=HOME`). Modern devices usually have NetBIOS disabled, so if nothing on the LAN answers
these columns stay empty (macOS's own netbiosd is off by default).

### Parameters

| Parameter | Description |
|---|---|
| Mode | Bonjour / Active IPv4 scan / Both |
| Rescan Now | Re-run the active scan immediately (pulse) |
| Service Types | Bonjour types to browse (comma or space separated) |
| Domain | Search domain (default `local.`) |
| Resolve Timeout (s) | Bonjour resolve timeout |
| Subnet (blank = auto) | CIDR to scan (blank = this machine's `en*` subnet) |
| Scan Timeout (s) | How long to wait for ARP to complete (default 2 s) |
| Max Hosts | Sweep cap (keeps a large subnet from running away; default 1024) |
| Reverse DNS / mDNS | Resolve hostnames (default On; slow with many hosts) |
| NetBIOS / SMB Name | Get the SMB name/domain over NetBIOS (UDP 137). Default On; up to 0.6 s per host |
| Restart Bonjour | Restart the Bonjour browse (pulse) |

### Notes

- **The active scan is a single sweep** (it does not scan continuously). It runs on a settings
  change, when the mode is enabled, or on a `Rescan Now` pulse. The scan is on a worker thread and
  never blocks cook
- macOS **local network permission** is required (the responsible process is **TouchDesigner
  itself**). The first run may return nothing until the permission dialog is answered
- **What you will not see**: devices that do not answer ARP, other subnets/VLANs, anything behind
  a firewall, and sleeping devices. There is no standard API for a router's DHCP lease list.
  **Scanning all of IPv6 is impossible** given the address space
- The active scan sends a one-byte UDP packet to every host in the subnet (your own LAN only,
  minimal). Some security software may treat this as a port scan
- Reverse lookup (DNS + mDNS) plus NetBIOS costs up to ~1.6 s per host, so with many ARP
  responders the whole scan can take tens of seconds (done serially on a worker thread; cook never
  blocks). Turning off the `Reverse DNS` / `NetBIOS` toggles speeds it up
- A device advertising several Bonjour services gets one row per service (distinguished by
  service_type / name)

### Updating the OUI database

`oui.txt` is generated from IEEE's official data (`tools/gen_oui.py`):

```
curl -sSo /tmp/oui.csv   https://standards-oui.ieee.org/oui/oui.csv
curl -sSo /tmp/mam.csv   https://standards-oui.ieee.org/oui28/mam.csv
curl -sSo /tmp/oui36.csv https://standards-oui.ieee.org/oui36/oui36.csv
python3 tools/gen_oui.py /tmp/oui.csv /tmp/mam.csv /tmp/oui36.csv NetworkDiscovery/oui.txt
```

### Build

```
cd NetworkDiscovery && ./build.sh   # → build/NetworkDiscoveryDAT.plugin (bundles oui.txt in Resources)
```

## 日本語

**LAN内のデバイス/サービスを発見**して `service_type / name / hostname / ip4 / ip6 /
mac / port / txt / source` をテーブル出力する。会場機器の一覧化・OSC/HTTP機器の自動発見・
ネットワーク状態連動の演出に。

**2つの発見方式をマージ**するので、Bonjourを広告しない機器も含めて**LAN上の全機器**を拾える:

- **Bonjour**(NSNetServiceBrowser): サービスを広告している機器を名前/ホスト/ポート/TXT付きで発見
- **Active IPv4 Scan**: サブネットを総当たりして ARP を発火 → ARPテーブルを読み、**応答した
  全機器を MAC付き**で列挙(逆引きDNS/mDNSでホスト名も)。カメラ/IoT/Windows等の
  Bonjour非対応機器もこれで見える

### Mode

| Mode | 内容 |
|---|---|
| Bonjour services | Bonjour広告のみ |
| Active IPv4 scan | ARPスキャンのみ(全機器をMAC付きで) |
| **Both**(既定) | 両方をマージ。同一IPはBonjour行にMACを補完(`source=bonjour+arp`)、ARPのみの機器は別行で追加 |

### 仕組み(Active IPv4 Scan)

サブネット内の各ホストへ小さなUDPを投げると、カーネルが送信前に **ARP解決**を行う。応答した
機器だけ ARPエントリが complete(MACあり)になる。`sysctl(NET_RT_FLAGS)` で ARPテーブルを
読めば(=`arp -an` 相当)、**ICMPや特権ソケット無しで**「LANに居る全機器」を列挙できる。
全IPv4探索の高レベル Apple API は無いためこの方式を採る。逆引きは `getnameinfo`(DNS/mDNS)。

**実測(M2)**: 自宅LAN(192.168.49.0/24)で **20機器**を検出。Bonjour広告なしの機器
(ルータ/各種端末)がMAC付きで並び、AppleTV/FireTV(.21)は複数のBonjourサービス行に同一MACが
補完され `bonjour+arp`、自Mac(.16)も `_raop` + MAC でマージ。エラー・警告なし。

### 出力(テーブル) — LanScan Pro 相当

| 列 | 内容 |
|---|---|
| ip4 | IPv4アドレス |
| mac | MACアドレス(Active Scan由来) |
| **vendor** | **MACベンダー名**(同梱 IEEE OUIデータベースから。例 `BUFFALO.INC` / `Espressif Inc.` / `Amazon Technologies Inc.` / `Hitachi ...` / `Intel Corporate`) |
| **dns_name** | **ユニキャスト逆引きDNS名**(ルータ提供のPTRなど。`.local`以外) |
| **mdns_name** | **mDNS名**(`.local`。Bonjour解決名 or 強制マルチキャスト逆引きPTR。Bonjour非広告機器も拾う) |
| **smb_name** | **NetBIOS/SMBコンピュータ名**(Windows/NAS/Samba。unique 0x00) |
| **smb_domain** | **NetBIOSワークグループ/ドメイン名**(group 0x00) |
| service_type | Bonjour サービスタイプ(`_osc._udp.` など。ARP由来行は空) |
| name | Bonjour サービスのインスタンス名 |
| ip6 | IPv6アドレス(Bonjour解決時) |
| port | ポート番号(Bonjour由来) |
| txt | TXTレコード(`key=value; ...`) |
| source | `bonjour` / `arp` / `self`(自機)/ 組合せ `bonjour+arp+self` など |

**MACベンダー(OUI)**: MAC先頭 24/28/36bit を longest-match で引く。ランダム化MAC(ローカル
アドミニスタード)は登録が無いので空欄になる(例 自機の `06:de:d4:...`)。データは
`oui.txt`(IEEE MA-L/MA-M/MA-S 約53000件)をプラグインの `Contents/Resources/` に同梱。

**DNS名 と mDNS名を分離**: LanScan Pro と同様に、ユニキャスト逆引き(`dns_name`)と
mDNS逆引き(`mdns_name`)を別列で出す。ルータは `dns_name`、Apple/Android/Linux等の `.local`
機器は `mdns_name` に入る。

**自機(このMac)の IP/MAC/名前は Mode に関わらず必ず出す**(`source` に `self`)。同一IPが
Bonjour/ARPでも出ていれば統合される(例 `bonjour+arp+self`)。複数の en* を持つ場合は各IPを出す。

行は ip4 昇順にソート。Info CHOP: `executes / services / scan_hosts / rows / scanning`

### 実測(M2・自宅LAN 192.168.49.0/24)— LanScan Pro とほぼ一致

| ip4 | vendor | dns_name | mdns_name |
|---|---|---|---|
| .1 | BUFFALO.INC | ap50c4dd2b6170 | |
| .4 | Amazon Technologies Inc. | | linux-2.local |
| .5 | Hitachi Global Life Solutions | | HITACHI.local |
| .9 | Panasonic Appliances Company | | |
| .16(自機) | (randomized) | | mrt-MacBook-Air.local |
| .23 | Intel Corporate | | |

ベンダー・mDNS名とも LanScan Pro の表示値と一致。

**SMB名/ドメイン(NetBIOS)**: NetBIOS Name Service(UDP 137)の Node Status(NBSTAT)クエリで
Windows/NAS/Samba のコンピュータ名・ワークグループを取得する。**実装は疑似レスポンダで
フル送受信+パース検証済み**(`smb_name=NAS-SERVER / smb_domain=HOME`)。現代の機器は NetBIOS を
無効にしていることが多く、応答機器がLAN上に無いと空欄になる(macOS の netbiosd も既定オフ)。

### パラメータ

| パラメータ | 説明 |
|---|---|
| Mode | Bonjour / Active IPv4 scan / Both |
| Rescan Now | アクティブスキャンを今すぐ再実行(パルス) |
| Service Types | 監視する Bonjour タイプ(カンマ/空白区切り) |
| Domain | 検索ドメイン(既定 `local.`) |
| Resolve Timeout (s) | Bonjour resolve のタイムアウト |
| Subnet (blank = auto) | スキャン対象 CIDR(空欄で自機の en* サブネットを自動) |
| Scan Timeout (s) | ARP完了を待つ時間(既定2s) |
| Max Hosts | スイープ上限(大きなサブネットの暴走防止・既定1024) |
| Reverse DNS / mDNS | 逆引きでホスト名を取得(既定On。件数が多いと遅くなる) |
| NetBIOS / SMB Name | NetBIOS(UDP 137)で SMB名/ドメインを取得(既定On。1台あたり最大0.6s) |
| Restart Bonjour | Bonjourブラウズをやり直す(パルス) |

### 注意

- **アクティブスキャンは一回のスイープ**(常時スキャンはしない)。設定変更・Mode有効化・
  `Rescan Now` パルスで実行する。スキャンはワーカースレッドで行い cook をブロックしない
- macOS の**ローカルネットワーク権限**が要る(責任プロセスは **TouchDesigner 本体**)。
  初回は許可ダイアログが出るまで結果0のことがある
- **見えないもの**: ARPに応答しない機器・別サブネット/VLAN・ファイアウォール越し・
  スリープ中の端末は列挙できない。ルータのDHCPリース一覧を取るAPIは標準に無い。
  **IPv6全域スキャンはアドレス空間的に不可**
- Active Scan はサブネット全ホストへ1バイトUDPを送る(自分のLANのみ・最小限)。
  セキュリティソフトがポートスキャンとみなす場合がある
- 逆引き(DNS + mDNS)+ NetBIOS は1台あたり最大 ~1.6秒。ARP応答機器が多いとスキャン全体が
  数十秒かかることがある(件数分だけワーカースレッドで直列実行・cook は非ブロック)。
  不要なら `Reverse DNS` / `NetBIOS` トグルを Off にすると速くなる
- 同一機器が複数のBonjourサービスを広告している場合、サービスごとに行が出る(service_type/name で区別)

### OUIデータベースの更新

`oui.txt` は IEEE 公式から生成する(`tools/gen_oui.py`):

```
curl -sSo /tmp/oui.csv   https://standards-oui.ieee.org/oui/oui.csv
curl -sSo /tmp/mam.csv   https://standards-oui.ieee.org/oui28/mam.csv
curl -sSo /tmp/oui36.csv https://standards-oui.ieee.org/oui36/oui36.csv
python3 tools/gen_oui.py /tmp/oui.csv /tmp/mam.csv /tmp/oui36.csv NetworkDiscovery/oui.txt
```

### ビルド

```
cd NetworkDiscovery && ./build.sh   # → build/NetworkDiscoveryDAT.plugin(oui.txt を Resources に同梱)
```
