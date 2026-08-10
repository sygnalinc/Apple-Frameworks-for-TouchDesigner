#!/bin/bash
# Apple Frameworks for TouchDesigner リリースビルド: Developer ID 深署名 → 検証 → DMG → 公証 → ステープル
#
# 使い方:
#   tools/release.sh sign      # リポジトリのビルド成果物を dist/ へ集めて深署名
#   tools/release.sh verify    # dist/ の全バンドルを codesign 検証
#   tools/release.sh dmg       # dist/ から配布DMGを作成し署名
#   tools/release.sh notarize  # DMGを公証(要: notarytool keychain-profile)→ステープル
#   tools/release.sh all       # sign → verify → dmg → notarize
#
# 前提:
#   - キーチェーンに "Developer ID Application: SYGNAL INC." の秘密鍵があること
#   - notarize には一度だけ: xcrun notarytool store-credentials "$NOTARY_PROFILE"
#     (App Store Connect APIキー または Apple ID+app用パスワード。ユーザーが実行)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$REPO/VERSION")"
SIGN_ID="${SIGN_ID:-Developer ID Application: SYGNAL INC. (2ZSD5ZZLKB)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-tdappleops}"
# 配布物は「main が追跡しているプラグインフォルダの build/ 成果物」だけを集める。
# ユーザーの常設 Plugins フォルダから集めるとサードパーティ製(Azure Kinect 等)が
# 混入するため、必ずリポジトリ由来にすること。
DIST="$REPO/dist/Apple-Frameworks-for-TouchDesigner-v$VERSION"
DMG="$REPO/dist/Apple-Frameworks-for-TouchDesigner-v$VERSION.dmg"

CS=(codesign -f --timestamp --options runtime -s "$SIGN_ID")

# 現在の TD SDK が期待する OP_CommonAPIVersion(バンドルの宣言値と一致必須)
SDK_ROOT="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus"
EXPECT_COMMON="$(grep -h -m1 'OP_CommonAPIVersion = ' "$SDK_ROOT/CHOP/CPlusPlus_Common.h" | sed 's/[^0-9]*\([0-9]*\).*/\1/')"

# 1バンドルを内側から深署名(dylib → ネスト.app/framework → ヘルパ実行ファイル → 本体)
sign_bundle() {
    local b="$1"
    # ネストした dylib
    find "$b" -type f -name "*.dylib" -print0 | while IFS= read -r -d '' f; do
        "${CS[@]}" "$f"
    done
    # ネストした .framework / .app (深い階層から)
    find "$b" -type d \( -name "*.framework" -o -name "*.app" \) -print0 |
        while IFS= read -r -d '' d; do echo "${#d} $d"; done | sort -rn | cut -d' ' -f2- |
        while IFS= read -r d; do
            "${CS[@]}" "$d"
        done
    # Helpers 直下のスタンドアロン Mach-O 実行ファイル
    if [ -d "$b/Contents/Helpers" ]; then
        find "$b/Contents/Helpers" -maxdepth 1 -type f -perm +111 -print0 |
            while IFS= read -r -d '' f; do
                file -b "$f" | grep -q "Mach-O" && "${CS[@]}" "$f"
            done
    fi
    # バンドル本体
    "${CS[@]}" "$b"
}

cmd_sign() {
    echo "== sign: repo builds → $DIST (identity: $SIGN_ID)"
    rm -rf "$DIST"; mkdir -p "$DIST"
    local n=0
    while read -r d; do
        for b in "$REPO/$d"/build/*.plugin; do
            [ -d "$b" ] || continue
            cp -R "$b" "$DIST/"
            n=$((n+1))
        done
    done < <(cd "$REPO" && git ls-files '*/build.sh' | sed 's|/build.sh||')
    echo "copied $n bundles (from repo builds)"
    # 各プラグインのビルド時点の版が残らないよう、配布物へ現在の VERSION を焼き直す。
    # **署名より前**に行う(Info.plist を後から書き換えると署名が壊れるため)
    local build; build="$(cd "$REPO" && git rev-list --count HEAD)"
    for b in "$DIST"/*.plugin; do
        local pl="$b/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$pl" >/dev/null 2>&1 \
            || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$pl" >/dev/null 2>&1
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$pl" >/dev/null 2>&1 \
            || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build" "$pl" >/dev/null 2>&1
    done
    echo "stamped version $VERSION (build $build)"
    # 並列署名(timestampサーバ往復があるため)。スクリプト自身を再入呼び出し
    ls -d "$DIST"/*.plugin | xargs -P 6 -I{} "$REPO/tools/release.sh" _sign_one "{}"
    echo "== sign done"
}

cmd_verify() {
    echo "== verify: $DIST (expect OP_CommonAPIVersion=$EXPECT_COMMON)"
    local fail=0
    # 現行 TD SDK と API バージョンが合わないバンドルを検出する。
    # (TD をダウングレードした環境では新SDKビルドが残りやすく、TD は
    #  "invalid opType name" という無関係に見えるエラーで拒否する)
    local scan="$REPO/dist/.apiscan"
    cc -o "$scan" "$REPO/tools/apiscan.c" 2>/dev/null
    for b in "$DIST"/*.plugin; do
        if ! codesign --verify --deep --strict "$b" 2>/dev/null; then
            echo "VERIFY FAIL: $(basename "$b")"; fail=1
        fi
        # Hardened Runtime + Developer ID で署名されているか
        # (grep -q は pipefail + SIGPIPE で誤検知するため出力を変数に取る)
        local info; info="$(codesign -dvv "$b" 2>&1)"
        if [[ "$info" != *"flags=0x10000(runtime)"* ]]; then
            echo "NO HARDENED RUNTIME: $(basename "$b")"; fail=1
        fi
        if [[ "$info" != *"Developer ID Application"* ]]; then
            echo "NOT DEVELOPER ID: $(basename "$b")"; fail=1
        fi
        local sv; sv="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$b/Contents/Info.plist" 2>/dev/null)"
        if [ "$sv" != "$VERSION" ]; then
            echo "VERSION MISMATCH: $(basename "$b") -> $sv (expected $VERSION)"; fail=1
        fi
        if [ -x "$scan" ]; then
            local api; api="$("$scan" "$b/Contents/MacOS/$(basename "$b" .plugin)" 2>/dev/null)"
            if [[ "$api" != *"common=$EXPECT_COMMON"* ]]; then
                echo "API VERSION MISMATCH: $(basename "$b") -> $api"; fail=1
            fi
        fi
    done
    [ $fail -eq 0 ] && echo "== all $(ls -d "$DIST"/*.plugin | wc -l | tr -d ' ') bundles verified OK"
    return $fail
}

cmd_dmg() {
    echo "== dmg: $DMG"
    rm -f "$DMG"
    # インストール手順を同梱
    cat > "$DIST/INSTALL.txt" <<EOF
Apple Frameworks for TouchDesigner v$VERSION — Apple-native custom operators (macOS / Apple Silicon)

Install:
  Copy the .plugin bundles you want into:
    ~/Library/Application Support/Derivative/TouchDesigner099/Plugins/
  Then restart TouchDesigner.

https://github.com/sygnalinc/Apple-Frameworks-for-TouchDesigner
EOF
    hdiutil create -volname "Apple Frameworks for TouchDesigner v$VERSION" -srcfolder "$DIST" -ov -format UDZO "$DMG" >/dev/null
    codesign -f --timestamp -s "$SIGN_ID" "$DMG"
    echo "== dmg done: $DMG ($(du -h "$DMG" | cut -f1))"
}

# 各 .plugin に公証チケットを貼ってから DMG を作り直す。
# **これをしないと、DMGから取り出した .plugin にはチケットが無く**、
# 中の wifiscan-helper.app のような入れ子のアプリを起動しようとした瞬間に
# Gatekeeper が「マルウェアが含まれていないことを検証できませんでした」で止める(実測)。
# DMG に貼ったチケットはコピーすると失われるので、バンドル個別に貼る必要がある。
cmd_staple_plugins() {
    local zip="$REPO/dist/plugins-v$VERSION.zip"
    echo "== notarize plugins (チケットを各 .plugin に貼るため)"
    rm -f "$zip"
    ( cd "$DIST" && /usr/bin/ditto -c -k --keepParent --sequesterRsrc . "$zip" )
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$zip"
    local n=0
    for b in "$DIST"/*.plugin; do
        xcrun stapler staple "$b" >/dev/null || { echo "  ステープル失敗: $(basename "$b")"; exit 1; }
        n=$((n+1))
    done
    echo "== $n 個の .plugin にステープル済み"
}

cmd_notarize() {
    cmd_staple_plugins          # 先にバンドル個別へチケットを貼る
    cmd_dmg                     # 貼った状態で DMG を作り直す
    echo "== notarize: $DMG (profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "== notarize done. Gatekeeper check:"
    spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 || true
    echo "== 各 .plugin のチケット確認:"
    for b in "$DIST"/*.plugin; do
        xcrun stapler validate "$b" >/dev/null 2>&1 || echo "  チケット無し: $(basename "$b")"
    done
    echo "   (何も出なければ全て貼れている)"
}

case "${1:-}" in
    _sign_one)
        b="$2"
        if sign_bundle "$b" >/dev/null 2>"/tmp/relsign_err_$(basename "$b").log"; then
            rm -f "/tmp/relsign_err_$(basename "$b").log"
            echo "signed: $(basename "$b")"
        else
            echo "SIGN FAIL: $(basename "$b")"
            cat "/tmp/relsign_err_$(basename "$b").log"
            exit 1
        fi ;;
    sign)     cmd_sign ;;
    verify)   cmd_verify ;;
    dmg)      cmd_dmg ;;
    notarize) cmd_notarize ;;
    all)      cmd_sign && cmd_verify && cmd_dmg && cmd_notarize ;;
    *) echo "usage: $0 {sign|verify|dmg|notarize|all}"; exit 1 ;;
esac
