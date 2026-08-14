# MapKit

**English** | [日本語](#日本語)

## English

One TOP that renders Apple Maps **live**: the 3D map you can fly through, or **Look Around**
street-level photography you can stand in. No API key, no account.

> **Status: experimental.** Requires **Screen Recording permission** (the same TCC grant as the
> Screen Capture TOP) — see "How it works" for why.

### What it does (measured on M2 / macOS 26.6)

- **Fly through the 3D map**: animate `Latitude / Longitude / Distance / Pitch / Heading` from
  expressions or CHOP exports — **57 fps sustained** (measured over 2 minutes, TD itself at 60 fps)
- **Look Around**: live street-level scene at the coordinate (Shibuya Crossing measured); with the
  window shown you can look and walk around in it
- **Hand-frame with trackpad/mouse**: turn **Show Window** on and the map window comes forward with
  a drag bar. Pan / pinch-zoom / two-finger rotate / Option-scroll pitch — the same gestures as
  Maps.app — and every move is **written back into the parameters**
- Styles: Standard / Muted / Satellite / Hybrid, `Realistic (3D)` elevation, traffic, POI,
  dark appearance

### How it works — and why it needs Screen Recording

`MKMapSnapshotter` costs ~0.9 s **per image** no matter what (885 ms even at 32×32; parallel
requests serialize to ~1.4 images/s), so a snapshot API can never fly. Maps.app is smooth because it
keeps a **persistent renderer** alive. This op does the same: a real `MKMapView` (or
`MKLookAroundViewController`, an `NSViewController` on macOS) lives in a borderless window owned by
the plugin.

Reading that window back is the hard part. MapKit draws with Metal into presented drawables that
**belong to the window server** — every in-process capture path comes back blank
(`cacheDisplayInRect:`, `layer renderInContext:`, and `CARenderer`, all measured). The only
supported route is ScreenCaptureKit's `initWithDesktopIndependentWindow:`, which is why the op
needs the Screen Recording permission.

### The window

- **Show Window off (default)**: the window parks at the bottom-right corner of the screen with
  **1 pt left on-screen** — on a MacBook the rounded bezel effectively hides it. Why not fully
  hidden, all measured: fully off-screen **freezes rendering** (frames stop, last image sticks);
  desktop level behind other windows counts as occluded and **goes gray after a while**; and
  lowering the window's alpha darkens the capture itself, because **ScreenCaptureKit returns the
  composited appearance** (alpha 0.01 gives 1 % brightness)
- **Show Window on**: the window comes forward (floating — clicking TD does not hide it) with a
  separate title-bar window above it; drag the bar and the map follows
  (`NSWindowDidMoveNotification`). The map window itself stays borderless because titling it — or
  even attaching it as a child window on macOS 26 — rounds its corners, and the rounding shows up
  in the capture (measured by corner alphas). The window position is remembered across hide/show
- The map's own compass/zoom/pitch controls are never shown: they would be captured. All gestures
  work without them

### Overlaying your own geometry (Markers DAT)

Point **Markers DAT** at a table of `name / lat / lon` rows (or just `lat / lon`) and the TOP's
**Info DAT** reports each point's screen position as `u / v / visible`. The projection comes from
`MKMapView`'s own `convertCoordinate:toPointToView:`, so it matches the 3D perspective, pitch and
heading **exactly** — measured: with pitch 0 and heading 0, the camera target lands on (0.5, 0.5)
and a point 500 m north on (0.5, 0.966).

Instance SOP geometry at `(u−0.5, (v−0.5)/aspect)` through an Ortho Width = 1 camera and composite
over the map (the same overlay pattern as the Vision examples) and your objects sit on the map and
track every camera move. Off-screen points report `visible` = 0 — use it as an instance scale.
The demo `/project1/MapKitFly` overlays pins on five Tokyo landmarks this way while flying with a
game controller. Note the projected points are **ground positions**; the API carries no building
height.

### Two-way camera

With Show Window on, **the window is the master**: the camera you frame by hand is pulled every
cook and written back to `Latitude / Longitude / Distance / Pitch / Heading` (via the same embedded
Python used elsewhere in this repo). Turn it off and the parameters are the master again — no jump,
because the last pulled values seed the push side. The initial camera is seeded from the parameters
so the default world view never leaks back into them.

In Look Around mode the camera parameters only choose the scene coordinate. **Looking around is
done by hand in the window** — and that took two discoveries: the embedded view controller ships
with its pan/zoom recognizers **disabled** (`navigationEnabled = YES` does not flip them; measured
`enabled = 0`), so this op force-enables them every cook, which makes drag-to-look and pinch-zoom
work for real input.

**The view direction cannot be driven from parameters.** The whole chain was measured: the scene
and view controller expose no orientation API; and synthesizing drag gestures is impossible —
application-constructed `NSEvent`s do not feed AppKit's gesture-recognizer machinery at all (a
plain self-owned `NSPanGestureRecognizer` fired **zero** times from posted synthetic events).
System-level event injection would need the Accessibility permission and would move the user's
real cursor. So: coordinates from parameters, view direction by hand.

### Parameters

| Parameter | Meaning |
|---|---|
| Mode | `Map` or `Look Around` |
| Latitude / Longitude | Camera target (Map) or scene coordinate (Look Around) |
| Distance (m) | Camera distance. No upper clamp — hand-zooming out writes big values back |
| Pitch / Heading | Camera tilt and rotation (Map mode) |
| Style / Elevation / Show Traffic / Show Points Of Interest / Dark Appearance | Map styling |
| Show Attribution | Burns "&#63743; Apple Maps" into the output (same presentation as everywhere else in this repo). **On by default.** The map's built-in "Legal" label is always hidden instead — in a TOP it is just pixels, not a working link. Apple's guidelines expect visible attribution on maps shown to an audience; switching this off is your call |
| Attribution Position | Which corner |
| Capture FPS | ScreenCaptureKit frame-rate ceiling. Idle maps deliver frames only on change |
| Markers DAT | Table of lat/lon points to project into screen space (see above) |
| Show Window | Interactive mode (see above) |
| Restart | Rebuild the stream and re-request the scene |

Resolution comes from the **Common** page (`Use Input` falls back to 1280×720).

Info CHOP: `executes / frames / running / window_ready / available / width / height / capture_fps`.
`available` is 1 while a Look Around scene exists at the coordinate — coverage is patchy (Shibuya
Crossing yes, Tokyo Station no) and there is no API to query it, so check this before relying on
the image.

## MapKit DAT

A second op in this folder, **MapKit** (DAT family — the opType repeats across families like the
CoreML trio), provides the data side. Four modes, all measured working:

| Mode | In → Out |
|---|---|
| **Search Nearby** | Natural-language query + centre/span → `name / lat / lon / distance_m / category / address / phone / url`. "coffee" around Shibuya returned real cafés with addresses |
| **Geocode** | Place name or address → coordinates. "Tokyo Station" → 35.68107, 139.76743. Implemented with `MKLocalSearch`, because `CLGeocoder` returns *no result* (kCLErrorDomain 8) for place names |
| **Reverse Geocode** | lat/lon → `country / admin_area / locality / thoroughfare / postal_code` |
| **Route** | Source → destination, walking/driving/transit. `Steps` gives instructions with distances (Shibuya→Tokyo Station walking: 7532 m / 124 min, Japanese instructions); `Points` gives the **full route polyline** (190 rows for that route) |
| **Look Around Coverage** | Where does Look Around imagery exist? There is no coverage-query API, so this probes scene requests point by point (a miss costs ~0.16 s). No input: scans a `Coverage Grid` × Grid over `Span` around the centre — Tokyo Station 600 m, 5×5: **23/25 points covered** in ~20 s (the station building itself is one of the two holes, which explains the TOP's earlier "no coverage" there). With a DAT wired into the input (search results, route points — any table with lat/lon in columns 1–2): checks each row instead — all 6 Shibuya cafés from a search came back available. If the result stays empty right after wiring an input, press **Refresh** (the input may still have been loading when first read) |

`Points` exists to feed the TOP: DAT to CHOP the lat/lon columns and drive the MapKit TOP's camera
along the route — a turn-by-turn flythrough.

Requests fire when a parameter changes (plus **Refresh**); results arrive asynchronously and the
completion handlers come in on the main queue, same as the TOP. Info CHOP:
`executes / requests / busy / valid / rows / request_ms`.

### Notes

- There is **no public API for time of day** — the 3D lighting cannot be changed (`timeOfDay`
  appears nowhere in MapKit's headers or binary). **Dark Appearance** is the closest control
- Imagery streams from Apple's servers: a network connection is required, and heavy use is
  rate-limited
- One real window (plus the drag bar while shown) exists on screen. It ignores the mouse while
  hidden

### Build

```bash
cd MapKit && ./build.sh
```

---

## 日本語

Apple マップを**ライブ**で TOP に出す1つのオペレータ。3D地図の中を飛び、**Look Around**
(街並みの実写)の中に立てる。API キーもアカウントも不要。

> **状態: experimental(実験中)。** **画面収録の許可**(Screen Capture TOP と同じ TCC)が要る —
> 理由は「仕組み」を参照。

### できること(M2 / macOS 26.6 で実測)

- **3D地図の中を飛ぶ**: `Latitude / Longitude / Distance / Pitch / Heading` を式や CHOP で
  アニメーション — **57fps を維持**(2分間の実測。TD 本体は 60fps)
- **Look Around**: 座標の街並みをライブ表示(渋谷スクランブルで実測)。ウインドウを出せば
  その中で見回し・移動もできる
- **トラックパッド/マウスで構図を決める**: **Show Window** をオンにするとドラッグバー付きで
  前面に出る。パン / ピンチズーム / 2本指回転 / Option+スクロールのチルト — マップ.app と
  同じ操作 — の結果が**パラメータへ書き戻される**
- スタイル: 標準 / ミュート / 衛星 / ハイブリッド、`Realistic (3D)`、交通情報、POI、ダーク

### 仕組み — なぜ画面収録が要るのか

`MKMapSnapshotter` は何をしても**1枚あたり約0.9秒**(32×32でも885ms・並列にしても約1.4枚/秒に
直列化される)ので、スナップショット API では飛べない。マップ.app が滑らかなのは
**レンダラーを常駐させている**からで、このopも同じことをする: 本物の `MKMapView`
(Look Around は `MKLookAroundViewController`。macOS では NSViewController)を、プラグインが持つ
ボーダーレスウインドウの中で生かしっぱなしにする。

難しいのは**その中身を読み出す方法**。MapKit は Metal で描き、present 済みの drawable は
**ウインドウサーバーの持ち物**になる — プロセス内の取り込みは全滅だった
(`cacheDisplayInRect:` / `layer renderInContext:` / `CARenderer`、いずれも真っ白を実測)。
唯一の公式ルートが ScreenCaptureKit の `initWithDesktopIndependentWindow:` で、
これが画面収録の許可が要る理由。

### ウインドウについて

- **Show Window オフ(既定)**: ウインドウは画面右下の隅に**1pt だけ画面内に残して**退避する。
  MacBook では丸角ベゼルにほぼ隠れる。完全に隠せない理由(すべて実測):
  完全に画面外だと**描画が凍結**する(フレームが止まり最後の絵のまま)。デスクトップレベルで
  他の窓の裏に置くと遮蔽扱いになり**一定時間で灰色**になる。アルファを下げると
  **取り込みまで暗くなる**(ScreenCaptureKit は合成後の見た目を返す。アルファ 0.01 = 輝度1%)
- **Show Window オン**: フローティングで前面に出る(TD をクリックしても隠れない)。上に別
  ウインドウのバーが乗り、バーを掴むと地図がついてくる(`NSWindowDidMoveNotification`)。
  地図ウインドウ自体をタイトル付きにする — macOS 26 では親子接続でも — と角が丸くなり、
  丸角が取り込みに写る(四隅アルファで実測)ため、地図側は常にボーダーレス。
  表示位置は隠す→再表示で復元される
- 地図のコンパス/ズーム/チルトコントロールは出さない(取り込みに写るため)。
  ジェスチャはコントロール無しでも全部効く

### 自前のジオメトリを重ねる(Markers DAT)

**Markers DAT** に `name / lat / lon`(または `lat / lon` だけ)の表を指すと、TOP の **Info DAT** に
各点の画面位置が `u / v / visible` で出る。射影は `MKMapView` 自身の
`convertCoordinate:toPointToView:` なので、3Dのパース・ピッチ・ヘディングに**正確に**一致する —
実測: pitch 0 / heading 0 でカメラの注視点が (0.5, 0.5)、その500m北の点が (0.5, 0.966)。

`(u−0.5, (v−0.5)/アスペクト比)` で SOP をインスタンシングし、Ortho Width = 1 のカメラで地図に
合成すれば(Vision 系の利用例と同じ重ね合わせの型)、オブジェクトは地図に張り付いてカメラの
動きに追従する。画面外の点は `visible` = 0 — インスタンスのスケールに使うと自動で消える。
demo の `/project1/MapKitFly` はこの方法で東京のランドマーク5箇所にピンを立てながら
ゲームパッドで飛ぶ。射影される点は**地表の位置**で、ビルの高さ方向は API に無い点に注意。

### 双方向カメラ

Show Window オンのあいだは**ウインドウがマスター**: 手で決めたカメラを毎 cook 読み取り、
`Latitude / Longitude / Distance / Pitch / Heading` へ書き戻す。オフに戻すとパラメータが
マスターに戻る — 書き戻した値を push 側の基準にしているので切り替えで飛ばない。
初期カメラはパラメータから入れるので、地図既定の全景が逆流することもない。

Look Around モードでパラメータが決めるのはシーンの座標だけ。**見回しはウインドウ内で手で行う**
— これも2つの発見が要った: 埋め込みのビューコントローラは Pan / ズームのレコグナイザが
**無効化された状態**で来る(`navigationEnabled = YES` でも変わらない。実測 `enabled = 0`)。
このopは毎 cook 強制的に有効化しており、実際のドラッグ見回しとピンチズームが効く。

**視線の向きはパラメータからは動かせない。** 経路を全部実測した: シーンにもビューコントローラにも
向きの API が無い。ジェスチャの合成も不可能 — アプリが組み立てた `NSEvent` は AppKit の
ジェスチャ機構に一切届かない(自前の `NSPanGestureRecognizer` すら合成イベントでは**発火 0 回**)。
システムレベルのイベント注入はアクセシビリティ許可が要る上に実際のカーソルが動いてしまう。
結論: 座標はパラメータ、視線は手で。

### パラメータ

| パラメータ | 意味 |
|---|---|
| Mode | `Map` か `Look Around` |
| Latitude / Longitude | カメラの注視点(Map)/ シーンの座標(Look Around) |
| Distance (m) | カメラ距離。上限クランプなし(手でズームアウトした大きい値も書き戻せる) |
| Pitch / Heading | カメラの傾きと回転(Map モード) |
| Style / Elevation / Show Traffic / Show Points Of Interest / Dark Appearance | 地図の見た目 |
| Show Attribution | 「&#63743; Apple Maps」を出力へ焼き込む。**既定オン**。地図内蔵の「Legal」ラベルは常に隠す — TOP 上ではただのピクセルで、リンクとして機能しないため。Apple のガイドライン上、人に見せる地図には帰属表示が求められる — 消す判断は利用者のもの |
| Attribution Position | どの隅に出すか |
| Capture FPS | ScreenCaptureKit のフレームレート上限。静止中は変化時しかフレームが来ない |
| Markers DAT | 画面座標へ射影する緯度経度の表(上記) |
| Show Window | 対話モード(上記) |
| Restart | ストリームを張り直し、シーンも取り直す |

解像度は **Common** ページから(`Use Input` は 1280×720 にフォールバック)。

Info CHOP: `executes / frames / running / window_ready / available / width / height / capture_fps`。
`available` は Look Around のシーンがその座標にあるとき 1。カバー範囲は飛び飛び
(渋谷スクランブル=あり / 東京駅=なし)で問い合わせ API も無いので、画に頼る前にこれを見る。

## MapKit DAT

このフォルダのもう1つのop、**MapKit**(DAT ファミリー。opType は CoreML 三兄弟と同じく
ファミリー間で重複可)がデータ側を担当する。4モード、すべて実測済み:

| モード | 入力 → 出力 |
|---|---|
| **Search Nearby** | 自然文クエリ + 中心/範囲 → `name / lat / lon / distance_m / category / address / phone / url`。渋谷で "coffee" → 実在のカフェが住所つきで返る |
| **Geocode** | 地名・住所 → 座標。「東京駅」→ 35.68107, 139.76743。実装は `MKLocalSearch`(`CLGeocoder` は地名で kCLErrorDomain 8 = 結果なしを返すため) |
| **Reverse Geocode** | 緯度経度 → `country / admin_area / locality / thoroughfare / postal_code` |
| **Route** | 出発地 → 目的地。徒歩/車/公共交通。`Steps` は距離つきの案内(渋谷→東京駅 徒歩 7532m / 124分・日本語の案内)、`Points` は**経路のポリライン全点**(この経路で190行) |
| **Look Around Coverage** | Look Around がどこにあるか。カバー範囲の問い合わせ API は無いので、シーン要求を点ごとに投げて当たり外れを見る(外れは約0.16秒)。入力なし: 中心 + `Span` を `Coverage Grid` × Grid で走査 — 東京駅600mの5×5で**23/25点にあり**(約20秒。駅舎そのものが穴の1つで、TOP で「範囲外」だった理由もこれで分かる)。**入力 DAT を繋ぐ**と(検索結果・経路の点列など、1〜2列目が lat/lon の表)各行を判定 — 渋谷のカフェ検索6件は全てあり。入力を繋いだ直後に空のままなら **Refresh**(初回読み取り時に入力がまだロード中のことがある) |

`Points` は TOP へ流すためにある: lat/lon 列を DAT to CHOP して MapKit TOP のカメラを
経路に沿って動かせば、道なりの飛行になる。

要求はパラメータが変わったとき(+ **Refresh**)に飛ぶ。結果は非同期で、完了ハンドラは
TOP と同じくメインキューに来る。Info CHOP:
`executes / requests / busy / valid / rows / request_ms`。

### 注意

- **時刻を変える公開 API は無い** — 3D の照明は変更できない(MapKit のヘッダ・バイナリとも
  `timeOfDay` は 0 件)。一番近いのは **Dark Appearance**
- 画像は Apple のサーバーから届く。ネットワークが要り、過剰な利用はレート制限される
- 実ウインドウが1枚(表示中はバーも)画面上に存在する。隠しているあいだはマウス素通し

### ビルド

```bash
cd MapKit && ./build.sh
```
