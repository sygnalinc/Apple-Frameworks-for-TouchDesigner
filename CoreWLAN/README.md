# CoreWLAN CHOP

CoreWLAN で現在接続中の Wi-Fi インターフェースの **RSSI / ノイズ / SNR / 送信レート / チャンネル /
送信電力 / PHYモード** を数値CHOPとして出力する。SSID/BSSID/インターフェース名/セキュリティは Info DAT。

## 実測(M2)

- 実接続で rssi=-41 / noise=-93 / snr=52 / tx_rate=400Mbps / channel=120 / phy_mode=5 を取得

## 出力(CHOP)

`connected / rssi / noise / snr / tx_rate_mbps / tx_power / channel / channel_band / phy_mode`(1sample)。
Info DAT: `ssid / bssid / interface / security`

## 注意

- **SSID/BSSID は macOS 14+ で取得困難(TDプラグインからは実質不可)**。数値(rssi/noise/channel/
  txRate/PHY)は無条件で取れる。`connected` はチャンネル関連付け(または rssi≠0)で判定する
- 未接続時は Warning。値はポーリング(cook 毎)

### SSID が取れない理由(macOS 26.5.1 で実測検証済み)

「Location 権限を組み込めば取れる」と考え、CoreLocation の許可リクエストを実装して段階的に検証したが、
**この方法では取得できない**ことが判明した:

| 条件 | 結果 |
|---|---|
| 裸のCLI(Info.plist に用途文字列なし) | 許可プロンプトすら出ず notDetermined 固定 → ssid=nil |
| 正しい .app + `NSLocationWhenInUseUsageDescription` | authorizedAlways を取得 → **それでも ssid=nil** |
| + 実際の位置フィックス取得(実座標が返る) | **ssid=nil** |
| + フル精度認可(`requestTemporaryFullAccuracyAuthorization`) | **ssid=nil** |

`ipconfig getsummary en0` も `SSID : <redacted>`、`system_profiler SPAirPortDataType` も `<redacted>`
で、**システムレベルで伏せられている**。macOS 26 は SSID アクセスを Location 権限＋正規署名(ad-hoc不可)
の両方でゲートしており、教科書通りの完全条件でも第三者アプリからは返らない。

TDプラグインには**さらに決定的な壁**がある: 責任プロセスの **TouchDesigner.app の Info.plist に
`NSLocation*` 用途文字列が無い**ため、プラグインから `requestWhenInUseAuthorization()` を呼んでも
**サイレントに無反応**(プロンプトが出ない)。`.plugin` 単体では Info.plist キーを足せず、TD.app の
plist を改変すると Derivative の署名が壊れる。よって**位置情報リクエストの組み込みは行わない**
(常に nil を返す動かないトグルになるため)。SSID が要る場合はユーザーが手動で確認するしかない。

## ビルド
```
cd WiFiMonitor && ./build.sh
```
