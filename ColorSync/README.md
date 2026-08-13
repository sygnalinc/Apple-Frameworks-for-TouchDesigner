# ColorSync TOP

入力TOPを **ColorSync/ICC** で色空間変換する(sRGB / Display P3 / Adobe RGB / Rec.2020 /
Generic RGB / Generic Gray / 任意 `.icc` プロファイル間)。CGColorSpace はICCプロファイル(ColorSync)で
色管理されるので、CGImageの描画による変換 = ColorSync 変換。**表示装置別の色変換**に使える。

## 実測(M2)

- 定数色 sRGB(0.9,0.1,0.1) → Display P3 = (0.824,0.208,0.165)。広色域への変換で成分値が正しく変化

## パラメータ

| パラメータ | 説明 |
|---|---|
| Active | 有効 |
| Source Space / Destination Space | sRGB / Display P3 / Adobe RGB / Rec.2020 / Generic RGB / Generic Gray / ICC File |
| Source ICC File / Destination ICC File | `File` 選択時の `.icc` プロファイル |

Info CHOP: `executes / submits / converts`

## 注意

- 入力は BGRA8 でダウンロードし、source色空間のCGImage→dest色空間のコンテキストへ描画して変換
- `.icc` ファイルを指定すればディスプレイ実測プロファイル等にも変換できる
- cook はブロックせずワーカーで変換(1〜2フレーム遅延で最新を出力)

## ビルド
```
cd ColorSync && ./build.sh
```
