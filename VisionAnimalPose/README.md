# Vision Animal Pose CHOP

Apple Visionの`VNDetectAnimalBodyPoseRequest`で犬・猫の2D姿勢を検出するCHOP。
macOS 14以降。複数検出は画面の左から右へ並べる。

## 出力仕様

Max Animalsの各スロットに80チャンネルを出力する。

- `animal{i}:valid`
- `animal{i}/bbox:u,v,w,h`（信頼度を満たす関節から算出）
- `animal{i}/{joint}:u,v,confidence`（25関節）

関節は耳6点、目2点、鼻、首、前脚6点、後脚6点、尾3点。座標は0〜1・左下原点。

## パラメータ

| 名前 | 内容 |
|---|---|
| TOP | 入力TOP |
| Active | 推論On/Off |
| Max Animals | 出力スロット数。内部上限100、スライダー表示10 |
| Minimum Joint Confidence | 未満の関節を0クリア。既定0.1 |
| Flip Image Vertically | 既定On。TDのTOP入力には必須 |

## Info CHOP

`executes / submits / analyzes / analyze_ms / animals`。

## 注意

- Appleの学習対象は犬・猫。ほかの動物での精度は保証されない
- 被写体が小さい、遮蔽が多い、横を向いている場合は関節が欠落しやすい
- 推論はワーカースレッドで非同期。結果は1〜2フレーム遅れる

## ビルド

```sh
cd VisionAnimalPose && ./build.sh
```
