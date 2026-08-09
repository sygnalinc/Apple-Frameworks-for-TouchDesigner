# CoreWLAN Scan CHOP

**English** | [日本語](#日本語)

## English

Scans the surrounding Wi-Fi and reports **per-channel congestion, AP count and peak RSSI** as
numeric CHOP channels. A **spectrum-environment tool** for seeing which channels are busy and
which are free: choosing a channel, monitoring congestion at a venue, or driving something
reactive from the congestion value.

It uses `CWInterface.scanForNetworks`. RSSI, band (2.4/5 GHz) and channel width need no
permission. **SSID names and BSSIDs are available if location access is granted** (the
`Get SSID Names` toggle, below).

### Getting SSID names (Get SSID Names)

On macOS 14.4+ the SSID from `scanForNetworks` is **gated behind Location permission**. With
permission, SSID/BSSID are returned (verified). But **TouchDesigner itself has no location usage
string in its Info.plist**, so a plugin cannot request the permission directly.

The workaround is a small **helper `.app` with its own Info.plist (and location usage string)**
bundled with the plugin. Turning on `Get SSID Names` makes the CHOP launch it:

```
CoreWLAN Scan CHOP → (open) → wifiscan-helper.app → Location permission + scanForNetworks
                                     → JSON (~/Library/Caches/TDAppleML/wifiscan.json) → read by the CHOP
```

- **The first time, a "wifiscan-helper would like to use your location" dialog appears** — allow it
- After that, SSID/BSSID/RSSI/channel/band appear in the **Info DAT**
  (`ssid / bssid / rssi / channel / band`)
- The congestion channels (below) keep working without any permission (those use the built-in scan)

#### Automatic SSID Info DAT (fully automatic, no setup)

**Just place the operator** and a pre-filled **Callbacks DAT** (`<node>_callbacks`) is created and
connected for you (the operator creates it on its first cook; custom parameters do not exist yet
right after creation, so it retries until it succeeds). The Callbacks DAT is **docked to the node
just like a GLSL TOP's shader DAT**, and the chip below the host is **closed by default**
(showDocked = False, a ↓ chip). Click the chip and the DAT opens for editing, same as GLSL.
From then on, **the moment `Get SSID Names` goes ON an SSID list Info DAT (`<node>_ssid`) is
created next to it** (nothing happens if one exists — duplicate guard).

```
place the OP → <node>_callbacks (pre-filled) is connected automatically
Get SSID Names ON → <node>_ssid (Info DAT) appears → the SSID list shows up on its own
```

- Edit `onGetSSID(op, enabled)` in the Callbacks DAT to change the behaviour (placement, name,
  viewer visibility…). Delete the Callbacks DAT and it is recreated the next time Get SSID goes ON
- **Measured**: on placement (first cook) `_callbacks` connects, and the instant Get SSID goes ON
  `_ssid` is created; after the scan finishes 17 SSIDs (SYGNAL etc.) are listed automatically.
  Toggling ON/OFF repeatedly still leaves exactly one of each
- Making the Info DAT by hand and pointing Operator at this OP works the same

**Measured (M2, macOS 26.5.1)**: the helper returned 18 SSIDs (`SYGNAL` / `SYGNAL_GUEST` /
`SCC_JBFES` / `Buffalo-G-D32E` …) with RSSI and channel.

> Note: this README used to say "the SSID cannot be obtained" — that was **wrong** (it can, with
> location permission) and has been corrected. The problem that the responsible process (TD) has
> no usage string is worked around by the helper `.app` above.

### Congestion model

Each AP's occupied band (centre frequency ± channel width / 2) is **apportioned by how much it
overlaps** each 20 MHz channel slot, and linear power `10^(rssi/10)` is accumulated.
**Interference from 40/80 MHz APs onto neighbouring channels is therefore included.** Each band is
normalised so its maximum is 1 (`congestion` is 0–1). `best_ch` is the least congested channel in
that band.

### Output (CHOP, 126 channels)

| Channel | Description |
|---|---|
| `scans` / `scanning` / `networks` | Scan count / scanning now / total detected |
| `networks_24` / `networks_5` | Detected on 2.4 GHz / 5 GHz |
| `ch{n}_24/aps` `.../rssi` `.../congestion` | Per 2.4 GHz channel (1–14): AP count / peak RSSI / congestion (0–1) |
| `ch{n}_5/aps` `.../rssi` `.../congestion` | Per 5 GHz channel (36–165): AP count / peak RSSI / congestion |
| `best_ch_24` / `best_congestion_24` | Freest 2.4 GHz channel / its congestion |
| `best_ch_5` / `best_congestion_5` | Freest 5 GHz channel / its congestion |

Info CHOP: `executes / scans / networks`

**Info DAT** (when `Get SSID Names` is on): the surrounding SSID list as
`ssid / bssid / rssi / channel / band`

### Parameters

| Parameter | Description |
|---|---|
| Scan Interval (s) | Automatic scan interval (default 10 s; 0 = manual only) |
| Rescan Now | Scan immediately (pulse) |
| Get SSID Names (Location) | Fetch SSID names (default Off). Goes through the helper `.app`; a location dialog appears the first time |
| Callbacks DAT (Custom page) | A pre-filled DAT is connected on placement. Edit the automatic Info DAT creation here |

### Measured (M2, macOS 26.5.1)

Six networks detected at home (4 on 2.4 GHz, 2 on 5 GHz). There is a **strong 40 MHz AP on ch10
(-44 dBm)**, and its interference spreading over ch8–12 shows up as a congestion gradient.
**best 2.4 GHz = ch1 and best 5 GHz = ch36** were reported correctly. No errors or warnings.

### Notes

- **`scanForNetworks` blocks (for seconds)**, so it runs **on a worker thread**; cook only reads
  the latest aggregated snapshot (never blocks). An active scan briefly disturbs the connection,
  so don't set Scan Interval too short (default 10 s)
- **SSID names come from `Get SSID Names`** (needs location permission, via the helper `.app`).
  Congestion needs no permission
- Scanning uses the connected interface (en0 etc.). With Wi-Fi off, networks = 0 and a warning
- Which 5 GHz channels appear (DFS channels and so on) varies with environment, region and driver
- The SSID helper communicates through `~/Library/Caches/TDAppleML/wifiscan.json`, so its result
  lands one scan behind

### Build

```
cd CoreWLANScan && ./build.sh   # → build/CoreWLANScanCHOP.plugin (bundles wifiscan-helper.app)
```

The helper `.app` is Swift (CoreWLAN + CoreLocation). `build.sh` bundles and signs it at
`Contents/Resources/Helpers/wifiscan-helper.app`.

## 日本語

周辺のWi-Fiをスキャンし、**チャンネル別の混雑度・AP数・最大RSSI**を数値CHOPで出す。
「電波が混んでいる/空いているチャンネルはどこか」を可視化する**電波環境ツール**。
チャンネル選定(空き帯域探し)・展示会場の電波混雑モニタ・混雑度をリアクティブ入力に、等。

`CWInterface.scanForNetworks` を使う。RSSI・帯域(2.4/5GHz)・チャンネル幅は権限なしで取れる。
**SSID名/BSSID は位置情報の許可があれば取得できる**(`Get SSID Names` トグル・下記)。

### SSID名の取得(Get SSID Names)

macOS 14.4+ では **scanForNetworks の SSID は「位置情報の許可(Location)」でゲート**されている。
許可があれば SSID/BSSID が返る(実測で確認)。ただし **TouchDesigner 本体は Info.plist に位置情報の
用途文字列を持たない**ため、プラグインから直接は許可を要求できない。

そこで **独自 Info.plist(位置情報の用途文字列)を持つ小さなヘルパー .app を同梱**し、
`Get SSID Names` をオンにすると CHOP がそのヘルパーを起動する:

```
CoreWLAN Scan CHOP → (open) → wifiscan-helper.app → Location許可 + scanForNetworks
                                     → JSON(~/Library/Caches/TDAppleML/wifiscan.json)→ CHOPが読む
```

- **初回だけ「wifiscan-helper が位置情報を使おうとしています」の許可ダイアログ**が出る → 許可
- 許可後は SSID/BSSID/RSSI/channel/band が **Info DAT** に出る(`ssid / bssid / rssi / channel / band`)
- 混雑度チャンネル(下記)は権限なしでも従来どおり動く(こちらは内蔵scan)

#### SSID Info DAT の自動生成(完全自動・操作不要)

**OPを配置するだけ**で、雛形入りの **Callbacks DAT**(`<node名>_callbacks`)が自動生成・接続される
(初回cook時に本体が生成。生成直後はカスタムパラメータ未生成のため成功するまで自動リトライ)。
Callbacks DAT は **GLSL TOP のシェーダDATと同様に本体ノードへドック**され、ホスト下部の
**チップは既定で閉じている**(showDocked=False・↓チップ)。チップをクリックすると
GLSL同様にDATが開いてスクリプトを編集できる。
以降 **`Get SSID Names` を ON にした瞬間に、隣へ SSID 一覧の Info DAT(`<node名>_ssid`)が
自動生成**される(既にあれば何もしない=二重生成ガード)。

```
OPを配置 → <node名>_callbacks(雛形入り)が自動で接続される
Get SSID Names ON → 隣に <node名>_ssid(Info DAT)が出現 → SSID一覧が自動表示
```

- 自動生成の挙動は Callbacks DAT の `onGetSSID(op, enabled)` を編集して変えられる(生成位置・
  名前・viewer 表示など)。Callbacks DAT を消しても Get SSID ON でもう一度自動生成される
- **実測**: 配置(初回cook)で `_callbacks` が接続され、Get SSID ON の瞬間に `_ssid` が生成、
  スキャン完了後 17 SSID(SYGNAL 等)が自動表示。ON/OFFを繰り返しても各1個のまま
- 手動で Info DAT を作って Operator に本OPを指定しても同じ

**実測(M2・macOS 26.5.1)**: ヘルパーが 18件のSSID(`SYGNAL` / `SYGNAL_GUEST` / `SCC_JBFES` /
`Buffalo-G-D32E` 等)を RSSI/チャンネル付きで取得。

> 補足: 以前このREADMEは「SSIDは取得不可」としていたが**誤り**だった(位置情報の許可で取れる)。
> 訂正済み。責任プロセス(TD本体)に用途文字列が無い問題は、上記のヘルパー .app 方式で回避している。

### 混雑度モデル

各APの占有帯域(中心周波数 ± チャンネル幅/2)を、各20MHzチャンネル枠との**重なり割合で按分**し、
線形強度 `10^(rssi/10)` を加算する。**40/80MHz幅のAPが隣接chへ与える干渉も反映**される。
各バンドで最大値=1に正規化(`congestion` は 0〜1)。`best_ch` = そのバンドで最も混雑度が低いch。

### 出力(CHOP・126ch)

| チャンネル | 内容 |
|---|---|
| `scans` / `scanning` / `networks` | スキャン回数 / スキャン中 / 検出総数 |
| `networks_24` / `networks_5` | 2.4GHz / 5GHz の検出数 |
| `ch{n}_24/aps` `.../rssi` `.../congestion` | 2.4GHz 各ch(1〜14)のAP数 / 最大RSSI / 混雑度(0〜1) |
| `ch{n}_5/aps` `.../rssi` `.../congestion` | 5GHz 各ch(36〜165)のAP数 / 最大RSSI / 混雑度 |
| `best_ch_24` / `best_congestion_24` | 2.4GHzで最も空いてるch / その混雑度 |
| `best_ch_5` / `best_congestion_5` | 5GHzで最も空いてるch / その混雑度 |

Info CHOP: `executes / scans / networks`

**Info DAT**(`Get SSID Names` オン時): `ssid / bssid / rssi / channel / band` の周辺SSID一覧

### パラメータ

| パラメータ | 説明 |
|---|---|
| Scan Interval (s) | 自動スキャン間隔(既定10s。0=手動のみ) |
| Rescan Now | 今すぐスキャン(パルス) |
| Get SSID Names (Location) | SSID名取得(既定Off)。ヘルパー.app経由・初回に位置情報許可ダイアログ |
| Callbacks DAT (Customページ) | 配置時に雛形入りDATが自動接続される。Get SSID ON時のInfo DAT自動生成をここで編集できる |

### 実測(M2・macOS 26.5.1)

自宅環境で6ネットワーク検出(2.4GHz×4・5GHz×2)。**ch10 に 40MHz幅の強AP(-44dBm)**があり、
その干渉が ch8〜12 に広がる様子(混雑度グラデーション)を確認。**best 2.4GHz = ch1・best 5GHz = ch36**
(最も空いているch)を正しく提示。エラー・警告なし。

### 注意

- **scanForNetworks はブロックする(数秒)**ため**ワーカースレッドで実行**し、cook は最新の集計
  スナップショットを読むだけ(非ブロック)。アクティブスキャンは接続を一瞬乱すので Scan Interval は
  短くしすぎない(既定10s)
- **SSID名は `Get SSID Names` で取れる**(位置情報許可が要る・ヘルパー.app経由)。混雑度は権限不要
- スキャンは接続中のインターフェース(en0等)で行う。Wi-Fiオフ時は networks=0 で Warning
- 5GHzのDFSチャンネル等、環境・地域・ドライバによって検出されるchは変わる
- SSIDヘルパーは `~/Library/Caches/TDAppleML/wifiscan.json` を介す。結果は1スキャンぶん遅れて反映

### ビルド

```
cd CoreWLANScan && ./build.sh   # → build/CoreWLANScanCHOP.plugin(wifiscan-helper.app 同梱)
```

ヘルパー .app は Swift(CoreWLAN + CoreLocation)。build.sh が
`Contents/Resources/Helpers/wifiscan-helper.app` に同梱・署名する。
