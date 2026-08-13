# PHASE CHOP

Apple **PHASE**(Physical Audio Spatialization Engine)で入力オーディオを**物理ベースに空間化**し、
システム出力(ヘッドホン)へ再生する。ドライ入力はそのまま出力へパススルーし、空間化版はデバイスで鳴る。

> **重要な制約**: PHASE は**出力バッファ取得APIが無く**(`start`/`stop` でデバイスへ直接再生)、
> レンダ結果を**TDに戻せない**。したがってこれは「TD入力→PHASE定位→デバイス再生」の**再生プラグイン**。
> 空間化した音声を録音・後段処理したい場合は [Spatial Audio](../SpatialAudio/)(バイノーラルをTDに戻す)を使う。

- 物理ベースの定位・距離減衰・幾何音響パイプライン(Direct Path / Early Reflections / Late Reverb)
- 位置(方位/仰角/距離)をTDから制御
- `PHASEPullStreamNode` の renderBlock は**リアルタイムスレッド**なので、cookとの受け渡しは
  ロックフリーの SPSC リングバッファで行う

## 実測(M2)

- 440Hzトーンを入力・Play=On → `playing=1` / `buffered=8820` / `rendering=1`(PHASEエンジン稼働・
  デバイスへ再生)。TDクラッシュなし
- 出力バッファ非取得のため、音の視覚検証はできない(ヘッドホンで聴く)

## 使い方

1. オーディオCHOP(モノ)を入力に接続
2. `Direct Path`(+必要なら Early Reflections / Late Reverb)を選び、`Azimuth`/`Distance` を設定
3. **Play** をOn → ヘッドホンに物理ベース空間化された音が鳴る。位置パラメータを動かすと定位が動く

## 出力(CHOP)

ドライ入力のパススルー(= 入力と同じ)。Info CHOP: `executes / playing / buffered / underruns / rendering`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Active / Play | エンジン有効 / デバイス再生の開始停止 |
| Azimuth / Elevation / Distance | 音源位置 |
| Gain | 出力ゲイン(renderBlockで適用) |
| Direct Path / Early Reflections / Late Reverb | 空間パイプラインの構成(物理音響) |

## 注意

- **音声はTDに戻らない**。out はドライ入力のパススルー、空間化版はデバイス出力
- スクラブや強制cook時は実時間供給が途切れ underruns が増える(通常の連続再生では安定)
- パイプライン構成(Direct/Early/Late)を変えるとエンジンを再構築する

## ビルド

```
cd Phase && ./build.sh
```
