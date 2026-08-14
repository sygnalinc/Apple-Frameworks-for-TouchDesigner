# CI Enhance TOP

Core Imageの`autoAdjustmentFilters`が画像内容に応じて露出、彩度、コントラスト、色かぶり等の補正filterを自動選択するTOP。追加モデル不要。

## 出力・診断

入力TOPをBGRA8で非同期処理して出力する。Red Eye Correction、Auto Crop、Auto Level、Flipを選択可能。Info DATに実際に適用したfilter名、Info CHOPにfilter数と処理時間を出す。

## 注意

画像によってfilterが0件になるのは正常。Auto Cropを有効にすると出力解像度が変わる場合がある。Core Imageを使う他pluginとはプロセス横断で処理を直列化する。M2/640x360 gradient入力で2 filters、約32.1ms、正立出力を視認した。

## ビルド

`./build.sh` → `build/CoreImageEnhanceTOP.plugin`
