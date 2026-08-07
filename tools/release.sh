#!/bin/bash
# TDAppleOps リリースビルド: Developer ID 深署名 → 検証 → DMG → 公証 → ステープル
#
# 使い方:
#   tools/release.sh sign      # インストール済み全pluginを dist/ へコピーして深署名
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
SRC="${SRC:-$HOME/Library/Application Support/Derivative/TouchDesigner099/Plugins}"
DIST="$REPO/dist/TDAppleOps-v$VERSION"
DMG="$REPO/dist/TDAppleOps-v$VERSION.dmg"

CS=(codesign -f --timestamp --options runtime -s "$SIGN_ID")

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
    echo "== sign: $SRC → $DIST (identity: $SIGN_ID)"
    rm -rf "$DIST"; mkdir -p "$DIST"
    local n=0
    for b in "$SRC"/*.plugin; do
        cp -R "$b" "$DIST/"
        n=$((n+1))
    done
    echo "copied $n bundles"
    # 並列署名(timestampサーバ往復があるため)。スクリプト自身を再入呼び出し
    ls -d "$DIST"/*.plugin | xargs -P 6 -I{} "$REPO/tools/release.sh" _sign_one "{}"
    echo "== sign done"
}

cmd_verify() {
    echo "== verify: $DIST"
    local fail=0
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
    done
    [ $fail -eq 0 ] && echo "== all $(ls -d "$DIST"/*.plugin | wc -l | tr -d ' ') bundles verified OK"
    return $fail
}

cmd_dmg() {
    echo "== dmg: $DMG"
    rm -f "$DMG"
    # インストール手順を同梱
    cat > "$DIST/INSTALL.txt" <<EOF
TDAppleOps v$VERSION — TouchDesigner Apple-native custom operators (macOS / Apple Silicon)

Install:
  Copy the .plugin bundles you want into:
    ~/Library/Application Support/Derivative/TouchDesigner099/Plugins/
  Then restart TouchDesigner.

https://github.com/sygnalinc/TDAppleOps
EOF
    hdiutil create -volname "TDAppleOps v$VERSION" -srcfolder "$DIST" -ov -format UDZO "$DMG" >/dev/null
    codesign -f --timestamp -s "$SIGN_ID" "$DMG"
    echo "== dmg done: $DMG ($(du -h "$DMG" | cut -f1))"
}

cmd_notarize() {
    echo "== notarize: $DMG (profile: $NOTARY_PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "== notarize done. Gatekeeper check:"
    spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 || true
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
