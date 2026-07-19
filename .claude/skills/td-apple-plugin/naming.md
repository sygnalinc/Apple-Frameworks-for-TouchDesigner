# 命名規約(TD起動時の検証で弾かれる罠あり)

TDは起動時にカスタムOPの名前を検証する。規約違反は**起動エラーやOP登録失敗**になる。

## opType(タイプトークン。既定ノード名 = opType.lower())

- **先頭大文字1字 + 以降は小文字と数字のみ**(例 `Visionpose3d` / `Coreimagebokeh` / `Metalupscale`)
- 記号・スペース・連続大文字は不可
- family 間では**重複可**(Multipeer DAT と Multipeer CHOP が opType "Multipeer" で共存できる)

## opIcon(3文字アイコン)

- **英字のみ3文字。数字を入れると TD起動時の名前検証で弾かれ起動エラー**になる
  (実例: "VP3"→NG、"VPD"→OK)

## opLabel(OP Create Dialog の表示名)

- **`Framework Feature` 形式**にする(例 `Vision Pose` / `CoreImage Bokeh` / `Metal Upscale` /
  `RealityKit Capture` / `Speech Activity`)
- **接頭辞は実装フレームワーク名**。「Apple」等の共通接頭辞は
  **OP Create Dialog のタイルで折り返して読めなくなる**(1タイル約20文字)ため使わない
- ラベルはフレームワークの粒度に合わせる:
  - Vision系 → `Vision X`
  - Core ML → `CoreML X`(SAM2/ImageGen/Detect/CHOP)
  - Core Image → `CoreImage X`(Bokeh/Keystone/Enhance/Code)
  - VideoToolbox/MetalFX/MPS → `Metal X`(Upscale/Denoise/FrameInterp/MPSAnalyze)
  - ImageIO → `ImageIO X`、SpeechAnalyzer → `Speech X`、SoundAnalysis → `Sound X`
  - 単独名が定着しているものは据え置き(`Foundation Model` / `Translate` / `Text Analyze` /
    `Shazam` / `Shortcuts` / `Multipeer In` / `Game Controller`)

## パラメータ名・UIラベル

- パラメータ名は先頭大文字 + 小文字数字(例 `Maxbodies` / `Flip`)
- **UIラベル・メニューラベルは英語のみ**(日本語はTDのUIで文字化けする)
- ソースコメント・READMEの日本語はOK

## フォルダ名・ファイル名は opLabel に揃える

- フォルダ名 = **opLabelのスペース除去**(例 `CoreImage Bokeh` → `CoreImageBokeh/`)
- ソース = `<Name><Family>.mm`(例 `CoreImageBokehTOP.mm`)、build.shの `<Name><Family>` も一致させる
- **Swiftヘルパのモジュール/dylib名はリネームで巻き込まない**(内部識別子。build.shの置換は
  NAME・ソース.mm・plistのみを対象にし、Helperを含む行は別substringで守る)

## 命名の先例(family と機能)

| 表示名 | opType | 由来 |
|---|---|---|
| Vision Pose / Hand / Face / Segment / … | Visionpose 等 | Vision |
| CoreML SAM2 / ImageGen / Detect | Coremlsam2 等 | Core ML |
| CoreImage Bokeh / Keystone / Enhance / Code | Coreimagebokeh 等 | Core Image |
| Metal Upscale / Denoise / FrameInterp / MPSAnalyze | Metalupscale 等 | VideoToolbox/MetalFX/MPS |
| Sound Class / Features | Soundclass 等 | SoundAnalysis |
| Speech Text / Synth / Activity | Speechtext 等 | SpeechAnalyzer/AVSpeech |
| Foundation Model | Foundationmodel | FoundationModels(汎用"LLM"は他統合と衝突回避で避けた) |
| Translate | Translate | Translation |
| RealityKit Capture | Realitykitcapture | RealityKit Object Capture |
| ImageIO Metadata | Imageiometadata | ImageIO |
