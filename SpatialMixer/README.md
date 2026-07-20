# Spatial Mixer CHOP

多チャンネル(サラウンドベッド)入力を、各チャンネルを**標準スピーカー位置**に配置したモノ音源として
**AVAudioEnvironmentNode** でバイノーラル(HRTF)にレンダし、ステレオCHOPで返す。5.1/7.1/Quad/Stereo
のサラウンドをヘッドホン用に空間ダウンミックスする用途。

- 音声は**TDに戻る**(出力 left/right)
- `Input Layout` で入力chの意味(Stereo / Quad / 5.1 / 7.1 / Auto)を指定し、各chを標準角度に配置
- 各chは独立した positioned mono source として env node に流れる

> 実装ノート: `kAudioUnitSubType_SpatialMixer`('3dem')の多ch生設定は manual rendering で不安定
> (実測 segfault)。実証済みの AVAudioEnvironmentNode + チャンネル毎 positioned source で
> 同等の空間ミックスを堅牢に実現している。

## 実測(M2)

- ステレオ(ch0=左-30°大 / ch1=右+30°小)→ **rmsL/rmsR=1.14**(大きいスピーカーch側へ寄る)。
  エラーなし

## 標準レイアウト(チャンネル順)

| Layout | 角度(azimuth, +right) |
|---|---|
| Stereo | L -30, R +30 |
| Quad | L -45, R +45, Ls -135, Rs +135 |
| 5.1 | L -30, R +30, C 0, LFE 0, Ls -110, Rs +110 |
| 7.1 | L -30, R +30, C 0, LFE 0, Lrs -135, Rrs +135, Ls -90, Rs +90 |
| Auto | チャンネル数で自動(該当なしは円周等間隔) |

## 出力(CHOP)

`left` / `right`。Info CHOP: `executes / renders / sources / ready`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Input Layout | 入力chの意味(スピーカー配置) |
| Speaker Distance | 各スピーカーの距離 |
| Rendering Algorithm | HRTF / HRTF HQ / Spherical Head |
| Output Type | Headphones / External Speakers |
| Listener Yaw / Reverb / Gain | 向き / リバーブ / ゲイン |

## 注意

- 単一のモノ点源を自由配置したいなら [Spatial Audio](../SpatialAudio/) を使う
- timeslice オーディオフィルタ。多音源で共有読み取り位置を使うとプル順で壊れるため、音源ごとに
  独立した read position を持つ

## ビルド

```
cd SpatialMixer && ./build.sh
```
