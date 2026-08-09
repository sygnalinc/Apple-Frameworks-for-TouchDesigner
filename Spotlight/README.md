# Spotlight DAT

**English** | [日本語](#日本語)

## English

Searches macOS's **Spotlight local index** with `NSMetadataQuery` and outputs the results (name /
path / kind / modified) as a table. Supports search by name, by content (full text) and by raw
`kMDItem` predicate. It returns the OS-wide file index.

### Measured (M2)

- Query = "README" (Name) → 15 results, first = `README.ja.md`. Real-data search confirmed

### Parameters

| Parameter | Description |
|---|---|
| Query | Search term (Name/Content) or a predicate (Raw) |
| Mode | Name (name match) / Content (full text) / Raw (`kMDItem*` predicate) |
| Max Results | Maximum results |
| Search | Search again (pulse; a Query/Mode change also re-searches automatically) |

Output: `name / path / kind / modified` (modified is Unix seconds). Info CHOP: `executes / results`

### Notes

- **`startQuery` must be called on a thread with a run loop (the main one).** Calling it directly
  from TD's cook thread means the notifications never fire — it is dispatched to the main queue
  (already implemented)
- **CoreSpotlight's CSUserQuery is deliberately not used.** It needs the app's own indexed items
  and entitlements, and returns nothing in a plugin context. For the OS-wide file index,
  `NSMetadataQuery` (Spotlight) is the right answer
- Content (full-text) search and some folders depend on what Spotlight indexes and on privacy
  settings

### Build

```
cd Spotlight && ./build.sh
```

## 日本語

macOS の **Spotlight ローカル索引**を `NSMetadataQuery` で検索し、結果(名前/パス/種別/更新日時)を
テーブル出力する。名前・内容(全文)・生 `kMDItem` 述語での検索に対応。OS全体のファイル索引を返す。

### 実測(M2)

- Query="README" (Name) → 15件を取得、first=`README.ja.md`。実データ検索を確認

### パラメータ

| パラメータ | 説明 |
|---|---|
| Query | 検索語(Name/Content)または述語(Raw) |
| Mode | Name(名前一致)/ Content(全文)/ Raw(`kMDItem*` 述語) |
| Max Results | 最大件数 |
| Search | 再検索(パルス。Query/Mode変更でも自動再検索) |

出力: `name / path / kind / modified`(更新日時はUnix秒)。Info CHOP: `executes / results`

### 注意

- **`startQuery` は run loop のあるスレッド(メイン)で呼ぶ**。TDのcookスレッドから直接呼ぶと通知が
  発火しない → メインキューへdispatch(実装済み)
- **CoreSpotlight の CSUserQuery は不採用**。アプリ自身の索引項目/エンタイトルメントが必要で、
  プラグイン文脈では0件になる。OS全体のファイル索引には `NSMetadataQuery`(Spotlight)が正解
- Content(全文)検索や一部フォルダは Spotlight の索引対象/プライバシー設定に依存する

### ビルド

```
cd Spotlight && ./build.sh
```
