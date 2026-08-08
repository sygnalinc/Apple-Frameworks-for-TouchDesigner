# 症状別トラブルシュート

実際に踏んだものだけ。上から順に確認する。

## OP が Create Dialog に出ない / "Unknown operator type"

0. **起動時の許可ダイアログを閉じてしまっていないか。** TD は新しいプラグインごとに
   許可を求め、その結果を `Plugins.json` に記録する。許可しなかったものは登録されない
1. `.plugin` を `~/Library/Application Support/Derivative/TouchDesigner099/Plugins/` に
   置いたか。置いた**あと TouchDesigner を再起動**したか(起動時にしか走査しない)
2. 12個以上を一度に入れ替えた直後の初回起動は**再検証で数分かかる**。2回目以降はキャッシュで通常速度。
   固まったように見えたら強制終了 → 再起動でよい
3. 古い `.toe` が削除済み/改名済みの opType を参照していると赤くなる。該当ノードを新しい型で貼り直す

## "provides an invalid opType name"

**opType 文字列が正しくてもこのエラーは出る。** 真因はたいてい
**TouchDesigner 本体と .plugin の SDK バージョン不一致**。TDのバージョンを上げ下げすると、
古い/新しいSDKでビルドされたバンドルが混在して一部だけ拒否される。

→ 該当プラグインを**今の TouchDesigner でビルドし直す**。
自分でビルドしないなら、TDのバージョンに合ったリリースを使う。

## TOPが黒いまま

| 状況 | 原因 | 直し方 |
|---|---|---|
| 一度 bypass / 無効化して戻したら黒い | 古いバージョンのバグ | 最新の `.plugin` に更新する(修正済み) |
| Vision Flow が常に黒い | 入力が静止 / UVモードは値が極小 | `Output` を `visualize` に。または Math TOP で増幅 |
| 静止画入力で何も起きない | 入力が更新されないと再解析されない | パラメータを一度変える(変更検知で再投入される) |
| そもそも cook されていない | 出力が誰にも使われていない | Null + ビューア、または Execute DAT で毎フレーム cook |

## 検出0になる

1. **チャンネル名の区切りを間違えていないか。** スロット直下は**コロン**(`body1:valid`)。
   `body1/valid` は存在しない
2. **`Flip Image Vertically` を Off にしていないか。** Vision系は既定 On が正しい。
   Off にすると検出0になる
3. **被写体が小さすぎないか。** 顔・手は引きの画角だと不安定。寄るか Crop で拡大する
4. **連続フレームが要るOPではないか。** Vision Track / Vision Trajectory は
   間隔を空けた force cook では成立しない。実時間で再生しながら確認する
5. Vision AnimalPose の学習対象は**犬・猫**。他の動物は保証されない

## 骨格線・オーバーレイが描画されない

- **outPOP の render / display フラグ**が立っているか(このTDは POP 世代)
- Script SOP の `Trigger` に元CHOPの `totalCooks` の式が入っているか
  (入力が無いSOPは毎フレーム cook しない)
- Geometry COMP に既定の `torus1` が残っていないか
- Render TOP の `geometry` に対象の Geo が含まれているか

## uv が映像とズレる / 縦に伸びる

`Aspect Correct UVs` が Off のまま。On にして、カメラを **Ortho・Ortho Width = 1**、
インスタンスの tx/ty を `u-0.5` / `v-0.5` にする。

逆に「Crop TOP に渡したいのに値がおかしい」なら、Off に戻す(生の画像座標が要る)。

## 音がノイズ / 早送りに聞こえる

音声を生成して出すCHOPで、実時間より速く読み出されている状態。
最新の `.plugin` で修正済み(Speech Synth で実際にあった)。更新して直らなければ Issue へ。

## 音声・翻訳・LLM が進まない

出力が使われていないと cook されないため。Null + ビューア、または Execute DAT の
`onFrameEnd` で毎フレーム cook させる。Info DAT の `status` も必ず見る。

## 急に重くなった

**重いML系OPの同時実行**。ANE の取り合いで数倍遅くなる(実測: YOLO 単独38ms → 同時262ms、
LLSR 4ms → 324ms)。使わないOPは `Active` を Off にする。

Vision Pose3D は仕様上遅い(初回モデルロード約17秒・定常0.5秒)。リアルタイム用途には使わない。

## モデルが読み込めない

- `models/README.md` のファイル名と**完全一致**しているか
- CoreML TOP/CHOP は初回に ANE コンパイルが走る。**数秒〜数分 `valid=0` のまま**なのは正常
  (SD2.1 で約2分、SDXL で10分超。2回目以降はキャッシュで速い)
- **モデルパスが変わらないと再ロードされない。** 差し替えたのに反映されないときは、
  パラメータを一度空にしてから設定し直す

## 解像度が頭打ちになる / 出力が崩れる

**Non-Commercial 版は 1280x1280 制限**。Metal Upscale・Cinematic Video・ImageIO File In・
CoreImage RAW/HDR・Screen Capture・PDFKit・CoreText が該当しうる。
このリポジトリは NC 環境で検証できていないので、出力解像度を下げて回避する。

## 権限で止まる

| OP | 必要な許可 |
|---|---|
| Screen Capture | 画面収録 |
| CA Process Tap | 音声入力系(初回にダイアログ) |
| Network Discovery / Multipeer | ローカルネットワーク |
| CoreWLAN Scan の SSID 取得 | 位置情報(同梱ヘルパー.app が要求) |
| Shortcuts / AppleScript | オートメーション(初回に「TouchDesignerが〜を制御しようとしています」) |

許可を出したあと **TouchDesigner の再起動が要る**ことがある(Screen Capture で実際にあった)。

## Shortcuts が「見つかりません」で失敗する

名前は合っているのに失敗する場合、原因は責任プロセス(TouchDesigner)の権限。
`Run Method` を **app**(既定・URLスキームで Shortcuts.app に委譲)にすると確実に動く。
ただし app 方式は**出力テキストを受け取れない**。値が要るなら cli 方式(TDに権限が要る)。

外部アプリを制御して結果も欲しいなら、**AppleScript DAT** のほうが素直
(正規の Automation 許可フローに乗る)。
