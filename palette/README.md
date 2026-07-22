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
