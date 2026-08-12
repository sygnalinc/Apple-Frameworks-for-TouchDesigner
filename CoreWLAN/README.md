# CoreWLAN CHOP

**English** | [日本語](#日本語)

## English

Outputs the **RSSI / noise / SNR / transmit rate / channel / transmit power / PHY mode** of the
currently connected Wi-Fi interface as numeric CHOP channels, via CoreWLAN. SSID, BSSID,
interface name and security go into the Info DAT.

### Measured (M2)

- On a live connection: rssi = -41, noise = -93, snr = 52, tx_rate = 400 Mbps, channel = 120,
  phy_mode = 5

### Output (CHOP)

`connected / rssi / noise / snr / tx_rate_mbps / tx_power / channel / channel_band / phy_mode`
(1 sample). Info DAT: `ssid / bssid / interface / security`

### Notes

- **SSID/BSSID are hard to obtain on macOS 14+ (effectively impossible from a TD plugin).** The
  numbers (rssi, noise, channel, txRate, PHY) are always available. `connected` is decided from
  the channel association (or rssi ≠ 0)
- A warning is raised when not connected. Values are polled every cook
- If you need SSID names, see [CoreWLAN Scan](../CoreWLANScan/) — it ships a small helper `.app`
  with its own location-usage strings and can list surrounding SSIDs

### Why the SSID is unavailable (verified on macOS 26.5.1)

The obvious idea — "add a Location permission request and it will work" — was implemented and
tested step by step. **It does not work**:

| Condition | Result |
|---|---|
| Bare CLI (no usage string in Info.plist) | No permission prompt at all, stuck at notDetermined → ssid = nil |
| Proper `.app` + `NSLocationWhenInUseUsageDescription` | authorizedAlways granted → **still ssid = nil** |
| + an actual location fix (real coordinates returned) | **ssid = nil** |
| + full-accuracy authorisation (`requestTemporaryFullAccuracyAuthorization`) | **ssid = nil** |

`ipconfig getsummary en0` also reports `SSID : <redacted>` and `system_profiler SPAirPortDataType`
shows `<redacted>` — **it is hidden at the system level**. macOS 26 gates SSID access behind both
Location permission and proper (non ad-hoc) signing, and even with every textbook condition met
it is not returned to a third-party app.

There is **one more decisive obstacle** for a TD plugin: the responsible process,
TouchDesigner.app, **has no `NSLocation*` usage string in its Info.plist**, so calling
`requestWhenInUseAuthorization()` from a plugin does **nothing at all** (no prompt appears). A
`.plugin` cannot add Info.plist keys of its own, and editing TD.app's plist breaks Derivative's
signature. So the location request is deliberately **not** implemented here (it would be a dead
toggle that always returns nil).

### Build

```
cd CoreWLAN && ./build.sh
```

## 日本語

CoreWLAN で現在接続中の Wi-Fi インターフェースの **RSSI / ノイズ / SNR / 送信レート / チャンネル /
送信電力 / PHYモード** を数値CHOPとして出力する。SSID/BSSID/インターフェース名/セキュリティは Info DAT。

### 実測(M2)

- 実接続で rssi=-41 / noise=-93 / snr=52 / tx_rate=400Mbps / channel=120 / phy_mode=5 を取得

### 出力(CHOP)

`connected / rssi / noise / snr / tx_rate_mbps / tx_power / channel / channel_band / phy_mode`(1sample)。
Info DAT: `ssid / bssid / interface / security`

### 注意

- **SSID/BSSID は macOS 14+ で取得困難(TDプラグインからは実質不可)**。数値(rssi/noise/channel/
  txRate/PHY)は無条件で取れる。`connected` はチャンネル関連付け(または rssi≠0)で判定する
- 未接続時は Warning。値はポーリング(cook 毎)
- SSID 名が必要なら [CoreWLAN Scan](../CoreWLANScan/) を使う。用途文字列を持つ小さなヘルパー `.app`
  を同梱していて、周囲の SSID を列挙できる

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
(常に nil を返す動かないトグルになるため)。

### ビルド

```
cd CoreWLAN && ./build.sh
```
