# Vision Pose 3D CHOP — 単一人物の3Dポーズ推定（macOS 14+）

TOP の映像から**最も目立つ1人**の3Dボディポーズ（17関節・メートル単位）を推定する
TD ネイティブのカスタム CHOP。`VNDetectHumanBodyPose3DRequest` を使用。

2D複数人の [VisionPose CHOP](../VisionPose/)（Body Track 互換・60fps）と対になる単一人物・3D版。

## 性能特性（重要）

| | 値（M2・1252x736入力） |
|---|---|
| 初回解析 | **約17秒**（3Dモデルの初回ロード/コンパイル。以後は速い） |
| 定常解析 | **約0.5秒/フレーム（≒2fps）** |

リアルタイムの毎フレーム用途には向かない。姿勢の判定・計測・スナップショット的な
用途向け（cook はブロックしない非同期実行なので、TD のフレームレートは落ちない。
チャンネル値が約0.5秒間隔で更新される、という動き方になる）。

## 出力チャンネル（91ch）

| チャンネル | 内容 |
|---|---|
| `valid` | 検出できたか（1/0） |
| `bodyheight` | 推定身長（メートル） |
| `heightestimation` | 0=reference（既定身長から推定）/ 1=measured（実測。LiDAR等の深度がある場合） |
| `camera:tx,ty,tz` | カメラ位置（メートル・シーン原点基準） |
| `{joint}:tx,ty,tz` | 関節の3D位置（メートル・**シーン原点=人物root**・y上向き） |
| `{joint}:u,v` | 関節の入力画像への2D投影（0〜1・左下原点） |

17関節: `root spine center_shoulder center_head top_head
left_shoulder left_elbow left_wrist right_shoulder right_elbow right_wrist
left_hip left_knee left_ankle right_hip right_knee right_ankle`

座標系: 人物の root（腰）がシーン原点。例: 直立時は `top_head:ty ≈ +0.77`、
`right_ankle:ty ≈ -0.87`（身長1.8m推定時）。カメラとの距離・向きは `camera:*` から分かる。

## パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| TOP | — | 解析する映像の TOP パス |
| Active | On | 解析の有効/無効 |
| Flip Image Vertically | **On** | TD の TOP ダウンロードは上下逆（bottom-up）のため既定 On |

Info CHOP（動作診断）: `executes / submits / analyzes / analyze_ms`（1解析の所要ms）。

## ビルド

```
./build.sh    # → build/VisionPose3DCHOP.plugin（要 macOS 14+）
```

使い方は [ルート README](../README.md) 参照（CPlusPlus CHOP でロード or Plugins フォルダへ）。
