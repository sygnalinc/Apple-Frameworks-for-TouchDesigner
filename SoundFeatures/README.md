# Sound Features CHOP

Audio CHOPをAccelerate/vDSPで非同期解析し、映像・照明制御向けの音響特徴量を出力する。

実測（M2 / 44.1kHz・440Hz正弦波・FFT 2048）: RMS 0.707、peak 1.0、
centroid 440.0Hz、rolloff 452.2Hz。

## 出力

`rms / peak / db / zcr / centroid / rolloff / flux / onset / beat / bpm / bass / mid / high`
と、対数配置した`band0`〜`band15`。すべて1サンプル。

## パラメータ

FFT Sizeは2の指数（既定11=2048）、Onset Thresholdはspectral fluxの判定閾値。
Info CHOPは`executes / analyzes / analyze_ms / samplerate / fft_size`。

## 注意

BPMはonset間隔からの軽量推定で、一定テンポの打楽器を想定する。厳密な楽曲解析器ではない。

## ビルド

```sh
./build.sh
```
