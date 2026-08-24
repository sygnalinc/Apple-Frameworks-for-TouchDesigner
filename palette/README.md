# palette — TouchDesigner Palette 用 .tox テンプレート

配線済みの Component を **TD の Palette(My Components / sygnal)** にドラッグ&ドロップで
使えるようにした .tox。中身の**カスタムOP(.plugin)は別途インストールが必要**(下記)。

> **.plugin(エンジン)+ .tox(テンプレート)の二層**: 実際の処理は .plugin が担い、
> .tox は「配線済み・パラメータ露出済み」の再利用テンプレート。.tox 単体では動かない(プラグイン必須)。

## DroneCamera.tox

**GameController CHOP を繋ぐだけでパッド操作できるドローン飛行カメラ**(Camera COMP)。
`demo.toe` の `/project1/GameController` にあるドローンデモの「操縦部分」だけを取り出して、
どのプロジェクトへでもコピペで持っていける形にまとめたもの。

- **Camera COMP そのもの**なので、Render TOP の `Camera` にそのまま指定できる
- **使い方は「GameController CHOP をワイヤで繋ぐ」だけ**(中の `in1` が受ける)
- パッドが無くてもキーボードで動く(WASD / Q E / Space / Shift / Z X / R)
- **複数置いても互いに干渉しない。** コピーすると必ず Home から始まる
  (COMP の id を状態に持たせて複製を検出しているため、飛行中のものをコピーしても
  位置を引き継がない)

### 操作

| 入力 | 動作 |
|---|---|
| A / B ・ W S | 前進 / 後進(**カメラが向いている方向**・チルト込み) |
| 右スティック X / A D | 水平に平行移動 |
| 右スティック Y | 上昇 / 下降(R2 / L2 と同じ。合算して ±1 に丸める) |
| 左スティック X / Q E | バンク旋回(倒した量ぶん傾き、その傾きで旋回する。戻せば水平へ復帰) |
| 左スティック Y | チルト(俯仰)。上に倒すと見上げる |
| R2 / Space ・ L2 / Shift | 上昇 / 下降 |
| L1 / R1 ・ Z / X | FOV 望遠 / 広角 |
| Menu / R | Home へリセット(`Reset To Home` パルスと同じ) |

### パラメータ

- **Drone**: `Active` / `Keyboard Fallback` / `Rumble On Landing` / `Reset To Home` /
  `Speed` / `Lift Speed` / `Turn Rate` / `Tilt Rate` / `FOV Rate` / `Stick Deadzone` /
  `Home Position` / `Home Heading` / `Home Tilt` / `Home FOV`
- **Limits**: `Air Damping` / `Bank Response` / `Bank Max` / `Tilt Min` / `Tilt Max` /
  `FOV Min` / `FOV Max` / `Altitude Min` / `Altitude Max` / `Range`(**0 = 無制限**)

**必要プラグイン**: [GameController](../GameController/) → `GameControllerCHOP.plugin`
(キーボードだけで動かすならプラグイン無しでも使える)

> **Rotate Order は `zxy` 固定**。roll を最初に適用することでバンクが**カメラの光軸まわり**になり、
> 傾けても視線方向が変わらない。`xyz` に変えると傾けたときに視線ごと動いてしまう。

**実測(M2)**: 疑似パッドで前進 → z が減り高度が Altmin まで下がる / バンク上限 ±46°・離すと 0 へ復帰 /
上昇で高度 12 → 64 / FOV が Fovmax 160 まで / Menu と `Reset To Home` で Home (0,12,34) へ復帰。
実機パッド(`lsticky = 1.0`)でも追従し、`lstickx = -0.088` は Deadzone 0.15 内なので正しく無視された。
飛行中の状態をコピーしても、コピー先は次のフレームで Home から始まることを確認。

## NativePanel.tox

**本物の操作可能なネイティブmacOSウインドウUI**を1ドロップで使える Component。
中身は `UI Widget DAT ×4 → Merge → SwiftUI Panel CHOP → out`(= [UIWidget](../UIWidget/) +
[SwiftUIPanel](../SwiftUIPanel/) の構成)。

- **COMP に露出したパラメータ**: `Show Window`(窓の表示)/ `Window Title`
- **`out`**(null CHOP)にウインドウ操作値が id 別チャンネルで出る(`level` / `enable` / `trigger`)
- 中に入って UI Widget DAT を足す/編集すればコントロールを増やせる

### 必要なプラグイン(先にインストール)

- [UIWidget](../UIWidget/) → `UIWidgetDAT.plugin`
- [SwiftUIPanel](../SwiftUIPanel/) → `SwiftUIPanelCHOP.plugin`

各フォルダで `./build.sh` → `~/Library/Application Support/Derivative/TouchDesigner099/Plugins/` へ
コピー → TD再起動。

## SwiftUIButton.tox

**TD の Button COMP の "ネイティブUI版"**。Button COMP の基本機能(クリックで `state` を出力・
既定 Momentary)はそのままに、**ボタンの見た目が本物のネイティブ macOS ボタン**になっている。

- **COMP に露出したパラメータ**: `Label`(ボタン文字)/ `Show Window` / `Window Title`
- **`out`**(null CHOP)に `state` チャンネル: **クリックした瞬間だけ 1**(モーメンタリ)。
  Button COMP の出力と同じ感覚で配線できる(Panel Execute の代わりに CHOP 監視 / Trigger 等)
- 中身は `UI Widget DAT(button)→ SwiftUI Panel CHOP → out`

> **重要(できる/できない)**: TD標準 Button COMP の**UI描画そのものをSwiftUIに差し替えることは不可**
> (TDにフックが無い)。これは「Button COMP と同じ出力仕様を持つ、UIがネイティブSwiftUIな**別COMP**」。
> Toggle 動作は現状フラつく(モーメンタリ信号のCount取りこぼし)ため v1 は Momentary のみ。将来
> ヘルパ側で toggle ボタンを堅牢化予定。

**実測**: ネイティブ「Button」ウインドウを表示 → クリック → `out` の `state` が1フレームだけ 1
(次フレーム 0)を実操作で確認。

## WifiScanner.tox

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

## Palette への登録

使いたい .tox を TD のユーザーpaletteフォルダへ置く:

```
~/Library/Application Support/Derivative/TouchDesigner099/palette/sygnal/
```

TD の **Palette Browser**(左の Palette パネル)に `My Components > sygnal > NativePanel` として現れる。
そこから任意のネットワークへドラッグ&ドロップ → `Show Window` をオンにするとネイティブウインドウが出る。

## 実測(M2)

- NativePanel.tox(1.2KB)をフレッシュにロード → Show/Title カスタムパラメータ・全部品・
  out の3チャンネル(level/enable/trigger)を復元、ウインドウ表示を確認
