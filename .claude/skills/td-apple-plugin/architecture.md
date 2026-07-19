# 実装の型(全プラグイン共通アーキテクチャ)

新規プラグインはこの型に必ず従う。既存プラグイン(例 `VisionPose/VisionPoseCHOP.mm`)が
生きた実例。

## 1. 推論は非同期ワーカースレッドで

- cook(`execute`)は絶対にブロックしない。重い処理(Vision/Core ML推論、`getData()`、
  GPU完了待ち、ファイルI/O)は全てワーカースレッドへ投げる
- 結果は **1〜2フレーム遅れで最新値を出力**する(latestバッファ + mutex/atomic)
- **busyフラグで多重投入を防ぐ**。前回の推論が終わるまで次を投げない(フレームが詰まる)
- 典型構成: cook側は「入力を1枚コピー → busyでなければワーカーにsubmit → latest結果を出力」
  だけ。ワーカー側が「推論 → latestへ書き込み → busy解除」

```
cook():
  if 入力が更新された && !busy:
    入力をコピーしてキューへ; busy = true; submits++
  latest結果を出力チャンネル/テクスチャへ書く
  executes++

worker loop:
  キューから取り出し; 推論; latest = 結果; analyzes++; busy = false
```

## 2. TOP入力の取得

- `inputs->getParTOP()` / `inputs->getInputTOP()` → `downloadTexture()` でCPUへ落とす
- `downloadTexture()` の**戻りを受けての `getData()` はブロックする**ので、ダウンロード発行は
  cook、実データ参照は**ワーカー側**で。busyフラグで多重ダウンロードを防ぐ

## 3. TOP download の flip — Vision/ML意味処理系のみ

**これが最頻出の事故ポイント。**

- TDのGLテクスチャは bottom-up。**Vision/Core ML など「向きに意味がある推論」は
  `BGRA8Fixed` + `verticalFlip=true` でダウンロードしないと検出0になる**
- flip は `Flip` トグル(既定On)としてユーザーに露出する
- **向きに依存しない幾何処理(Metal Upscale / Metal FrameInterp の補間・拡大)は flip を持たない**
  (`verticalFlip=false` 固定・出力もそのまま)。片側だけ flip すると出力が上下逆になる
- 判定基準: **正立画像でないと検出/推論が劣化するか?** Yes→flip必要(Vision全部・CoreML)。
  No→flip不要(Upscale/FrameInterp等の幾何変換系)

## 4. TOP出力(CPUMem)の行反転

- Vision系の出力座標は top-down。**出力テクスチャは行反転してアップロード**する
- **downloadのflipと出力の再反転は必ず対で行う**(片方だけだと上下逆)。
  CoreMLのように入力flip+出力再反転が対になっていれば整合。Upscaleのように両方持たなければ整合

## 5. Info CHOP 診断チャンネルを必ず出す

- `executes`(cook回数)・`submits`(ワーカー投入数)・`analyzes`(推論完了数)等
- **`analyzes` が `executes` に追従 = フレーム落ちなし**。詰まっていれば差が開く
- ステータス文字列(loading / busy / unavailable 理由)は Info DAT で返す(クラッシュさせない)

## 6. cookEveryFrameIfAsked と「出力を使わないとcookされない」

- 基本 `cookEveryFrameIfAsked = true`
- **TDは出力がどこかで使われていないとcookしない**。音声/翻訳系は「音が流れない」
  「進まない」に見える。テスト時は `chopexecuteDAT` / `datexecuteDAT` で監視して毎フレームcookさせる
- 逆に、毎フレーム重い再生成をしたくないもの(AI生成等)は、AI busy中のみ
  `cookEveryFrameIfAsked` をOnにする等で暴走を防ぐ

## 7. 静止画入力の再解析

- 静止画入力では `totalCooks` が変わらず、同じフレームを再解析しない
- **処理系パラメータ(Mode等)の変更を signature 検知**して `myLastCookSeen = -1` にし、
  再投入する。全TOP/CHOPにこの型を入れてある(Keystone/Bokeh/Similarity/MPS等)
- signature には**効く全パラメータ**を含める(Prompt/Seed/Composer を入れ忘れて再生成されない罠)

## 8. 複数検出のスロット出力

- `body{i}/` `hand{i}/` `face{i}/` `animal{i}/` `rect{i}/`(**1始まり**)+ `:valid`
- 並びは基本 **左→右ソート**(VisionPoseのみ最近傍マッチの永続 trackingid)
- スロット上限は定数(例 `kMax=100`)。UIスライダーは控えめ(10まで)、既定値も控えめ
- **CHOPは0ch出力を嫌う**。検出前(チャンネル未確定)は1ch(`connected` 等)のダミーを出す。
  `getOutputInfo` でチャンネル名スナップショットを固定し、`getChannelName`/`execute` と整合させる

## 9. 座標系

- Visionの座標は **0〜1・左下原点**。TDのuv系と同じなので無変換で整合
- 例外あり。**SAM2(Apple Core ML版)のプロンプト座標は1024×1024ピクセル空間**。
  TD uv → `x=u*1024, y=(1-v)*1024`(正規化のまま渡すと常に左上が選ばれる)

## 10. Swift専用APIのラップ

ObjC++から直接呼べないSwift専用API(SpeechAnalyzer / FoundationModels / Translation /
ml-stable-diffusion / ImageCreator / SpeechDetector / PhotogrammetrySession / ShazamKit /
WhisperKit)は、helperを dylib 化して C ABI で繋ぐ。詳細は [build.md](build.md)。

- 状態の受け渡しは **poll方式のJSON**(status / busy / result)+ 必要ならバイト列コピー関数
- `@_cdecl` でCエクスポート、ハンドルは `Unmanaged.passRetained().toOpaque()`
- 古いOS向けは `@available` ガード + status文字列で理由を返す(クラッシュさせない)
