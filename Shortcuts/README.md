# Shortcuts DAT

**macOSショートカット(Shortcuts.app)をTDから実行**する。HomeKit照明・家電・Music再生・
通知・他アプリ連携など、ショートカットにできることは全て TD のイベント(パルス)から叩ける。

## 使い方

1. **List Shortcuts** をパルス → 利用可能な一覧がテーブルに出る(読み取りのみ・安全)
2. **Shortcut Name** に一覧の名前を正確に入れて **Run** をパルス
3. 入力: **Input Text**、または入力DATの cell(0,0) がショートカットの入力になる
4. 出力テーブル: `status / shortcut / output / took_ms`

## Run Method(重要 — ここでハマる)

| Method | 動作 | 出力 | 用途 |
|---|---|---|---|
| **App (shortcuts://)** 既定 | `open shortcuts://run-shortcut` で **Shortcuts.app に委譲** | ✗ 返らない | **Music再生・照明・通知など「動作」させる**もの(ほぼ全部) |
| CLI (output) | `shortcuts run` を直接実行 | ○ テキストが返る | 純粋に**値を返すだけ**のショートカット |

**なぜ App 方式が既定か**: TouchDesigner から `shortcuts run` CLI を直接叩くと、**TDのプロセス
権限で実行**され、Music/HomeKit等の外部アプリを操作するショートカットは
「ショートカットが見つかりませんでした」という紛らわしいエラーで**失敗する**(実測)。
App方式は権限を持つ **Shortcuts.app 側で走る**ので確実に動く。ただし出力テキストは受け取れない。

→ **動作させたいだけなら App(既定)、出力が欲しいなら CLI**。CLI で失敗するショートカットは
TD に権限が無いのが原因(macOS の仕様)。

## 実測(M2・macOS 26.5.1)

- List: ユーザーの実ショートカット21件を一覧取得
- Run(App方式): 「今聴いているアルバムの全曲を再生」を実行 → **Music.app が `playing` に**(TDのOPから)
- CLI方式で同じショートカットを実行すると「見つかりません」エラー(TD権限不足)を確認 → App方式で解決

## パラメータ

| パラメータ | 説明 |
|---|---|
| Shortcut Name | 実行するショートカット名(List でコピー) |
| Input Text | ショートカットへの入力(入力DATがあればその cell(0,0) を優先) |
| Run Method | app(Shortcuts.app委譲・既定)/ cli(出力を返す) |
| Run | 実行(パルス) |
| List Shortcuts | 一覧取得(パルス) |

## 注意

- **Run は押した瞬間に即実行**。施錠/開錠・購入等の副作用ショートカットは配線に注意
- 実行はワーカースレッド(cook非ブロック)。結果は 1〜数フレーム遅れで反映
- パルスは「cook でジョブ投入 → ワーカー実行 → 次の cook で結果反映」の流れ
- 出力をどこかで使う(null DAT等に繋ぐ)と毎フレーム cook され結果が確実に反映される

## ビルド

```
cd Shortcuts && ./build.sh   # → build/ShortcutsDAT.plugin
```
