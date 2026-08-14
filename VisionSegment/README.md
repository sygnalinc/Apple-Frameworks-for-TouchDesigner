# Vision Segment TOP — person segmentation (macOS)

入力 TOP の映像から人物マスクを生成する TD ネイティブのカスタム TOP。
Windows+NVIDIA 専用の **Nvidia Background TOP の macOS 代替**を想定。
Apple Vision のオンデバイス推論（Neural Engine）で、モデルDL・外部ランタイム不要。

実測（M2 / 1252x736 入力）: cook 非ブロックの非同期推論（結果は1〜2フレーム遅れ）。

## モード

| Mode | 使用API | 出力 |
|---|---|---|
| **Person Mask** | `VNGeneratePersonSegmentationRequest` | 人物領域の統合マスク（Mono 8bit・0〜1）。背景ぼかし・切り抜き向け |
| **Instance Masks (RGBA)** | `VNGeneratePersonInstanceMaskRequest`（macOS 14+） | 人物ごとのマスクを R/G/B/A 各チャンネルに分離（**最大4人**・API上限。5人以上は近い人物に統合される） |

Instance の各チャンネルは Channel Mix / Reorder TOP で個別マスクとして取り出せる。

## パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| Active | On | 推論の有効/無効 |
| Mode | Person Mask | 上記モード切替 |
| Quality | Balanced | Person Mask の品質（Fast / Balanced / Accurate。解像度と負荷が変わる） |
| Flip Image Vertically | **On** | TD の TOP ダウンロードは上下逆（bottom-up）のため既定 On。通常触らない |

## 出力解像度について

出力は Vision のマスクネイティブ解像度（入力より低い。例: 1252x736 入力 → Balanced で 512x384）。
入力と合成するときは Fit TOP 等で入力解像度に合わせる（マスクなので拡大品質の影響は小さい）。

Info CHOP（動作診断）: `executes / submits / analyzes / mask_w / mask_h`。

## ビルド

```
./build.sh    # → build/VisionSegmentTOP.plugin
```

使い方は [ルート README](../README.md) 参照（CPlusPlus TOP でロード or Plugins フォルダへ）。
