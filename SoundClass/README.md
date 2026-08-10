# Sound Class CHOP — sound classification (macOS / SoundAnalysis)

**English** | [日本語](#日本語)

## English

Stream-analyses an audio CHOP input (Audio Device In, Audio File In, …) and outputs the confidence
of **over 300 sound classes** — laughter, applause, cheering, a barking dog, an alarm —
(`SNClassifySoundRequest`, Apple's built-in model) as channels.
**A custom Core ML sound classification model (.mlmodel / .mlmodelc) can be substituted.**

Measured (M2, TD's stock music sample): classified accurately as `music 0.83 / synthesizer 0.65 /
…`.

### Output

- One channel (confidence 0–1) per class ID listed in the `Classes` parameter (space separated)
- **The top 10 across all classes appear in the Info DAT** — you do not need to know the class IDs
  in advance: play the sound, watch the Info DAT, and add the IDs you want to `Classes`.
  Note this is the operator's **Info DAT** (an Info DAT node with its Operator set to this CHOP),
  not a CHOP to DAT of its channels — the latter only ever shows what is already in `Classes`.
  `demo.toe`'s `/project1/SoundClass` has both side by side (`top10` and `chopto1`).
  You do not have to wire it up yourself: turn on the **Info DAT (top 10)** toggle and the operator
  creates the Info DAT next to itself (a Callbacks DAT is docked to the node automatically on
  placement, as a closed chip).
- Results update every `Window (sec) × (1 - Overlap)` (by default 1 s × 0.5 = every 0.5 s). The
  channels hold the latest value (add a Lag/Filter CHOP downstream to smooth them)

Example class IDs: `applause cheering laughter music speech singing shout whistling
finger_snapping dog cat siren car_horn knock door telephone_bell ...`

### The full class list (303)

The Info DAT only shows the top 10 for whatever is playing, which is enough to discover IDs by ear.
For the complete set, the authority is the API itself — `SNClassifySoundRequest.knownClassifications`.
Regenerate it on your own machine with:

```sh
clang -fobjc-arc -framework Foundation -framework SoundAnalysis \
      -o /tmp/sound_classes tools/sound_classes.m && /tmp/sound_classes
```

**The list belongs to the OS version.** These 303 are what `com.apple.SoundAnalysis.classifier.v1`
reports on macOS 26.6; a future release may add or drop entries, so treat a hardcoded list as a
snapshot.

<details>
<summary>303 class IDs (macOS 26.6)</summary>

```
speech                  shout                   yell                    battle_cry              children_shouting       screaming
whispering              laughter                baby_laughter           giggling                snicker                 belly_laugh
chuckle_chortle         crying_sobbing          baby_crying             sigh                    singing                 choir_singing
yodeling                rapping                 humming                 whistling               breathing               snoring
gasp                    cough                   sneeze                  nose_blowing            person_running          person_shuffling
person_walking          chewing                 biting                  gargling                burp                    hiccup
slurp                   finger_snapping         clapping                cheering                applause                booing
chatter                 crowd                   babble                  dog                     dog_bark                dog_howl
dog_bow_wow             dog_growl               dog_whimper             cat                     cat_purr                cat_meow
horse_clip_clop         horse_neigh             cow_moo                 pig_oink                sheep_bleat             fowl
chicken                 chicken_cluck           rooster_crow            turkey_gobble           duck_quack              goose_honk
lion_roar               bird                    bird_vocalization       bird_chirp_tweet        bird_squawk             pigeon_dove_coo
crow_caw                owl_hoot                bird_flapping           insect                  cricket_chirp           mosquito_buzz
fly_buzz                bee_buzz                frog                    frog_croak              snake_hiss              snake_rattle
whale_vocalization      coyote_howl             elk_bugle               music                   plucked_string_instrument  guitar
electric_guitar         bass_guitar             acoustic_guitar         steel_guitar_slide_guitar  guitar_tapping          guitar_strum
banjo                   sitar                   mandolin                zither                  ukulele                 keyboard_musical
piano                   electric_piano          organ                   electronic_organ        hammond_organ           synthesizer
harpsichord             percussion              drum_kit                drum                    snare_drum              bass_drum
timpani                 tabla                   cymbal                  hi_hat                  tambourine              rattle_instrument
gong                    mallet_percussion       marimba_xylophone       glockenspiel            vibraphone              steelpan
orchestra               brass_instrument        french_horn             trumpet                 trombone                bowed_string_instrument
violin_fiddle           cello                   double_bass             wind_instrument         flute                   saxophone
clarinet                oboe                    bassoon                 harp                    bell                    church_bell
bicycle_bell            cowbell                 tuning_fork             chime                   wind_chime              harmonica
accordion               bagpipes                didgeridoo              shofar                  theremin                singing_bowl
disc_scratching         wind                    wind_rustling_leaves    wind_noise_microphone   thunderstorm            thunder
water                   rain                    raindrop                stream_burbling         waterfall               ocean
sea_waves               gurgling                fire                    fire_crackle            boat_water_vehicle      sailing
rowboat_canoe_kayak     motorboat_speedboat     car_horn                power_windows           vehicle_skidding        car_passing_by
race_car                truck                   air_horn                reverse_beeps           bus                     emergency_vehicle
police_siren            ambulance_siren         fire_engine_siren       motorcycle              traffic_noise           rail_transport
train                   train_whistle           train_horn              railroad_car            train_wheels_squealing  subway_metro
aircraft                helicopter              airplane                bicycle                 skateboard              engine
lawn_mower              chainsaw                engine_knocking         engine_starting         engine_idling           engine_accelerating_revving
door                    door_bell               door_sliding            door_slam               knock                   tap
squeak                  drawer_open_close       dishes_pots_pans        cutlery_silverware      chopping_food           frying_food
microwave_oven          blender                 water_tap_faucet        sink_filling_washing    bathtub_filling_washing  hair_dryer
toilet_flush            toothbrush              vacuum_cleaner          zipper                  keys_jangling           coin_dropping
scissors                electric_shaver         typing                  typewriter              typing_computer_keyboard  writing
telephone               telephone_bell_ringing  ringtone                alarm_clock             siren                   civil_defense_siren
smoke_detector          foghorn                 ratchet_and_pawl        clock                   tick                    tick_tock
sewing_machine          mechanical_fan          air_conditioner         printer                 camera                  hammer
saw                     power_tool              drill                   hedge_trimmer           gunshot_gunfire         artillery_fire
fireworks               firecracker             eruption                boom                    chopping_wood           wood_cracking
glass_clink             glass_breaking          liquid_splashing        liquid_sloshing         liquid_squishing        liquid_dripping
liquid_pouring          liquid_trickle_dribble  liquid_filling_container  liquid_spraying         water_pump              boiling
underwater_bubbling     whoosh_swoosh_swish     thump_thud              basketball_bounce       slap_smack              crushing
crumpling_crinkling     tearing                 beep                    click                   bowling_impact          playing_badminton
playing_hockey          playing_squash          playing_table_tennis    playing_tennis          playing_volleyball      rope_skipping
scuba_diving            skiing                  silence
```

</details>

### Parameters

| Parameter | Default | Description |
|---|---|---|
| Active | On | Enable/disable analysis |
| Info DAT (top 10) | Off | Turning it on creates an Info DAT next to the operator showing the top 10 across all classes |
| Classes | applause cheering laughter music speech | Class IDs to output (space separated) |
| Custom Core ML Model | — | A custom sound classification model. `.mlmodel` is compiled automatically on load |
| Window (sec) | 1.0 | Analysis window length (shorter reacts faster, less accurately) |
| Overlap Factor | 0.5 | Window overlap (larger updates more often) |

### Notes

- Only channel 0 of the input is used (stereo is not mixed down — L is read. Make it mono
  upstream with a Math CHOP if needed)
- This CHOP is `cookEveryFrameIfAsked` — **unless the output is used (displayed) somewhere it does
  not cook and no audio flows**. Keep it in a state where something evaluates it every frame
  (export, reference, CHOP Execute…)
- Info CHOP (diagnostics): `executes / results / samplerate`. If `results` is climbing, analysis
  is running

### Build

```
./build.sh    # → build/SoundClassCHOP.plugin
```

For how to load it, see the [root README](../README.md) (a CPlusPlus CHOP, or the Plugins folder).

## 日本語

オーディオ CHOP 入力（Audio Device In / Audio File In 等）をストリーム解析し、
**笑い声・拍手・歓声・犬の鳴き声・警報音など300種類以上**の音分類
（`SNClassifySoundRequest`・Apple 組込みモデル）の信頼度をチャンネル出力する。
**独自の Core ML 音響分類モデル（.mlmodel / .mlmodelc）への差し替えも可能**。

実測（M2 / TD 標準の音楽サンプル）: `music 0.83 / synthesizer 0.65 / ...` と的確に分類。

### 出力

- `Classes` パラメータに列挙したクラスID（空白区切り）ごとに1チャンネル（信頼度 0〜1）
- **全クラスのランキング上位10は Info DAT に出る** — クラスIDが分からなくても、
  実際に音を鳴らして Info DAT を見ながら欲しいIDを拾って `Classes` に足せばよい。
  ここで言う Info DAT は**このCHOPを Operator に指定した Info DAT ノード**のこと。
  CHOP to DAT でチャンネルを表にしたものは `Classes` に書いたIDしか出ないので別物。
  `demo.toe` の `/project1/SoundClass` に両方並べてある(`top10` と `chopto1`)。
  自分で繋がなくてもよく、**Info DAT (top 10)** トグルを on にすれば隣に Info DAT が自動生成される
  (Callbacks DAT は配置しただけで閉じたチップとしてドック接続される)
- 結果の更新間隔は `Window (sec) × (1 - Overlap)`（既定 1秒×0.5 = 0.5秒ごと）。
  チャンネルは最新値を保持する（滑らかにしたい場合は後段に Lag/Filter CHOP）

クラスIDの例: `applause cheering laughter music speech singing shout whistling
finger_snapping dog cat siren car_horn knock door telephone_bell ...`

### クラスID全一覧（303件）

Info DAT に出るのは今鳴っている音の上位10件だけで、耳で探す用途にはそれで足りる。
全部を知りたいときの正は API そのもの（`SNClassifySoundRequest.knownClassifications`）。
手元で再生成するには:

```sh
clang -fobjc-arc -framework Foundation -framework SoundAnalysis \
      -o /tmp/sound_classes tools/sound_classes.m && /tmp/sound_classes
```

**一覧は OS のバージョンに紐づく。** 下の303件は macOS 26.6 の
`com.apple.SoundAnalysis.classifier.v1` が返したもので、将来増減しうる。
貼ってある一覧はスナップショットとして扱うこと。

<details>
<summary>303件のクラスID（macOS 26.6）</summary>

```
speech                  shout                   yell                    battle_cry              children_shouting       screaming
whispering              laughter                baby_laughter           giggling                snicker                 belly_laugh
chuckle_chortle         crying_sobbing          baby_crying             sigh                    singing                 choir_singing
yodeling                rapping                 humming                 whistling               breathing               snoring
gasp                    cough                   sneeze                  nose_blowing            person_running          person_shuffling
person_walking          chewing                 biting                  gargling                burp                    hiccup
slurp                   finger_snapping         clapping                cheering                applause                booing
chatter                 crowd                   babble                  dog                     dog_bark                dog_howl
dog_bow_wow             dog_growl               dog_whimper             cat                     cat_purr                cat_meow
horse_clip_clop         horse_neigh             cow_moo                 pig_oink                sheep_bleat             fowl
chicken                 chicken_cluck           rooster_crow            turkey_gobble           duck_quack              goose_honk
lion_roar               bird                    bird_vocalization       bird_chirp_tweet        bird_squawk             pigeon_dove_coo
crow_caw                owl_hoot                bird_flapping           insect                  cricket_chirp           mosquito_buzz
fly_buzz                bee_buzz                frog                    frog_croak              snake_hiss              snake_rattle
whale_vocalization      coyote_howl             elk_bugle               music                   plucked_string_instrument  guitar
electric_guitar         bass_guitar             acoustic_guitar         steel_guitar_slide_guitar  guitar_tapping          guitar_strum
banjo                   sitar                   mandolin                zither                  ukulele                 keyboard_musical
piano                   electric_piano          organ                   electronic_organ        hammond_organ           synthesizer
harpsichord             percussion              drum_kit                drum                    snare_drum              bass_drum
timpani                 tabla                   cymbal                  hi_hat                  tambourine              rattle_instrument
gong                    mallet_percussion       marimba_xylophone       glockenspiel            vibraphone              steelpan
orchestra               brass_instrument        french_horn             trumpet                 trombone                bowed_string_instrument
violin_fiddle           cello                   double_bass             wind_instrument         flute                   saxophone
clarinet                oboe                    bassoon                 harp                    bell                    church_bell
bicycle_bell            cowbell                 tuning_fork             chime                   wind_chime              harmonica
accordion               bagpipes                didgeridoo              shofar                  theremin                singing_bowl
disc_scratching         wind                    wind_rustling_leaves    wind_noise_microphone   thunderstorm            thunder
water                   rain                    raindrop                stream_burbling         waterfall               ocean
sea_waves               gurgling                fire                    fire_crackle            boat_water_vehicle      sailing
rowboat_canoe_kayak     motorboat_speedboat     car_horn                power_windows           vehicle_skidding        car_passing_by
race_car                truck                   air_horn                reverse_beeps           bus                     emergency_vehicle
police_siren            ambulance_siren         fire_engine_siren       motorcycle              traffic_noise           rail_transport
train                   train_whistle           train_horn              railroad_car            train_wheels_squealing  subway_metro
aircraft                helicopter              airplane                bicycle                 skateboard              engine
lawn_mower              chainsaw                engine_knocking         engine_starting         engine_idling           engine_accelerating_revving
door                    door_bell               door_sliding            door_slam               knock                   tap
squeak                  drawer_open_close       dishes_pots_pans        cutlery_silverware      chopping_food           frying_food
microwave_oven          blender                 water_tap_faucet        sink_filling_washing    bathtub_filling_washing  hair_dryer
toilet_flush            toothbrush              vacuum_cleaner          zipper                  keys_jangling           coin_dropping
scissors                electric_shaver         typing                  typewriter              typing_computer_keyboard  writing
telephone               telephone_bell_ringing  ringtone                alarm_clock             siren                   civil_defense_siren
smoke_detector          foghorn                 ratchet_and_pawl        clock                   tick                    tick_tock
sewing_machine          mechanical_fan          air_conditioner         printer                 camera                  hammer
saw                     power_tool              drill                   hedge_trimmer           gunshot_gunfire         artillery_fire
fireworks               firecracker             eruption                boom                    chopping_wood           wood_cracking
glass_clink             glass_breaking          liquid_splashing        liquid_sloshing         liquid_squishing        liquid_dripping
liquid_pouring          liquid_trickle_dribble  liquid_filling_container  liquid_spraying         water_pump              boiling
underwater_bubbling     whoosh_swoosh_swish     thump_thud              basketball_bounce       slap_smack              crushing
crumpling_crinkling     tearing                 beep                    click                   bowling_impact          playing_badminton
playing_hockey          playing_squash          playing_table_tennis    playing_tennis          playing_volleyball      rope_skipping
scuba_diving            skiing                  silence
```

</details>

### パラメータ

| パラメータ | 既定 | 内容 |
|---|---|---|
| Active | On | 解析の有効/無効 |
| Info DAT (top 10) | Off | on にすると隣に Info DAT を自動生成し、全クラスの上位10件を表示する |
| Classes | applause cheering laughter music speech | 出力するクラスID（空白区切り） |
| Custom Core ML Model | — | 独自の音響分類モデル。`.mlmodel` はロード時に自動コンパイル |
| Window (sec) | 1.0 | 解析ウィンドウ長（短いほど反応が速く精度は下がる） |
| Overlap Factor | 0.5 | ウィンドウの重なり（大きいほど更新が細かい） |

### 注意

- 入力はチャンネル0のみ使用（ステレオはミックスせず L を見る。必要なら前段で Math CHOP 等でモノ化）
- 本 CHOP は `cookEveryFrameIfAsked` — **出力をどこかで使って（表示して）いないと cook されず
  音声が流れない**。エクスポート/参照/CHOP Execute 等で毎フレーム評価される状態で使うこと
- Info CHOP（動作診断）: `executes / results / samplerate`。`results` が増えていれば解析が回っている

### ビルド

```
./build.sh    # → build/SoundClassCHOP.plugin
```

使い方は [ルート README](../README.md) 参照（CPlusPlus CHOP でロード or Plugins フォルダへ）。
