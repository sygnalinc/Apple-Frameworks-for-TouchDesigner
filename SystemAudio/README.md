# SystemAudio CHOP

ScreenCaptureKitでmacOSのシステム音声をステレオAudio CHOPとして取得する。ScreenCapture TOPと同じdisplay indexを選ぶことで画面と音を併用できる。

## 出力

`left` / `right`、48 kHz、既定1024 samples。取得はOSコールバックで非同期に行い、cookは最新ブロックをコピーするだけで停止しない。

## パラメータ

| 名前 | 内容 |
|---|---|
| Active | 取得の開始/停止 |
| Display Index | 対象display |
| Block Samples | 64〜8192、既定1024 |
| Exclude Current App Audio | TouchDesigner自身の音を除外しフィードバックを防ぐ |
| Restart Capture | stream再生成 |

## 注意

初回はmacOSの画面収録権限が必要。TD実測でpluginロード、48 kHz stereo 1024 samples、stream running=1を確認した。検証時は再生タイミング内にaudio bufferを捕捉できず、実音声のpeak確認は未完了。無音時もOSから音声bufferが届くまではゼロを出力する。

## ビルド

`./build.sh` → `build/SystemAudioCHOP.plugin`
