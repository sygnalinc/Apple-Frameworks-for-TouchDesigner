# Semantic Index DAT

macOS の **Spotlight ローカル索引**を `NSMetadataQuery` で検索し、結果(名前/パス/種別/更新日時)を
テーブル出力する。名前・内容(全文)・生 `kMDItem` 述語での検索に対応。OS全体のファイル索引を返す。

## 実測(M2)

- Query="README" (Name) → 15件を取得、first=`README.ja.md`。実データ検索を確認

## パラメータ

| パラメータ | 説明 |
|---|---|
| Query | 検索語(Name/Content)または述語(Raw) |
| Mode | Name(名前一致)/ Content(全文)/ Raw(`kMDItem*` 述語) |
| Max Results | 最大件数 |
| Search | 再検索(パルス。Query/Mode変更でも自動再検索) |

出力: `name / path / kind / modified`(更新日時はUnix秒)。Info CHOP: `executes / results`

## 注意

- **`startQuery` は run loop のあるスレッド(メイン)で呼ぶ**。TDのcookスレッドから直接呼ぶと通知が
  発火しない → メインキューへdispatch(実装済み)
- **CoreSpotlight の CSUserQuery は不採用**。アプリ自身の索引項目/エンタイトルメントが必要で、
  プラグイン文脈では0件になる。OS全体のファイル索引には `NSMetadataQuery`(Spotlight)が正解
- Content(全文)検索や一部フォルダは Spotlight の索引対象/プライバシー設定に依存する

## ビルド
```
cd SemanticIndex && ./build.sh
```
