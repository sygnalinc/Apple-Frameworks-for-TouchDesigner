# Network Discovery DAT

**LAN内のデバイス/サービスを発見**して `service_type / name / hostname / ip4 / ip6 /
mac / port / txt / source` をテーブル出力する。会場機器の一覧化・OSC/HTTP機器の自動発見・
ネットワーク状態連動の演出に。

**2つの発見方式をマージ**するので、Bonjourを広告しない機器も含めて**LAN上の全機器**を拾える:

- **Bonjour**(NSNetServiceBrowser): サービスを広告している機器を名前/ホスト/ポート/TXT付きで発見
- **Active IPv4 Scan**: サブネットを総当たりして ARP を発火 → ARPテーブルを読み、**応答した
  全機器を MAC付き**で列挙(逆引きDNS/mDNSでホスト名も)。カメラ/IoT/Windows等の
  Bonjour非対応機器もこれで見える

## Mode

| Mode | 内容 |
|---|---|
| Bonjour services | Bonjour広告のみ |
| Active IPv4 scan | ARPスキャンのみ(全機器をMAC付きで) |
| **Both**(既定) | 両方をマージ。同一IPはBonjour行にMACを補完(`source=bonjour+arp`)、ARPのみの機器は別行で追加 |

## 仕組み(Active IPv4 Scan)

サブネット内の各ホストへ小さなUDPを投げると、カーネルが送信前に **ARP解決**を行う。応答した
機器だけ ARPエントリが complete(MACあり)になる。`sysctl(NET_RT_FLAGS)` で ARPテーブルを
読めば(=`arp -an` 相当)、**ICMPや特権ソケット無しで**「LANに居る全機器」を列挙できる。
全IPv4探索の高レベル Apple API は無いためこの方式を採る。逆引きは `getnameinfo`(DNS/mDNS)。

**実測(M2)**: 自宅LAN(192.168.49.0/24)で **20機器**を検出。Bonjour広告なしの機器
(ルータ/各種端末)がMAC付きで並び、AppleTV/FireTV(.21)は複数のBonjourサービス行に同一MACが
補完され `bonjour+arp`、自Mac(.16)も `_raop` + MAC でマージ。エラー・警告なし。

## 出力(テーブル) — LanScan Pro 相当

| 列 | 内容 |
|---|---|
| ip4 | IPv4アドレス |
| mac | MACアドレス(Active Scan由来) |
| **vendor** | **MACベンダー名**(同梱 IEEE OUIデータベースから。例 `BUFFALO.INC` / `Espressif Inc.` / `Amazon Technologies Inc.` / `Hitachi ...` / `Intel Corporate`) |
| **dns_name** | **ユニキャスト逆引きDNS名**(ルータ提供のPTRなど。`.local`以外) |
| **mdns_name** | **mDNS名**(`.local`。Bonjour解決名 or 強制マルチキャスト逆引きPTR。Bonjour非広告機器も拾う) |
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

## 実測(M2・自宅LAN 192.168.49.0/24)— LanScan Pro とほぼ一致

| ip4 | vendor | dns_name | mdns_name |
|---|---|---|---|
| .1 | BUFFALO.INC | ap50c4dd2b6170 | |
| .4 | Amazon Technologies Inc. | | linux-2.local |
| .5 | Hitachi Global Life Solutions | | HITACHI.local |
| .9 | Panasonic Appliances Company | | |
| .16(自機) | (randomized) | | mrt-MacBook-Air.local |
| .23 | Intel Corporate | | |

ベンダー・mDNS名とも LanScan Pro の表示値と一致。**SMB Name/Domain(NetBIOS)は未対応**(将来候補)。

## パラメータ

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
| Restart Bonjour | Bonjourブラウズをやり直す(パルス) |

## 注意

- **アクティブスキャンは一回のスイープ**(常時スキャンはしない)。設定変更・Mode有効化・
  `Rescan Now` パルスで実行する。スキャンはワーカースレッドで行い cook をブロックしない
- macOS の**ローカルネットワーク権限**が要る(責任プロセスは **TouchDesigner 本体**)。
  初回は許可ダイアログが出るまで結果0のことがある
- **見えないもの**: ARPに応答しない機器・別サブネット/VLAN・ファイアウォール越し・
  スリープ中の端末は列挙できない。ルータのDHCPリース一覧を取るAPIは標準に無い。
  **IPv6全域スキャンはアドレス空間的に不可**
- Active Scan はサブネット全ホストへ1バイトUDPを送る(自分のLANのみ・最小限)。
  セキュリティソフトがポートスキャンとみなす場合がある
- **SMB Name / SMB Domain(NetBIOS 137/445)は未対応**(LanScan Proにはあるが本OPは未実装・将来候補)
- 逆引き(DNS + mDNS)は1台あたり最大 ~1秒。ARP応答機器が多いとスキャン全体が数十秒かかることがある
  (件数分だけワーカースレッドで直列実行・cook は非ブロック)
- 同一機器が複数のBonjourサービスを広告している場合、サービスごとに行が出る(service_type/name で区別)

## OUIデータベースの更新

`oui.txt` は IEEE 公式から生成する(`tools/gen_oui.py`):

```
curl -sSo /tmp/oui.csv   https://standards-oui.ieee.org/oui/oui.csv
curl -sSo /tmp/mam.csv   https://standards-oui.ieee.org/oui28/mam.csv
curl -sSo /tmp/oui36.csv https://standards-oui.ieee.org/oui36/oui36.csv
python3 tools/gen_oui.py /tmp/oui.csv /tmp/mam.csv /tmp/oui36.csv NetworkDiscovery/oui.txt
```

## ビルド

```
cd NetworkDiscovery && ./build.sh   # → build/NetworkDiscoveryDAT.plugin(oui.txt を Resources に同梱)
```
