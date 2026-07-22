# UI Widget DAT

**SwiftUI Panel 用のUI部品を1つ定義する**(TD の Button/Slider COMP のプラグイン版)。
複数の UI Widget DAT を **Merge DAT でまとめて [SwiftUI Panel](../SwiftUIPanel/) の Widgets に
繋ぐ**と、1つのネイティブウインドウに集約されて表示・操作できる。

> **なぜ DAT なのか**: TD の Custom OP SDK は TOP/CHOP/DAT/SOP/POP のみで **COMP は作れない**。
> そこで「部品 = spec を出す DAT」「コンテナ = Panel(実ウインドウ)」に置き換えている。
> Button/Slider COMP を Container に入れる感覚を、DAT → Merge → Panel で再現する。

## 使い方

```
UI Widget DAT (slider) ┐
UI Widget DAT (toggle) ├─ Merge DAT ─→ SwiftUI Panel CHOP ─→ 値(id別チャンネル)
UI Widget DAT (button) ┘
```

1. UI Widget DAT を置いて **Type**(slider/toggle/button/stepper/text/header/divider)と
   **ID / Label / Min / Max / Value** を設定
2. 複数を **Merge DAT** で縦に積む(= Container に入れるイメージ)
3. Merge を [SwiftUI Panel](../SwiftUIPanel/) の **Widgets** に指定 → 1つの窓に集約
4. 窓を操作 → Panel の出力CHOPに **id 別チャンネル**で値が出る(`Select CHOP` で個別に取り出せる)

## 出力

1×1 テーブル。cell(0,0) = このウィジェットの JSON spec(例
`{"type":"slider","id":"brightness","label":"Brightness","value":0.6,"min":0,"max":1}`)。
Merge で積むと Panel が各行を1コントロールとして読む。

## パラメータ

| パラメータ | 説明 |
|---|---|
| Type | slider / toggle / button / stepper / text / header / divider |
| ID (channel name) | Panel 出力での**チャンネル名** |
| Label | 表示ラベル |
| Default Value | 初期値(slider/toggle/stepper) |
| Min / Max / Step | slider/stepper の範囲・刻み |
| Color | 色(RGBA。既定の白以外で spec に付与) |

## 実測(M2)

UI Widget DAT ×3(slider brightness / toggle strobe / button fire)→ Merge → SwiftUI Panel。
**「Assembled Panel」1つの窓に3部品が揃い**、Brightness スライダーをドラッグ →
Panel 出力の `brightness` = 0.60 → 0.95 に追従(実操作で確認)。

## ビルド

```
cd UIWidget && ./build.sh   # → build/UIWidgetDAT.plugin
```
