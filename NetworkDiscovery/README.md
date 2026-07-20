# Network Discovery DAT

**Bonjour(NSNetServiceBrowser)でLAN内のサービスを発見**し、
`service_type / name / hostname / ip4 / ip6 / port / txt` をテーブル出力する。
会場機器の一覧化・OSC/HTTP機器の自動発見・ネットワーク状態連動の演出に。

## 何ができる

- `Service Types` に列挙したタイプを**同時にブラウズ**(例 `_ssh._tcp, _http._tcp,
  _osc._udp, _airplay._tcp`)
- 見つかったサービスを **resolve** して hostname / IPv4 / IPv6 / port / TXT を取得
- サービスの出現・消滅に追従(ライブ更新)

## 出力(テーブル)

| 列 | 内容 |
|---|---|
| service_type | Bonjour サービスタイプ(`_osc._udp.` など) |
| name | サービスのインスタンス名 |
| hostname | 解決したホスト名(`.local`) |
| ip4 / ip6 | 解決したIPアドレス |
| port | ポート番号 |
| txt | TXTレコード(`key=value; ...`) |

Info CHOP: `executes / services / resolved`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Active | ブラウズ On/Off |
| Service Types | 監視するサービスタイプ(カンマ/空白区切り) |
| Domain | 検索ドメイン(既定 `local.`) |
| Resolve Timeout (s) | resolve のタイムアウト |
| Restart | ブラウズをやり直す(パルス) |

## 注意

- **Bonjour は「サービスを広告している機器」だけが見える**(全端末一覧ではない)。
  広告していないカメラ/IoT/Windows/スリープ中の端末・別VLANの機器は見えない
- macOS の**ローカルネットワーク権限**が要る(責任プロセスは **TouchDesigner 本体**)。
  初回は許可ダイアログが出るまで結果0のことがある。TouchDesignerに許可を与える
- 任意の全サービスタイプ列挙(`_services._dns-sd._udp`)は multicast entitlement が要る
  場合があるため、必要なタイプを明示する方が確実
- **全IPv4スキャン(Active IPv4 Scan)は将来対応**。現状は Bonjour ブラウズのみ

## ビルド

```
cd NetworkDiscovery && ./build.sh   # → build/NetworkDiscoveryDAT.plugin
```
