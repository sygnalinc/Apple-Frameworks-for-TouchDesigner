# CoreWLAN CHOP

CoreWLAN で現在接続中の Wi-Fi インターフェースの **RSSI / ノイズ / SNR / 送信レート / チャンネル /
送信電力 / PHYモード** を数値CHOPとして出力する。SSID/BSSID/インターフェース名/セキュリティは Info DAT。

## 実測(M2)

- 実接続で rssi=-41 / noise=-93 / snr=52 / tx_rate=400Mbps / channel=120 / phy_mode=5 を取得

## 出力(CHOP)

`connected / rssi / noise / snr / tx_rate_mbps / tx_power / channel / channel_band / phy_mode`(1sample)。
Info DAT: `ssid / bssid / interface / security`

## 注意

- **最近のmacOSでは SSID/BSSID の取得に Location 権限(TCC)が要る**。権限が無いと ssid は空になるが
  rssi/noise/channel 等の数値は取れる。`connected` はチャンネル関連付け(または rssi≠0)で判定する
- 未接続時は Warning。値はポーリング(cook 毎)

## ビルド
```
cd WiFiMonitor && ./build.sh
```
