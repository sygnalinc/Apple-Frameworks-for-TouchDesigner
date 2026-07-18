# Vision Barcode DAT

Apple VisionでQRコードと各種1D/2Dバーコードを検出するDAT。追加モデル不要。

出力列は`index / symbology / payload / confidence / u / v / width / height /`
`tl_u / tl_v / tr_u / tr_v / br_u / br_v / bl_u / bl_v`。座標は0〜1・左下原点で、
複数コードは中心uの左→右順。

| パラメータ | 内容 |
|---|---|
| TOP | 入力TOP |
| Active | 検出On/Off |
| Max Codes | 出力上限。既定10、内部上限100 |
| Minimum Confidence | 最低信頼度 |
| Flip Image Vertically | 既定On |

Info CHOPは`executes / submits / analyzes / analyze_ms / codes`。payloadを文字列化できない
バイナリコードではpayloadが空になる。推論は非同期で、パラメータ変更時は静止画も再解析する。

## ビルド

```sh
cd VisionBarcode && ./build.sh
```
