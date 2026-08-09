# palette — .tox templates for the TouchDesigner Palette

**English** | [日本語](#日本語)

## English

Pre-wired Components you can drag and drop from **TD's Palette (My Components / sygnal)**.
The custom operators (.plugin) they contain **must be installed separately** (see below).

> **Two layers: .plugin (the engine) + .tox (the template).** The plugin does the real work; the
> .tox is just a reusable, pre-wired, parameter-exposed arrangement of it. **A .tox alone does
> nothing** — the plugin is required.

### WifiScanner.tox

A Component with the **CoreWLAN Scan CHOP and its SSID Info DAT already wired up**, for when you
want to turn Get SSID on and see the SSID table without building an Info DAT by hand.

> **Note**: the CoreWLAN Scan CHOP itself now also **creates the Info DAT automatically via a
> Callbacks DAT** (press `Add` on the Custom page, then turning Get SSID ON creates the Info DAT
> next to it — see that operator's README). This .tox is for when you want it done in one drop
> without even pressing Add. There is no SDK hook for creating nodes unconditionally on placement,
> so it is either the callback (which needs a Callbacks DAT) or a .tox.

- Contents: `scan` (CoreWLAN Scan CHOP) / `congestion` (null CHOP, congestion) / `ssid` (Info DAT,
  the SSID list)
- **Parameters exposed on the COMP**: `Get SSID Names` (default On) / `Scan Interval` /
  `Rescan Now` (bound to the inner scan; Rescan is propagated by a Parameter Execute)
- `congestion` is per-channel congestion and the free channel (**no permission needed**); `ssid`
  is the list of surrounding networks (populated with Get SSID on plus location permission)

**Required plugin**: [CoreWLANScan](../CoreWLANScan/) → `CoreWLANScanCHOP.plugin` (bundles the SSID
helper)

**Measured**: dropping in WifiScanner filled the `ssid` Info DAT with the surrounding SSIDs
automatically (24 rows — SYGNAL, SCC_JBFES, …).

### Registering with the Palette

Put the `.tox` in TD's user palette folder:

```
~/Library/Application Support/Derivative/TouchDesigner099/palette/sygnal/WifiScanner.tox
```

It appears in TD's **Palette Browser** (the Palette panel on the left) as
`My Components > sygnal > WifiScanner`. Drag it into any network from there.

### Components that moved to the develop branch

`NativePanel.tox` and `SwiftUIButton.tox` (native macOS window UI) depend on the SwiftUI Panel CHOP
and UI Widget DAT, which were moved to the non-public `develop` branch on 2026-08-07, so they are
no longer here. They live on `develop` together with those plugins.

## 日本語

配線済みの Component を **TD の Palette(My Components / sygnal)** にドラッグ&ドロップで
使えるようにした .tox。中身の**カスタムOP(.plugin)は別途インストールが必要**(下記)。

> **.plugin(エンジン)+ .tox(テンプレート)の二層**: 実際の処理は .plugin が担い、
> .tox は「配線済み・パラメータ露出済み」の再利用テンプレート。**.tox 単体では動かない**(プラグイン必須)。

### WifiScanner.tox

**CoreWLAN Scan CHOP + SSID Info DAT を配線済み**にした Component。
「Get SSID を ON にしたら SSID表(Info DAT)を手で作らずに見たい」に応える。

> **補足**: CoreWLAN Scan CHOP 本体にも **Callbacks DAT 経由の自動生成**が入った
> (Custom ページで `Add` → Get SSID ON で隣に Info DAT が自動生成。CHOP の README 参照)。
> この .tox は「Add すら押さずに1ドロップで完結」させたい場合用。設置時に無条件で自動生成する
> フックは SDK に無いため、コールバック(要 Callbacks DAT)か .tox の二択になる。

- 中身: `scan`(CoreWLAN Scan CHOP)/ `congestion`(null CHOP・混雑度)/ `ssid`(Info DAT・SSID一覧)
- **COMP に露出したパラメータ**: `Get SSID Names`(既定On)/ `Scan Interval` / `Rescan Now`
  (内部 scan にバインド。Rescan は Parameter Execute で伝播)
- `congestion` はチャンネル別混雑度・空きch(**権限不要**)、`ssid` は周辺SSID一覧
  (Get SSID On + 位置情報許可で埋まる)

**必要プラグイン**: [CoreWLANScan](../CoreWLANScan/) → `CoreWLANScanCHOP.plugin`(SSIDヘルパー同梱)

**実測**: WifiScanner を置くと `ssid` Info DAT に周辺SSID(24行・SYGNAL/SCC_JBFES等)が自動で出た。

### Palette への登録

`.tox` を TD のユーザーpaletteフォルダへ置く:

```
~/Library/Application Support/Derivative/TouchDesigner099/palette/sygnal/WifiScanner.tox
```

TD の **Palette Browser**(左の Palette パネル)に `My Components > sygnal > WifiScanner` として
現れる。そこから任意のネットワークへドラッグ&ドロップする。

### develop ブランチへ移した Component

ネイティブ macOS ウインドウUIの `NativePanel.tox` / `SwiftUIButton.tox` は、依存する
SwiftUI Panel CHOP と UI Widget DAT を 2026-08-07 に非公開の `develop` ブランチへ移したため、
ここには無い。両プラグインと一緒に `develop` にある。
