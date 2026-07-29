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

## 命名の三層ルール(opLabel / opType / folder)

2026-07-21 に全op統一。原則:

1. **opType = opLabel からスペースを除いた文字列**(先頭大文字+以降小文字数字)。
   opLabel が略称なら opType も略称を反映する。
   例: `Vision Pose`→`Visionpose` / `CI Bokeh`→`Cibokeh` / `CA Process Tap`→`Caprocesstap` /
   `LLM MLX`→`Llmmlx` / `Cinematic Data`→`Cinematicdata`
2. **folder = opLabel(スペース除去・CamelCase)。ただし略称(CI/CA/GameKit 等)はフレームワーク名に展開**。
   例: `CI Bokeh`→`CoreImageBokeh` / `CA Process Tap`→`CoreAudioProcessTap` /
   `GameKit Agents`→`GameplayKitAgents` / `LLM MLX`→`LLMMLX`(LLMは展開不要)
3. **ファイル名 = folder + Family**(例 `CoreImageBokehTOP.mm`)。バンドル名も同じ
4. **同一ラベルを複数familyで出す場合は folder = ラベル+Family**(衝突回避):
   `CoreML` TOP/CHOP/DAT → `CoreML/`・`CoreMLCHOP/`・`CoreMLDAT/`、
   Multipeer → `MultipeerCHOP/`・`MultipeerDAT/`。この時のみ folder≠label は規約として許容
5. **1フォルダ2opの共有(Cinematic 等)は folder=フレームワーク**、opType は op ごとに分ける
   (`Cinematicdata`/`Cinematicvideo`)

**opType を変えると sample.toe の該当ノードが Unknown operator type(赤)になる**。改名時は
examples/デモの貼り直しをセットで行う(MCP必須)。

## UIラベルは ASCII のみ(記号も含む)

- **`p.label` と `appendMenu` のラベル配列は ASCII 文字だけにする**。日本語はもちろん、
  `…`(U+2026)や `→`(U+2192)のような**記号も TD のUIで文字化けする**(実測: `…` が `â€¦` になる)
- 代替: `…` → `...`、`→` → `to` / `->`
- **パラメータの「値」は非ASCIIでも問題ない**(Text欄の日本語や、省略記号 `…` の既定値は正しく表示・描画される)。
  化けるのは**ラベル**(パラメータ名の表示とメニュー項目名)
- 追加時のセルフチェック:
  `grep -rnP '(p\.label\s*=\s*"[^"]*[^\x00-\x7F]|const char\* l\[\]\s*=\s*\{[^}]*[^\x00-\x7F])' --include="*.mm" .`
