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

## 出力(テーブル)

| 列 | 内容 |
|---|---|
| service_type | Bonjour サービスタイプ(`_osc._udp.` など。ARP由来行は空) |
| name | サービスのインスタンス名 |
| hostname | ホスト名(Bonjour解決 or 逆引きDNS/mDNS。`.local`) |
| ip4 / ip6 | IPアドレス |
| mac | MACアドレス(Active Scan由来) |
| port | ポート番号(Bonjour由来) |
| txt | TXTレコード(`key=value; ...`) |
| source | `bonjour` / `arp` / `bonjour+arp` |

行は ip4 昇順にソート。Info CHOP: `executes / services / scan_hosts / rows / scanning`

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
- MACベンダー(OUI)名の解決は未対応(MACの先頭3オクテットで判別可能・将来候補)

## ビルド

```
cd NetworkDiscovery && ./build.sh   # → build/NetworkDiscoveryDAT.plugin
```
