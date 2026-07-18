# Screen Capture TOP

ScreenCaptureKitでmacOSのディスプレイまたは単一ウインドウを非同期キャプチャするTOP。

実測（M2 / 内蔵ディスプレイ）: 1710x1112 BGRA8を取得し、エラー・警告なし。

## 出力

BGRA8 TOP。Source TypeとIndexで対象を選び、0指定ならネイティブ解像度を使用する。
Info CHOPは`executes / frames / running / sources / width / height`。

## パラメータ

Display/Window、Source Index、出力Width/Height、Frame Rate、Show Cursor、Restart Capture。

## 注意

初回はmacOSの画面収録権限が必要。許可後にTouchDesignerの再起動が必要な場合がある。
ウインドウ一覧は画面上に存在するものだけを対象とし、Indexは一覧順なので起動状況で変化する。

## ビルド

```sh
./build.sh
```
