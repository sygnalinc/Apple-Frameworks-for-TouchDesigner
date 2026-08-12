# Screen Capture TOP

**English** | [日本語](#日本語)

## English

Asynchronously captures a macOS display or a single window with ScreenCaptureKit.

Measured (M2, built-in display): 1710x1112 BGRA8 captured, no errors or warnings.

### Output

A BGRA8 TOP. Pick the target with Source Type and Index; 0 uses the native resolution.
Info CHOP: `executes / frames / running / sources / width / height`.

### Parameters

Source Type (Display / Window), **Window** (in window mode — chosen from a dropdown of window
names), Display Index (in display mode), output Width/Height, Frame Rate, Show Cursor, Restart
Capture.

- **Window** is a **dynamic dropdown** of "app name - window title" listing the windows currently
  open. The internal value is the (stable) window ID, so the selection does not shift when the
  list reorders. The list refreshes roughly every two seconds and on Restart
- In Display mode, choose with Display Index

### Notes

- Under **TouchDesigner Non-Commercial** the resolution is capped at 1280x1280. Output above the
  cap is **scaled down automatically** with a warning (without it TD renders garbage). Use a
  commercial license if you need full resolution.

macOS screen-recording permission is required the first time; TouchDesigner may need restarting
after granting it. The window dropdown is enumerated asynchronously, so it fills in a few hundred
milliseconds after creation. If the selected window is closed, use Restart and pick again.

### Build

```sh
./build.sh
```

## 日本語

ScreenCaptureKitでmacOSのディスプレイまたは単一ウインドウを非同期キャプチャするTOP。

実測（M2 / 内蔵ディスプレイ）: 1710x1112 BGRA8を取得し、エラー・警告なし。

### 出力

BGRA8 TOP。Source TypeとIndexで対象を選び、0指定ならネイティブ解像度を使用する。
Info CHOPは`executes / frames / running / sources / width / height`。

### パラメータ

Source Type(Display / Window)、**Window**(window時=ウインドウ名のプルダウンから選択)、
Display Index(display時)、出力Width/Height、Frame Rate、Show Cursor、Restart Capture。

- **Window** は「アプリ名 - ウインドウタイトル」の**動的プルダウン**(現在開いている
  ウインドウを列挙)。内部値はウインドウID(安定)で選択するため、一覧順が変わっても選択が
  ずれない。約2秒ごと / Restart で一覧を更新
- Display モードは Display Index で選ぶ

### 注意

- **TouchDesigner Non-Commercial** では解像度が 1280x1280 に制限される。上限を超える出力は**自動で上限内へ縮小**し、その旨を警告に出す(縮小しないと TD 側で絵が崩れるため)。フル解像度が要るなら商用ライセンスを使う

初回はmacOSの画面収録権限が必要。許可後にTouchDesignerの再起動が必要な場合がある。
ウインドウのプルダウンは非同期で列挙するため、作成直後は数百msで埋まる。選んだウインドウが
閉じられた場合は Restart で選び直す。

### ビルド

```sh
./build.sh
```
