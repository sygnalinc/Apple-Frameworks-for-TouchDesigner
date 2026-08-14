# MapKit / MapKit Live

**English** | [日本語](#日本語)

## English

Renders Apple Maps imagery — the map itself, or **Look Around** street-level photography — into a
TOP. No API key, no account, nothing to sign up for.

> **Status: experimental.**

### What works (measured on M2 / macOS 26.6)

| Mode | Measured |
|---|---|
| Map, standard | Shibuya at 2560×1440 in **~0.9 s** |
| Map, satellite + `Realistic (3D)` + pitch 60° | Real building geometry, **~0.86 s** |
| Map, muted + dark | ~0.79 s |
| **Look Around** | Shibuya Crossing street-level, **~0.57 s** |
| Look Around, no coverage | `available` = 0 plus a warning, in ~0.16 s |

Requests only go out when a parameter changes (or you press **Reload**), so a static map costs
nothing per frame. While a request is in flight the previous image keeps showing; `busy` on the
Info CHOP tells you one is running.

## MapKit Live (flythrough)

A second op in this folder, **MapKit Live** (`Mapkitlive`), does what the snapshot op cannot:
**fly through the 3D map in real time**. Measured while animating heading and position from
expressions: **53 frames/sec received**, with TD itself still running at 64 fps.

It works the way Maps.app works — a **persistent `MKMapView`** kept alive in a borderless window,
captured with ScreenCaptureKit's `initWithDesktopIndependentWindow:`. The window sits at desktop
level (above the wallpaper, below the icons), joins no Mission Control spaces, and never takes
input focus. Set **Show Window** on to bring it forward for inspection.

Drive `Latitude / Longitude / Distance / Pitch / Heading` from expressions or CHOP exports and the
camera follows every frame. When nothing moves, ScreenCaptureKit only delivers frames on change, so
an idle map costs almost nothing.

What this costs, compared to the snapshot op:

- **Screen Recording permission** (same TCC grant as the Screen Capture TOP)
- A real window exists on the desktop layer of the screen
- Attribution comes from `MKMapView` itself (Apple logo and Legal link are part of the view)

The snapshot op stays the better choice for a static map: no permission, no window, and exact
metre-accurate spans.

### Why you cannot fly through the 3D view (with the snapshot op)

Measured, because it decides what is possible:

| | Measured |
|---|---|
| One snapshot, 640×360 | ~1.1 s |
| One snapshot, 2560×1440 | ~2.0 s |
| 8 requests in flight at once | **~1.4 frames/sec total** — the same as one at a time |

**Issuing requests in parallel does not help**; MapKit serialises them internally, so ~1.4 fps is a
hard ceiling no matter the size. And `MKMapView`, which does render continuously in 3D, **cannot be
captured offscreen** — `cacheDisplayInRect:` and `layer renderInContext:` both come back blank
because it draws with Metal.

So a live flythrough is not possible through the snapshot op — which is why **MapKit Live** above
exists. The third capture path that also failed, for the record: `CARenderer` renders a layer tree
into your own Metal texture, but a `CAMetalLayer`'s content lives in its presented drawables, which
belong to the window server — it "rendered" an empty layer in 0.08 ms.

### Look Around coverage is patchy

Shibuya Crossing has imagery; **Tokyo Station does not**. There is no way to ask MapKit for a
coverage map, so the op reports `available` on the Info CHOP and puts the reason in the node
warning. Check `available` before you rely on the picture.

### Span, pitch and heading

`Span (m)` means **how many metres across the ground you see** while pitch and heading are 0 — that
path uses a map region, which is the exact and intuitive behaviour. As soon as you tilt or rotate,
the op switches to a camera, and `Span` becomes the **camera distance** instead. The framing is
similar either way, but the number means something slightly different, which is worth knowing when
you animate through pitch 0.

### Parameters

| Parameter | Meaning |
|---|---|
| Mode | `Map` or `Look Around` |
| Latitude / Longitude | Centre of the view |
| Span (m) | Ground span, or camera distance once pitched/rotated (see above) |
| Style | Standard / Muted / Satellite / Hybrid |
| Elevation | Flat or `Realistic (3D)` — real building geometry, best with pitch |
| Pitch / Heading | Camera tilt and rotation |
| Show Traffic | Traffic overlay (Standard and Hybrid) |
| Show Points Of Interest | Shops, stations and so on |
| Dark Appearance | Renders the map in dark mode |
| Show Attribution | Burns "&#63743; Apple Maps" into a corner. **On by default** — see below |
| Attribution Position | Which corner |
| Reload | Request again without changing anything |

Resolution comes from the **Common** page, like the other generator TOPs. The default `Use Input` is
meaningless here (this op has no input), so it falls back to 1280×720.

Info CHOP: `executes / requests / renders / busy / available / width / height / request_ms`.

### Notes

- **Attribution is required, and is on by default.** Apple's guidelines ask that maps shown to an
  audience carry the Apple logo. The snapshot image does not contain one, so this op draws
  "&#63743; Apple Maps" into a corner itself, using the Apple logo glyph from the system font. Leave
  **Show Attribution** on unless you are adding your own — turning it off does not remove the
  obligation
- The imagery is fetched from Apple's servers — **this op needs a network connection**, and Apple
  rate-limits heavy use. Do not animate the coordinate every frame
- **MapKit raises Objective-C exceptions rather than returning errors.** A zero-area size makes
  `MKMapSnapshotOptions.size` raise, which took TouchDesigner down during development. Every MapKit
  call is wrapped now
- Look Around and the other network requests **deliver their completion on the main queue**. A
  command-line probe that blocks the main thread on a semaphore times out on all of them; TD pumps
  its main run loop, so it works there

### Build

```bash
cd MapKit && ./build.sh
```

---

## 日本語

Apple マップの画像 — 地図そのものと、**Look Around**(街並みの実写)— を TOP に出す。
API キーもアカウントも要らない。

> **状態: experimental(実験中)。**

### 動くこと(M2 / macOS 26.6 で実測)

| モード | 実測 |
|---|---|
| 地図(標準) | 渋谷 2560×1440 が **約0.9秒** |
| 地図(衛星 + `Realistic (3D)` + pitch 60°) | 実際の建物ジオメトリ。**約0.86秒** |
| 地図(ミュート + ダーク) | 約0.79秒 |
| **Look Around** | 渋谷スクランブルの街並み。**約0.57秒** |
| Look Around(カバー範囲外) | `available` = 0 と警告を約0.16秒で返す |

要求はパラメータが変わったとき(と **Reload**)だけ飛ぶので、動かさない地図は毎フレームの負荷が
ない。要求中は前の画像を出したままで、走っているかは Info CHOP の `busy` で分かる。

## MapKit Live(飛行)

このフォルダのもう1つのop、**MapKit Live**(`Mapkitlive`)がスナップショット版にできないことを
やる — **3D地図の中をリアルタイムに飛ぶ**。ヘディングと座標を式でアニメーションさせながらの実測で
**毎秒53フレーム受信**、TD 本体も 64 fps を維持した。

仕組みはマップ.app と同じで、**常駐の `MKMapView`** をボーダーレスウインドウに生かしっぱなしにし、
ScreenCaptureKit の `initWithDesktopIndependentWindow:` で取り込む。ウインドウはデスクトップレベル
(壁紙の上・アイコンの下)に置かれ、Mission Control にも入らず、フォーカスも奪わない。
確認したいときは **Show Window** で前面に出せる。

`Latitude / Longitude / Distance / Pitch / Heading` を式や CHOP エクスポートで駆動すれば、
カメラは毎フレーム追従する。動かしていないあいだは ScreenCaptureKit が変化時しかフレームを
寄越さないので、静止した地図はほぼコストゼロ。

スナップショット版と比べた代償:

- **画面収録の許可**(Screen Capture TOP と同じ TCC)
- 実ウインドウが画面のデスクトップ層に1枚存在する
- 帰属表示は `MKMapView` 自身が描く(Apple ロゴと Legal リンクがビューに含まれる)

静止した地図にはスナップショット版のほうが良い: 許可もウインドウも不要で、
メートル単位の正確な範囲指定ができる。

### スナップショット版で 3D の中を飛び回れない理由

何ができるかを決める数字なので実測した:

| | 実測 |
|---|---|
| 1枚(640×360) | 約1.1秒 |
| 1枚(2560×1440) | 約2.0秒 |
| 8枚を同時に要求 | **合計 約1.4枚/秒** — 1枚ずつと変わらない |

**並列に投げても速くならない。** MapKit が内部で直列化するので、サイズに関わらず 約1.4fps が
上限になる。一方、3Dを連続描画できる `MKMapView` は**オフスクリーンで取り込めない**
(`cacheDisplayInRect:` も `layer renderInContext:` も真っ白。Metal で描いているため)。

したがってスナップショット版でライブの飛行はできない — それが上の **MapKit Live** が存在する
理由。記録のために、3つ目の失敗した取り込み経路も書いておく: `CARenderer` はレイヤーツリーを
自前の Metal テクスチャに描くが、`CAMetalLayer` の中身は present 済み drawable にあり、
それはウインドウサーバーの持ち物 — 空のレイヤーを 0.08ms で「描いた」だけだった。

### Look Around のカバー範囲は飛び飛び

渋谷スクランブルには画像があるが、**東京駅には無い**。カバー範囲を問い合わせる API は無いので、
Info CHOP の `available` と、ノードの警告で理由を出している。**画に頼る前に `available` を見ること。**

### Span と pitch / heading

`Span (m)` は pitch と heading が 0 のあいだ **地上で何メートル見えるか**を意味する(この経路は
map region を使うので厳密)。傾けるか回した瞬間にカメラへ切り替わり、`Span` は**カメラまでの距離**に
なる。見え方は近いが数値の意味が変わるので、pitch 0 をまたいでアニメートするときは注意。

### パラメータ

| パラメータ | 意味 |
|---|---|
| Mode | `Map` か `Look Around` |
| Latitude / Longitude | 中心の緯度経度 |
| Span (m) | 地上の範囲。傾け/回すとカメラ距離になる(上記) |
| Style | 標準 / ミュート / 衛星 / ハイブリッド |
| Elevation | Flat か `Realistic (3D)`。実際の建物ジオメトリ。pitch と併用が映える |
| Pitch / Heading | カメラの傾きと回転 |
| Show Traffic | 交通情報(標準・ハイブリッド) |
| Show Points Of Interest | 店舗や駅などの表示 |
| Dark Appearance | 地図をダークで描く |
| Show Attribution | 「&#63743; Apple Maps」を隅に焼き込む。**既定でオン**(後述) |
| Attribution Position | どの隅に出すか |
| Reload | 設定を変えずにもう一度取得する |

解像度は他の生成系 TOP と同じく **Common** ページから。入力を持たないので既定の `Use Input` は
無意味 → 1280×720 にフォールバックする。

Info CHOP: `executes / requests / renders / busy / available / width / height / request_ms`。

### 注意

- **帰属表示は必要で、既定でオン。** Apple のガイドラインは、人に見せる地図に Apple ロゴを
  添えることを求めている。スナップショット画像には含まれないので、このopが自分で
  「&#63743; Apple Maps」を隅に描く(システムフォントの Apple ロゴのグリフを使用)。
  自分で別に付ける場合を除き **Show Attribution** はオンのままにする。
  オフにしても義務が消えるわけではない
- 画像は Apple のサーバーから取得する。**ネットワークが要る**し、過剰な利用はレート制限される。
  座標を毎フレーム動かすような使い方はしない
- **MapKit はエラーを返さず Objective-C 例外を投げる。** 面積 0 のサイズを渡すと
  `MKMapSnapshotOptions.size` が raise し、開発中に TouchDesigner ごと落ちた。現在は全ての
  MapKit 呼び出しを受け止めてある
- Look Around などネットワーク系は**完了ハンドラがメインキューに来る**。メインスレッドを
  セマフォで塞ぐ単体CLIでは全部タイムアウトする。TD はメインランループを回すので問題ない

### ビルド

```bash
cd MapKit && ./build.sh
```
