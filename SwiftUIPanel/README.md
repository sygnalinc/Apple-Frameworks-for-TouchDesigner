# SwiftUI Panel CHOP

**本物の操作可能な macOS ウインドウを TD のUIとして使う**。JSON で定義したコントロール
(Slider / Toggle / Button / Stepper)を実ウインドウ(NSWindow + SwiftUI)に表示し、
ユーザーが**マウスで操作した値を CHOP チャンネルとして出力**する。

SwiftUI TOP(テクスチャ・表示専用)と違い、これは**実ウインドウ**なのでネイティブコントロールが
そのまま**操作できる**(ImageRenderer が描けない Slider/Toggle も本物として動く)。ショー制御の
外部パネル、オペレータ用UI、ライブパフォーマンスのコントローラなどに。

## 使い方

コントロールの定義は**2通り**:

- **A. Widgets DAT(推奨・部品を個別opで)**: [UI Widget DAT](../UIWidget/) を複数置いて Merge DAT で
  まとめ、その Merge を **Widgets** パラメータに指定。TD の Button/Slider COMP を Container に
  入れる感覚(部品=DAT、コンテナ=このPanel)
- **B. Controls JSON**: Widgets DAT を繋がない場合、**Controls JSON** パラメータに直接記述

いずれも各コントロールの `id` が CHOP チャンネル名になる。**Show Window** で表示、
`Window X/Y/W/H` で位置・サイズ。ウインドウをマウスで操作 → `out` にライブで値が流れる。

```json
{"controls":[
  {"type":"header","label":"Show Controls"},
  {"type":"slider","id":"brightness","label":"Brightness","value":0.6},
  {"type":"slider","id":"speed","label":"Speed","min":0,"max":10,"value":3},
  {"type":"toggle","id":"strobe","label":"Strobe","on":false},
  {"type":"button","id":"fire","label":"Fire!"},
  {"type":"stepper","id":"count","label":"Count","min":0,"max":10,"step":1,"value":3}
]}
```

## コントロール → チャンネル

| type | 出力 | フィールド |
|---|---|---|
| `slider` | その値(min..max) | id / label / value / min / max |
| `toggle` | 0 or 1 | id / label / on |
| `button` | **押した瞬間だけ 1**(モーメンタリ) | id / label |
| `stepper` | その値 | id / label / value / min / max / step |
| `header` / `text` / `divider` | 表示のみ(チャンネルにならない) | label |

## 実測(M2・macOS 26.5.1・実操作で検証)

TD からウインドウを出し、**マウスで操作 → CHOP 値が追従**することを確認:
- Brightness スライダーをドラッグ → `brightness` = 0.48 → 0.99(ウインドウ表示と一致)
- Strobe トグルをクリック → `strobe` = 1
- Fire ボタンをクリック → `fire` が **1フレームだけ 1**(モーメンタリ)、次のcookで 0
- ウインドウはフローティング(`.floating`)で TD の上に常駐。閉じる/最小化も可能

## パラメータ

| パラメータ | 説明 |
|---|---|
| Show Window | ウインドウ表示 / 非表示 |
| Window Title | タイトルバーの文字 |
| Controls JSON | コントロール定義(式で Text DAT 参照 `op('json1').text` 可) |
| Window X / Y | 位置(画面座標・左下原点) |
| Window Width / Height | サイズ |

Info CHOP: `executes / controls`(コントロール数)

## 制約・注意

- ウインドウは**実ウインドウ**(TD本体のNSApplicationが持つ)。TDのビューポート内には出ない
- UI はメインスレッドで表示(TDがメインrunloopをpump)。cook は値を読むだけで非ブロック
- 値の**書き戻し**(TD側からウインドウのスライダーを動かす)は未対応(操作は一方向: 人→TD)
- テキスト入力欄(NSTextField)は将来対応。現状は数値/トグル/ボタン
- ボタンはモーメンタリ。押下は次の cook で 1 として読まれる(出力をどこかで使い毎フレームcookさせる)

## ビルド

```
cd SwiftUIPanel && ./build.sh   # → build/SwiftUIPanelCHOP.plugin(SwiftUIPanelHelper 同梱)
```
