# Music Understanding DAT

**音楽ファイルのオンデバイス楽曲解析**(macOS 27+・Apple `MusicUnderstanding` framework)。
演出制御に直結する構造データをテーブル出力する:

> **状態: 実験中(macOS 27+)。** DMG には含まれません(`PLUGINS.tsv` が唯一の正)。
> 3曲で BPM / 調 / 構造の正検出を確認済みですが、macOS 27 が beta のため released には上げていません。

| 解析 | 出力 |
|---|---|
| Rhythm | **ビート/小節の時刻列 + BPM** |
| Key | 調(トニック17種+major/minor)の時間区間 |
| Structure | 楽曲構造: **セクション/セグメント/フレーズ**の時間区間 |
| Pace | ペース(時間区間+値) |
| Loudness | integrated / momentary / shortTerm / peak(EBU系ラウドネス) |
| Instruments | **楽器アクティビティ**(vocal / drum / bass / other の区間+レベル曲線) |

`File` 変更で自動解析。`Mode` メニューで出力テーブルを切替。要約(BPM/キー等)は
Summary テーブルと Info CHOP(`bpm / beats / bars / sections / busy / done`)に出る。

## 実測(M2・macOS 27.0・TD同梱テクノ曲 約70秒)

- **BPM 123・144ビート・36小節・5セクション・G minor** を正しく検出
  (ビート間隔 0.488s = 123BPM と整合)
- instruments: bass/drum等の区間+アクティビティ曲線(5650行)
- loudness: integrated −11.4 LUFS / peak −0.0 dB(1408行)
- 解析時間: 数十秒(非同期・cook非ブロック)

## 使い方の例

- ビート表 → Script CHOP / Lookup で**曲同期のトリガー生成**(事前解析なので揺れゼロ)
- セクション区間 → シーン切替のキューシート
- instruments のレベル曲線 → 擬似ステム(vocal/drum/bass/other)で演出をパート連動

## パラメータ

| 名前 | 説明 |
|---|---|
| Audio File | 解析する音楽ファイル(mp3/wav/m4a等・AVAssetが読める形式) |
| Output Table | Summary / Rhythm / Key / Structure / Pace / Loudness / Instruments |
| Analyze Rhythm〜Instruments | 解析セットのOn/Off(既定全On) |
| Reanalyze | 手動再解析 |

## 注意

- **macOS 27以降必須**。26以前では Warning に理由が出る(クラッシュしない)。
  フレームワークは weak link 済みなので26でもロード自体は安全
- DRM保護された曲(Apple Music のダウンロード等)は `hasProtectedContent` エラーになる
- ストリーミング入力(`audioProvider:` = ライブPCM解析)はAPIにあるが未実装(将来候補)

## ビルド

```bash
./build.sh   # → build/MusicUnderstandingDAT.plugin
```
