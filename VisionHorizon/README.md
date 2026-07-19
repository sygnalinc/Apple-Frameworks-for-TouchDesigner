# VisionHorizon CHOP

Visionの`VNDetectHorizonRequest`で画像の水平線/地平線の傾きを検出する。カメラの自動水平補正、UIやパーティクルの重力方向制御に使える。

## 出力

`valid`, `angle`（rad）, `angledeg`, `transform/a,b,c,d`, `confidence`。Visionの補正用affine transformの線形成分も保持する。

## パラメータ

TOP、Active、Flip Image Vertically（既定On）。検出は非同期で、Info CHOPにexecutes/submits/analyzes/analyze_ms/validを出す。

## 注意

明確な水平構造がない画像ではvalid=0。M2/640x360の単純gradient入力では初回解析約37.7ms、要求は正常完了しvalid=0（水平構造なし）を確認した。実写の角度精度は未検証。

## ビルド

`./build.sh` → `build/VisionHorizonCHOP.plugin`
