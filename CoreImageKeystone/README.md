# Vision Keystone TOP

VisionRect CHOPが検出した四隅、または手動指定した四隅から入力画像を正対させる透視補正TOP。
紙面、スクリーン、看板、プロジェクション面の自動補正に使う。

実測（M2 / 640x426静止画）: 640x426へ補正出力し、正立画像・エラーなしを確認。

## 出力

補正済みBGRA8 TOP。出力解像度は自動、またはOutput Width / Heightで固定できる。

## パラメータ

| パラメータ | 内容 |
|---|---|
| Use VisionRect CHOP / Corner CHOP / Rectangle Slot | VisionRectの四隅を使用 |
| Top/Right/Bottom corners | 手動四隅（0〜1、左下原点） |
| Output Width / Height | 0で補正領域から自動決定 |
| Flip | TD入力の上下反転補正。既定On |

Info CHOPは`executes / submits / processes / process_ms / valid`。

## 注意

Corner CHOPにはVisionRect CHOPの`rect{i}/tl:u`等のチャンネル名を想定する。
入力や四隅が変わった次のcookで非同期更新される。

## ビルド

```sh
./build.sh
```
