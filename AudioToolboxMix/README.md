# AudioToolbox Mix CHOP

macOS 26 の **AUAudioMix**(`kAudioUnitSubType_AUAudioMix` = 'amix')で、空間音声から
**前景(speech)/背景(ambience)を分離・再ミックス**する。`AVAudioEngine` の manual rendering に
'amix' AudioUnit を差し込み、**4ch First-Order Ambisonics** 入力を通して結果(5ch)を出力する。

> **入力形式の制約**: このAUは **4ch First-Order Ambisonics 入力(layoutTag 0x930004)専用**で、
> 標準ステレオ/モノは `setFormat` が -10868 で拒否する。**意味のある分離には実際の空間音声
> (4chアンビソニックス)素材が必要**。合成トーンやステレオでは(接続はできても)無音になる。

- 出力5ch(amix の raw 出力を `out0..out4` として返す)
- **Style**(0-9)= 分離/再ミックスのスタイル、**Remix Amount**(0-1)= 原音〜完全分離のブレンド

## 実測(M2)

- 4ch入力を接続 → `input_channels=4` / `output_channels=5` / `renders>0`、TDクラッシュなし。
  AUのロード・4ch受理・5ch出力・Style/Remixパラメータ反映を確認
- **合成入力では無音**(前景/背景の分離対象が無いため)。実分離検証には4chアンビソニックスの
  空間音声素材が要る(未入手のため実分離は未検証)

## 使い方

1. **4チャンネル First-Order Ambisonics** のオーディオCHOP(W,Y,Z,X 相当)を入力に接続
2. `Style`(0-9)と `Remix Amount`(0=原音 / 1=完全分離)を設定
3. 出力 `out0..out4` を用途に応じてルーティング

## 出力(CHOP)

`out0`..`out4`(amix の5ch出力)。Info CHOP: `executes / renders / input_channels / output_channels / ready`

## パラメータ

| パラメータ | 説明 |
|---|---|
| Active | 有効 |
| Style | 分離/再ミックスのスタイル(0-9) |
| Remix Amount | 原音〜完全分離のブレンド(0-1) |

## 注意

- **4ch First-Order Ambisonics 入力専用**。標準ステレオ/モノは受け付けない(AUが -10868 で拒否)
- 接続には AU 自身の `inputBusses[0].format`(4ch FOA)を使う。標準フォーマットで connect すると
  クラッシュする
- macOS 26+ が必要('amix' は macOS 26.0 で追加)

## ビルド

```
cd AudioMix && ./build.sh
```
