# Shazam DAT

**自作音源のオフライン照合**(ShazamKit・macOS 12+)。Reference Folder の音声ファイル群
からカスタムカタログを構築し、Audio CHOP のライブ音声が**どの曲の何秒目か**を判定する。
「会場音源にショー進行を同期」「かかった曲で演出切替」に使える。
カスタムカタログ照合は**完全オンデバイス**(ネットワーク・エンタイトルメント不要)。

## 実測(M2)

- TD同梱mp3をカタログ化(数秒)→ 同曲再生で **matched=1・title・offset=29.06秒**
  (曲内位置まで特定)・skew≈0 を確認。マッチ確定まで数秒ぶんの音声が必要

## 使い方

1. Reference Folder に基準音源(wav/mp3/m4a/aif)を置く。曲名=ファイル名になる
2. Build Catalog をパルス(数秒/曲)
3. Audio CHOP にライブ音声(マイクや SystemAudio CHOP)を指定 → 自動照合

## 出力テーブル(key/value)

`status / matched / title / offset(曲頭からの秒)/ skew(再生速度ずれ)/ tracks`
数値は Info CHOP(`matched / offset / tracks`)からも取れる。

## 注意

- offset は「マッチした瞬間の曲内位置」。連続再生中は定期的に更新される
- 静かな部分・効果音のみの区間はマッチしないことがある(音楽的な特徴が必要)
- Shazam公式カタログ(世界中の楽曲)との照合はエンタイトルメントが必要なため未対応
  (カスタムカタログ専用)

## ビルド

```
cd Shazam && ./build.sh   # → build/ShazamDAT.plugin(Swiftヘルパdylib同梱)
```
