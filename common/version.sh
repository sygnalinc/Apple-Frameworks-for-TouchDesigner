#!/bin/zsh
# バージョン情報の単一ソース。各 build.sh から source して使う。
#   TD_VERSION … リポジトリ直下の VERSION ファイル(例 0.9.0)= CFBundleShortVersionString
#   TD_BUILD   … git のコミット数 = CFBundleVersion(ビルド番号)
# td_stamp_all を .plugin 生成後に呼ぶと Info.plist へ焼き込み+再署名する。
# 最低対応 macOS の単一ソース。**未指定だとビルドしたマシンのOSが焼き込まれる**ので必ず固定する。
#   macOS 27 beta 機でビルドすると minos 27.0 になり、27のAPIを1行も使っていなくても
#   macOS 26 では dyld がロードを拒否する(配布物なら全ユーザーが起動できなくなる)。
#
# 実測(macOS 26.6 / Xcode 26.4):
#   MACOSX_DEPLOYMENT_TARGET は **clang++ には効くが swiftc には効かない**(26.0のままだった)。
#   swiftc は `-target $TD_SWIFT_TARGET` の明示が必須。
TD_MIN_MACOS="${TD_MIN_MACOS:-26.0}"
export MACOSX_DEPLOYMENT_TARGET="$TD_MIN_MACOS"      # clang++ 用

# どの TouchDesigner の SDK でビルドしているかを毎回表示する。
# common/build_plugin.sh を通らない手組みの build.sh(1フォルダ複数バンドル・SPM 等)でも
# ここは必ず source されるので、全ビルドに出る。TD_APP 無しで 33070 の SDK を掴んで
# common=2 のバンドルを作り、TD 32280 に「plugin not found」と言われる事故を実際に起こした
_td_app="${TD_APP:-/Applications/TouchDesigner.app}"
_td_ver="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$_td_app/Contents/Info.plist" 2>/dev/null || echo "?")"
echo "TD SDK: $_td_app ($_td_ver)  [TD_APP で切替]"
unset _td_app _td_ver
TD_SWIFT_TARGET="arm64-apple-macos$TD_MIN_MACOS"     # swiftc 用(-target で明示すること)

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
