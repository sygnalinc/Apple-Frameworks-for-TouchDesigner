# Vision IterSeg TOP

**Apple純正の対話的セグメンテーション**(macOS 27+・`GenerateIterativeSegmentationRequest`)。
プロンプト(点/矩形/**なぞり書き**)を与えると任意物体のソフトマスクを返す。
**外部モデル不要**(CoreML SAM2 の純正代替。モデルはOSが管理するダウンロード資産)。

> **状態: 実験中(macOS 27+)。** DMG には含まれません(`PLUGINS.tsv` が唯一の正)。
> 3つのプロンプト経路は実データで確認済みですが、macOS 27 が beta のため released には上げていません。

- 入力0 = 画像、入力1 = scribbleマスク(Prompt Mode=Scribble のとき。Rチャンネルを使用)
- 出力 = Mono32Float ソフトマスク
- プロンプト座標は **TDのuvと無変換で一致**(Vision の既定 lowerLeft 原点)
- 初回のみ `Download Assets` パルスでモデル取得(OS全体で共有キャッシュ・以後不要)

## 実測(M2・macOS 27.0・640×426)

| 項目 | 値 |
|---|---|
| 点プロンプト | 群衆写真から指定人物1人を正確にマスク(2箇所で座標一致を確認) |
| box プロンプト | 矩形内の人物をマスク |
| scribble プロンプト | Circle TOP で描いた軌跡から該当人物をマスク |
| 解析時間 | 1〜2秒/回(balanced・非同期でcookは非ブロック) |
| アセットDL | 初回のみ数分(OS管理・全アプリ共有) |

## パラメータ

| 名前 | 説明 |
|---|---|
| Active | On/Off |
| Prompt Mode | Seed Point / Seed Box / Scribble (Input 1) |
| Seed Point (uv) | 点プロンプト(0..1) |
| Box Position / Size (uv) | 矩形プロンプト(左下原点) |
| Quality | Fast / Balanced / Accurate |
| Download Assets | モデル資産のダウンロード(初回のみ) |
| Flip Vertically | TD正立用(既定On) |

Info CHOP: `executes / submits / results / busy / asset_ready`(0=未取得/2=取得中/1=準備完了)。
プロンプト・画質・入力の変更で自動再解析(静止画でもパラメータ変更検知で再投入)。

## 注意

- **macOS 27以降必須**。26以前では Warning に理由が出る(クラッシュしない)
- モデル未取得のまま解析すると失敗する。`asset_ready` を確認して `Download Assets` を先に
- scribble は入力1の**Rチャンネル**をなぞり書きとして解釈(白=指定)

## ビルド

```bash
./build.sh   # → build/VisionIterSegTOP.plugin
```
