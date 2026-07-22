# SwiftUI TOP

**SwiftUI ビューをテクスチャにレンダして TOP に出す**。SF Symbols・システムフォント・
Swift の Gauge / ProgressView など、**macOS ネイティブUIの見た目**を TD の映像として使える。
値は TD 側(パラメータ)から流し込む一方向。

SwiftUI のレンダは Swift ヘルパ(`SwiftUIHelper`・C ABI `su_`)が **メインスレッド**で行い
(`ImageRenderer`)、cook は最新テクスチャを非ブロックでアップロードする。SwiftUI はメイン
スレッド専用だが、**TDがメインrunloopをpumpする**ので `DispatchQueue.main.async` で回せる。

## Mode(代表的な SwiftUI コンポーネント)

| Mode | 内容 |
|---|---|
| **Text** | システムフォント(rounded/semibold)のテキスト |
| **SF Symbol** | Apple の SF Symbols(`star.fill` / `waveform.circle.fill` / `bolt.fill` …) |
| **Gauge (circular)** | 円形ゲージ(`accessoryCircular`)。Value 0..1 |
| **Progress (bar)** | 横向きバー。**塗り=Foreground色 / トラック=薄いForeground**。Value 0..1(図形描画で確実にレンダ) |

### バーの色
progress バーの**塗り色は Foreground**(トラックはその薄色)。Gauge も Foreground が反映される。
色は RGBA。TD の Python から設定するときは**成分ごと**(`Textcolorr/g/b/a`)に。

### SF Symbols とは
Apple の**アイコン集(約5000+のシンボル)**。文字ではなくベクターアイコンで、`star.fill` /
`heart.fill` / `bolt.fill` / `wifi` / `waveform` / `play.fill` / `music.note` / `camera.fill` /
`sun.max.fill` / `gearshape.fill` など。正確な名前は **SF Symbols.app**(Apple 公式・無料)で検索。
`symbol` モードで名前を入れると、そのアイコンがシステム色/サイズで描かれる。

### マウス操作(値をUIで動かす)
TOP はテクスチャなので **TD からマウスイベントは渡らない**(レンダされたバーを直接クリックは不可)。
値をマウスで動かすには、TD 側のUIを `Value` に配線する:
- **Value パラメータのスライダーをドラッグ**(0..1・そのまま操作可)
- **Slider COMP を配線**: `Value` の式に `op('slider1').panel.u` → スライダーをドラッグでバーが動く
  (sample.toe の `/project1/swiftui_demo` がこの構成。実測でスライダー値にバーが追従)
- **Mouse In CHOP** や他のCHOPでも同様に駆動できる

## 実測(M2・macOS 26.5.1)

4モードすべて TOP に正しくレンダ(向き正立)を視認確認:
- Text「SwiftUI in TD」(rounded semibold・白/ダーク)
- SF Symbol `bolt.fill`(黄・Foreground色反映)、`waveform.circle.fill`
- Gauge 72%(円形・"72"/"LEVEL"ラベル)
- 背景色(赤)+ 白テキスト「● LIVE ●」で Foreground/Background 反映を確認
- デモ(sample.toe `/project1/swiftui_demo`)は Value を sin で駆動し**ゲージがライブで動く**

## パラメータ

| パラメータ | 説明 |
|---|---|
| Mode | text / symbol / gauge / progress |
| Text | 表示テキスト(Text/Gauge/Progress のラベル) |
| SF Symbol | SF Symbol 名(symbol モード) |
| Value (0..1) | ゲージ/バーの値 |
| Font / Symbol Size | フォント/シンボルのサイズ |
| Foreground / Background | 前景色 / 背景色(RGBA。背景 alpha 0 で透過) |
| Width / Height | 出力解像度 |

Info CHOP: `executes / submits / frames`

## 使い方のコツ

- **値を TD から流す**: `Value` に式(例 `0.5+0.5*math.sin(absTime.seconds*2)`)や CHOP 参照を
  入れると、ゲージ/バーが**ライブで動く**。テキストも op 参照で動的に
- **背景透過**(Background の alpha=0)にすれば、Composite TOP で他の映像に**ネイティブUIを重ねられる**
- SF Symbols は Apple の SF Symbols アプリで名前を確認

## 制約・注意

- **一方向(表示専用)**。TOP には TD からマウス/キーイベントが渡らないので、TOP内のUIを
  直接クリックする双方向操作はできない(双方向が要るなら別途 NSWindow 方式のOPが必要)
- パラメータ変化時のみ再レンダ(変化検知)。毎フレーム変わる式を入れると毎フレーム再レンダ
- レンダはメインスレッド。重い SwiftUI を高頻度で更新すると TD のUIに影響しうる
- **macOS 13+ 必須**(`ImageRenderer`)

## ビルド

```
cd SwiftUI && ./build.sh   # → build/SwiftUITOP.plugin(SwiftUIHelper 同梱)
```
