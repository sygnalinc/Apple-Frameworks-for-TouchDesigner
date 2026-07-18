# Vision Rect CHOP

Apple Visionで映像内の投影矩形を複数検出するCHOP。紙、カード、画面、看板などの
コーナーピン、射影補正、領域選択に使える。macOS 10.14以降。

各`rect{i}`に`valid / confidence / bbox:u,v,w,h / tl:u,v / tr:u,v / br:u,v / bl:u,v`
の14チャンネルを出力する。座標は0〜1・左下原点、複数矩形は中心uの左→右順。

| パラメータ | 内容 |
|---|---|
| TOP | 入力TOP |
| Active | 検出On/Off |
| Max Rectangles | 最大100、既定10 |
| Minimum/Maximum Aspect Ratio | 短辺÷長辺の範囲（0〜1） |
| Minimum Size | 画像短辺に対する最小辺比率 |
| Minimum Confidence | 最低信頼度 |
| Quadrature Tolerance | 直角から許容する角度（0〜45度） |
| Flip Image Vertically | 既定On |

Info CHOPは`executes/submits/analyzes/analyze_ms/rects`。推論は非同期で、静止画も
処理パラメータ変更時に再解析する。

## ビルド

```sh
cd VisionRect && ./build.sh
```
