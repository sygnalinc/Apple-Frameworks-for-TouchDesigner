# Vision Face CHOP — 顔検出+ランドマーク（macOS）

TOP の映像から複数の顔（`VNDetectFaceLandmarksRequest`）を検出する
TD ネイティブのカスタム CHOP。Windows+NVIDIA 専用 Face Track CHOP の macOS 代替を想定
（チャンネル形式は独自）。

## 出力チャンネル（Max Faces = N・各 16ch / Landmarks 有効時 168ch）

| チャンネル | 内容 |
|---|---|
| `face{i}:valid` | 検出できたか（1/0） |
| `face{i}/bbox:u,v,width,height` | 顔バウンディングボックス（中心+サイズ・0〜1） |
| `face{i}/roll` `yaw` `pitch` | 顔の向き（ラジアン。**取得できない軸は 0**） |
| `face{i}/left_eye:u,v` `right_eye` `nose` `mouth` | 主要ランドマークの中心（画像正規化座標） |
| `face{i}/p{0..75}:u,v` | Landmarks オン時のみ・全76ランドマーク点 |

face の並びは bbox 中心の x で左→右にソート。

## パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| TOP | — | 解析する映像の TOP パス |
| Active | On | 解析の有効/無効 |
| Max Faces | 5 | 検出する顔の最大数（**1〜100**・スライダー表示は10まで） |
| All Landmark Points (76) | Off | 全76点を p0..p75 として出力（チャンネル数が増える） |
| Flip Image Vertically | **On** | TD の TOP ダウンロードは上下逆のため既定 On |

## 注意

- **Face Capture Quality**(トグル・既定Off): Onで `face{i}/quality`(0〜1の顔写り
  スコア・VNDetectFaceCaptureQualityRequest)が roll/yaw/pitch の後に追加される。
  フォトブースの「ベスト表情自動選択」に。Offなら従来とチャンネル互換

- 顔が小さい（引きの全身ショット等）と検出が不安定。バストアップ程度の画角が確実
- **絵に描かれた顔（Tシャツのプリント等）も顔として検出しうる**（Vision の仕様）
- 実測: 顔写真で bbox・目/鼻/口の位置関係が正しく出力されることを確認

Info CHOP: `executes / submits / analyzes`。ビルドは `./build.sh`。
