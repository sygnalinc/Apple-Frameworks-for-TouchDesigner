# palette — TouchDesigner Palette 用 .tox テンプレート

配線済みの Component を **TD の Palette(My Components / sygnal)** にドラッグ&ドロップで
使えるようにした .tox。中身の**カスタムOP(.plugin)は別途インストールが必要**(下記)。

> **.plugin(エンジン)+ .tox(テンプレート)の二層**: ネイティブUIのレンダリングは .plugin が担い、
> .tox は「配線済み・パラメータ露出済み」の再利用テンプレート。.tox 単体では動かない(プラグイン必須)。

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

## Palette への登録

`NativePanel.tox` を TD のユーザーpaletteフォルダへ置く:

```
~/Library/Application Support/Derivative/TouchDesigner099/palette/sygnal/NativePanel.tox
```

TD の **Palette Browser**(左の Palette パネル)に `My Components > sygnal > NativePanel` として現れる。
そこから任意のネットワークへドラッグ&ドロップ → `Show Window` をオンにするとネイティブウインドウが出る。

## 実測(M2)

- NativePanel.tox(1.2KB)をフレッシュにロード → Show/Title カスタムパラメータ・全部品・
  out の3チャンネル(level/enable/trigger)を復元、ウインドウ表示を確認
