#!/bin/zsh
# バージョン情報の単一ソース。各 build.sh から source して使う。
#   TD_VERSION … リポジトリ直下の VERSION ファイル(例 0.9.0)= CFBundleShortVersionString
#   TD_BUILD   … git のコミット数 = CFBundleVersion(ビルド番号)
# td_stamp_all を .plugin 生成後に呼ぶと Info.plist へ焼き込み+再署名する。
TD_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ..)"
TD_VERSION="$(cat "$TD_REPO_ROOT/VERSION" 2>/dev/null || echo 0.0.0)"
TD_BUILD="$(git -C "$TD_REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"

# $1 = .plugin へのパス。Info.plist にバージョンを書き込み、署名を作り直す
td_stamp_version() {
    local plist="$1/Contents/Info.plist"
    [ -f "$plist" ] || return 0
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $TD_VERSION" "$plist" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $TD_VERSION" "$plist" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TD_BUILD" "$plist" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $TD_BUILD" "$plist" >/dev/null 2>&1
    codesign --force --deep -s - "$1" >/dev/null 2>&1   # plist改変で署名が壊れるので再署名
}

# build/ 配下の全 .plugin にバージョンを焼く(1フォルダ2バンドルにも対応)
td_stamp_all() {
    local b
    for b in build/*.plugin; do
        [ -e "$b" ] && td_stamp_version "$b"
    done
    echo "stamped version $TD_VERSION (build $TD_BUILD)"
}
