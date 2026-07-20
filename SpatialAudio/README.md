# Spatial Audio CHOP

モノ音源を **AVAudioEnvironmentNode** で3D空間に配置し、**HRTFバイノーラル**のステレオCHOPとして返す。
入力オーディオCHOP(モノ)を `AVAudioSourceNode` でエンジンへ供給し、`AVAudioEngine` の
**manual rendering(offline)** で1ブロックずつレンダしてTDのオーディオグラフに戻す。

- 音声は**TDに戻る**(出力 left/right を Audio Device Out 等へ送れる)
- 位置は極座標(方位/仰角/距離)または直交(XYZ)。HRTF/HRTF HQ/球面頭部/等パワーパンを選択
- 距離減衰・リバーブ・リスナー向き・オクルージョンに対応

## 実測(M2)

- 440Hzモノトーンを方位 -90°(左)→ **rmsL/rmsR=1.67**、+90°(右)→ **0.64**。定位が正しく反転
- HRTFバイノーラルがTDのオーディオグラフ内で動作

## 使い方

1. モノのオーディオCHOP(Audio File In / Audio Device In 等)を入力に接続
2. `Position Mode`=Polar で `Azimuth`/`Elevation`/`Distance` を設定(または Cartesian で X/Y/Z)
3. 出力 `left`/`right` を Audio Device Out(または Audio CHOP チェーン)へ

## 出力(CHOP)

`left` / `right`(バイノーラル・timeslice)。Info CHOP: `executes / renders / samplerate / ready`

## パラメータ(主要)

| パラメータ | 説明 |
|---|---|
| Position Mode | Polar(方位/仰角/距離)/ Cartesian(XYZ) |
| Azimuth / Elevation / Distance | 極座標位置 |
| Rendering Algorithm | HRTF / HRTF HQ / Spherical Head / Equal Power |
| Output Type | Headphones(バイノーラル)/ External Speakers |
| Listener Yaw / Pitch | リスナーの向き |
| Distance Attenuation / Ref / Max Distance | 距離減衰 |
| Reverb Blend / Occlusion / Gain | リバーブ / 遮蔽 / 出力ゲイン |

## 注意

- **オーディオフィルタCHOPは timeslice**。入力の現在ブロックを処理してN samples出力する
- モノ入力→2ch出力なので `getOutputInfo` は `true`+numChannels=2 を返す(falseだと入力=1chに一致し
  クラッシュする)
- 多ch入力はモノに平均して1点源として扱う。多点源のサラウンドは [Spatial Mixer](../SpatialMixer/) を使う

## ビルド

```
cd SpatialAudio && ./build.sh
```
