# Screen Capture TOP

ScreenCaptureKitでmacOSのディスプレイまたは単一ウインドウを非同期キャプチャするTOP。

実測（M2 / 内蔵ディスプレイ）: 1710x1112 BGRA8を取得し、エラー・警告なし。

## 出力

BGRA8 TOP。Source TypeとIndexで対象を選び、0指定ならネイティブ解像度を使用する。
Info CHOPは`executes / frames / running / sources / width / height`。

## パラメータ

Source Type(Display / Window)、**Window**(window時=ウインドウ名のプルダウンから選択)、
Display Index(display時)、出力Width/Height、Frame Rate、Show Cursor、Restart Capture。

- **Window** は「アプリ名 - ウインドウタイトル」の**動的プルダウン**(現在開いている
  ウインドウを列挙)。内部値はウインドウID(安定)で選択するため、一覧順が変わっても選択が
  ずれない。約2秒ごと / Restart で一覧を更新
- Display モードは Display Index で選ぶ

## 注意

- **TouchDesigner Non-Commercial** では解像度が 1280x1280 に制限される。上限を超える出力は**自動で上限内へ縮小**し、その旨を警告に出す(縮小しないと TD 側で絵が崩れるため)。フル解像度が要るなら商用ライセンスを使う

初回はmacOSの画面収録権限が必要。許可後にTouchDesignerの再起動が必要な場合がある。
ウインドウのプルダウンは非同期で列挙するため、作成直後は数百msで埋まる。選んだウインドウが
閉じられた場合は Restart で選び直す。

## ビルド

```sh
./build.sh
```
