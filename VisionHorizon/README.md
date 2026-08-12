# Vision Horizon CHOP

**English** | [日本語](#日本語)

## English

Detects the tilt of the horizon in an image with Vision's `VNDetectHorizonRequest`. Useful for
automatic levelling of a camera, or for driving the "gravity" direction of UI and particles.

### Output

`valid`, `angle` (radians), `angledeg`, `transform/a,b,c,d`, `confidence`. The linear part of
Vision's corrective affine transform is preserved as well.

### Parameters

TOP, Active, Flip Image Vertically (default On). Detection is asynchronous and the Info CHOP
reports executes/submits/analyzes/analyze_ms/valid.

### Notes

An image with no clear horizontal structure gives valid = 0. On M2 with a simple 640x360 gradient
input, the first analysis took about 37.7 ms and the request completed normally with valid = 0 (no
horizontal structure). Angular accuracy on real footage is unverified.

### Build

`./build.sh` → `build/VisionHorizonCHOP.plugin`

## 日本語

Visionの`VNDetectHorizonRequest`で画像の水平線/地平線の傾きを検出する。カメラの自動水平補正、UIやパーティクルの重力方向制御に使える。

### 出力

`valid`, `angle`（rad）, `angledeg`, `transform/a,b,c,d`, `confidence`。Visionの補正用affine transformの線形成分も保持する。

### パラメータ

TOP、Active、Flip Image Vertically（既定On）。検出は非同期で、Info CHOPにexecutes/submits/analyzes/analyze_ms/validを出す。

### 注意

明確な水平構造がない画像ではvalid=0。M2/640x360の単純gradient入力では初回解析約37.7ms、要求は正常完了しvalid=0（水平構造なし）を確認した。実写の角度精度は未検証。

### ビルド

`./build.sh` → `build/VisionHorizonCHOP.plugin`
