# Multipeer DAT

**Mac/iPhone/iPad間のローカルP2Pメッセージング**(MultipeerConnectivity)。
同じ Service Type のピアを自動発見・自動接続し、テキストを送受信する。
サーバー不要・Wi-Fi/有線/Bluetooth自動選択。マルチマシン展示の同期、
iPhoneをセンサー/リモコン化する用途に。

## 実測(M2)

- 同一マシン上の2ノード(td-mac / td-mac-b)が**自動で相互接続し、
  入力DATの内容("hello from A")が相手側テーブルに届く**ことを確認

## 使い方

- 送信: 入力DATの内容(TSV文字列化)が**変わるたびに自動送信**(Auto Send)。Sendパルスで手動も
- 受信: 出力テーブルに `type=peer`(接続中ピア)と `type=msg`(peer/message履歴)が並ぶ
- iOS側: MultipeerConnectivityで同じserviceTypeを名乗る簡単なアプリ/Playgroundで繋がる

## パラメータ

`Peer Name / Service Type(1〜15文字・英小文字数字とハイフン)/ Auto Send / Send /
Max Messages`

## 注意

- 初回はmacOSの**ローカルネットワーク許可**ダイアログが出ることがある
- 表示名の辞書順で片方向のみ招待する(二重接続防止)。同名ピアは避ける

## ビルド

```
cd Multipeer && ./build.sh   # → build/MultipeerDAT.plugin
```
