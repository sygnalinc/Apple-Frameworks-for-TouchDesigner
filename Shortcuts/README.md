# Shortcuts DAT

**macOSショートカット(Shortcuts.app)をTDから実行**する(`/usr/bin/shortcuts` CLI経由)。
HomeKit照明・家電・通知・他アプリ連携など、ショートカットにできることは全て
TDのイベントから叩ける。

## 実測(M2)

- List Shortcuts でユーザーの実ショートカット一覧(21件)を取得確認
- 実行はワーカースレッド(cook非ブロック)。結果テキストと所要msをテーブル出力

## 使い方

1. List Shortcuts をパルス → 利用可能な一覧がテーブルに出る
2. Shortcut Name に名前を入れ、Run をパルス
3. 入力: 入力DATの cell(0,0) または Input Text がショートカットの入力になる
4. 出力テーブル: `status / shortcut / output / took_ms`

## 注意

- ショートカット側の権限確認(HomeKit等)は初回にmacOSのダイアログが出ることがある
- 実行に時間がかかるものは `running` 警告が出続ける(Info CHOP `running`=1)
- 副作用のあるショートカット(施錠・購入等)はTDのパルスで即実行される。配線に注意

## ビルド

```
cd Shortcuts && ./build.sh   # → build/ShortcutsDAT.plugin
```
