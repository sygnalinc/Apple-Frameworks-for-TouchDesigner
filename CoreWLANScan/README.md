# CoreWLAN Scan CHOP

周辺のWi-Fiをスキャンし、**チャンネル別の混雑度・AP数・最大RSSI**を数値CHOPで出す。
「電波が混んでいる/空いているチャンネルはどこか」を可視化する**電波環境ツール**。
チャンネル選定(空き帯域探し)・展示会場の電波混雑モニタ・混雑度をリアクティブ入力に、等。

`CWInterface.scanForNetworks` を使う。**SSID名/BSSIDは macOS 14+ のprivacyで伏せられ取得不可**
(→ [CoreWLAN](../CoreWLAN/) の README 参照)。**ネットワーク名は出ないが**、各APの
RSSI・帯域(2.4/5GHz)・チャンネル幅は取れるので、混雑分析には十分。

## 混雑度モデル

各APの占有帯域(中心周波数 ± チャンネル幅/2)を、各20MHzチャンネル枠との**重なり割合で按分**し、
線形強度 `10^(rssi/10)` を加算する。**40/80MHz幅のAPが隣接chへ与える干渉も反映**される。
各バンドで最大値=1に正規化(`congestion` は 0〜1)。`best_ch` = そのバンドで最も混雑度が低いch。

## 出力(CHOP・126ch)

| チャンネル | 内容 |
|---|---|
| `scans` / `scanning` / `networks` | スキャン回数 / スキャン中 / 検出総数 |
| `networks_24` / `networks_5` | 2.4GHz / 5GHz の検出数 |
| `ch{n}_24/aps` `.../rssi` `.../congestion` | 2.4GHz 各ch(1〜14)のAP数 / 最大RSSI / 混雑度(0〜1) |
| `ch{n}_5/aps` `.../rssi` `.../congestion` | 5GHz 各ch(36〜165)のAP数 / 最大RSSI / 混雑度 |
| `best_ch_24` / `best_congestion_24` | 2.4GHzで最も空いてるch / その混雑度 |
| `best_ch_5` / `best_congestion_5` | 5GHzで最も空いてるch / その混雑度 |

Info CHOP: `executes / scans / networks`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Scan Interval (s) | 自動スキャン間隔(既定10s。0=手動のみ) |
| Rescan Now | 今すぐスキャン(パルス) |

## 実測(M2・macOS 26.5.1)

自宅環境で6ネットワーク検出(2.4GHz×4・5GHz×2)。**ch10 に 40MHz幅の強AP(-44dBm)**があり、
その干渉が ch8〜12 に広がる様子(混雑度グラデーション)を確認。**best 2.4GHz = ch1・best 5GHz = ch36**
(最も空いているch)を正しく提示。エラー・警告なし。

## 注意

- **scanForNetworks はブロックする(数秒)**ため**ワーカースレッドで実行**し、cook は最新の集計
  スナップショットを読むだけ(非ブロック)。アクティブスキャンは接続を一瞬乱すので Scan Interval は
  短くしすぎない(既定10s)
- **SSID名は取れない**(macOS privacy)。名前が要るなら手動確認するしかない
- スキャンは接続中のインターフェース(en0等)で行う。Wi-Fiオフ時は networks=0 で Warning
- 5GHzのDFSチャンネル等、環境・地域・ドライバによって検出されるchは変わる

## ビルド

```
cd CoreWLANScan && ./build.sh   # → build/CoreWLANScanCHOP.plugin
```
