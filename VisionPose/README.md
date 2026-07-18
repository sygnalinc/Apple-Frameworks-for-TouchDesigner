# Vision Pose CHOP — TouchDesigner カスタムオペレータ（macOS）

TOP の映像を Apple Vision（`VNDetectHumanBodyPoseRequest`）で多人数ボディポーズ推定し、
**TD 標準の Body Track CHOP（NVIDIA・2D複数人）と同一のチャンネル形式**で出力する
TD ネイティブのカスタム CHOP。外部アプリ・OSC・追加ランタイム不要で TD 内で完結し、
Windows+NVIDIA 専用の Body Track CHOP を macOS で置き換えるドロップイン用途を想定。

チャンネルレイアウトは実機の Body Track CHOP 出力（bclip サンプル）と突き合わせて
**チャンネル名・順序とも完全一致**を確認済み（Rotations 有効時 1680ch / 無効時 864ch・8体時）。

実測（M2 / 1252x736 / 5人）: 解析が cook と 1:1 で追従（60fps・フレーム落ちなし）。
処理はワーカースレッドで非同期実行され、cook をブロックしない（結果は1〜2フレーム遅れ）。

## 使い方

**方法A: CPlusPlus CHOP でロード（手軽・再起動不要）**
1. CPlusPlus CHOP を作成し、Plugin Path に `build/VisionPoseCHOP.plugin` を指定
2. カスタムパラメータページ「Vision Pose」で `TOP` に映像ソースを指定

**方法B: カスタムOPとしてインストール（`Visionpose` オペレータになる）**
```
mkdir -p ~/Library/Application\ Support/Derivative/TouchDesigner099/Plugins
cp -R build/VisionPoseCHOP.plugin ~/Library/Application\ Support/Derivative/TouchDesigner099/Plugins/
# TD を再起動 → OP Create Dialog の CHOP に「Vision Pose」が現れる
```

## パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| TOP | — | 解析する映像の TOP パス |
| Active | On | 解析の有効/無効 |
| Max Bodies | 8 | 出力する body 枠数（1〜8。チャンネル数が変わる） |
| Rotations (layout only) | Off | Body Track の Rotations と同じ rx/ry/rz チャンネルを出す（**値は常に0**・レイアウト互換用） |
| Flip Image Vertically | **On** | TD の TOP ダウンロードは上下逆（bottom-up）なので既定 On。通常触らない |

## 出力チャンネル（Body Track CHOP 2D 互換・body ごとに 108ch / Rotations 時 210ch）

| チャンネル | 内容 |
|---|---|
| `body{i}:valid` | トラッキング中か（1/0）。i は 1 始まり |
| `body{i}/bbox:u` `:v` `:width` `:height` | バウンディングボックス（中心+サイズ。信頼関節の外接矩形） |
| `body{i}/trackingid` | 永続ID（1始まり。フレーム間の最近傍マッチで維持 = People Tracking 相当） |
| `body{i}/{kp}:u` `:v` `:confidence` | 34キーポイント（0〜1・左下原点） |
| `body{i}/{kp}:rx` `:ry` `:rz` | Rotations 有効時のみ。**Vision では取れないため常に 0** |

34キーポイント（Maxine 準拠の名前・順序）: `pelvis left_hip right_hip torso left_knee right_knee
neck left_ankle right_ankle left_big_toe right_big_toe left_small_toe right_small_toe
left_heel right_heel nose left_eye right_eye left_ear right_ear left_shoulder right_shoulder
left_elbow right_elbow left_wrist right_wrist left_pinky_knuckle right_pinky_knuckle
left_middle_tip right_middle_tip left_index_knuckle right_index_knuckle left_thumb_tip right_thumb_tip`

Vision に無いキーポイントの扱い（**confidence=0 で判別可能**）:
- つま先・かかと（big_toe/small_toe/heel）→ 同側の **足首の位置**を confidence 0 で出力
- 手指（pinky/middle/index/thumb）→ 同側の **手首の位置**を confidence 0 で出力
- `torso` → neck と root(pelvis) の中点（confidence は両者の低い方）

body スロットはトラッキングで維持される（人が入れ替わっても同じ人は同じ body{i}/trackingid に留まる。
ロストすると valid=0 になり、復帰時は空きスロットに新しい trackingid で入る）。

Info CHOP（動作診断）: `executes / submits / analyzes / last_w / last_h / last_bytes`。
`analyzes` が `executes` に追従していればフレーム落ちなし。

## ビルド

```
./build.sh    # → build/VisionPoseCHOP.plugin（要 Xcode。TD の C++ SDK ヘッダはTD.app内のものを参照）
```

## VisionPoseOSC アプリとの使い分け

- **この CHOP**: TD 内で完結。TOP をそのまま解析でき、チャンネルとして直接使える（推奨）
- **VisionPoseOSC.app**: TD 外で動かしたい場合（負荷分離・別マシン・TD 以外への配信）や、
  プレビュー/スケルトン表示・NDI/カメラ入力・OSC 配信が必要な場合
