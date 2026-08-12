#!/bin/zsh
# TDAppleML 共通ビルドヘルパ。各プラグインの build.sh から呼ぶ。
#
# 使い方（プラグインディレクトリの build.sh 内）:
#   source ../common/build_plugin.sh
#   build_td_plugin <PluginName> <bundle-id-suffix> <sources...> -- <frameworks...>
#
# 例:
#   build_td_plugin VisionPoseCHOP visionpose-chop VisionPoseCHOP.mm -- Vision CoreVideo
#
# 前提: Xcode（clang++）と TouchDesigner.app（C++ SDK ヘッダを流用）
set -e

# **このファイルは zsh 専用**（配列 append `arr+="x"` など zsh 固有の記法を使う）。
# 呼び出し側の build.sh も必ず #!/bin/zsh にすること。#!/bin/bash から source すると
# ${(%):-%N} が "bad substitution" になり、set -e で**何もビルドされないまま無言で中断**する
# （実際に CoreImageCode 等6件がこの状態でビルド不能になっていた）。
source "$(dirname "${(%):-%N}")/version.sh"

TD_SDK="${TD_SDK:-/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CHOP}"

build_td_plugin() {
    local name="$1"; shift
    local bundle_suffix="$1"; shift
    local sources=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        sources+="$1"; shift
    done
    shift   # "--"
    local fw_flags=(-framework Foundation)
    for f in "$@"; do
        fw_flags+=(-framework "$f")
    done

    local out="build/$name.plugin/Contents"
    rm -rf build
    mkdir -p "$out/MacOS"

    # 任意の追加フラグ（Python.h を使う CHOP 等）。既定は空で他プラグインに影響しない。
    local extra_flags=(${=TD_EXTRA_CFLAGS})
    clang++ -std=c++17 -fobjc-arc -O2 -bundle \
        -I "$TD_SDK" \
        "${extra_flags[@]}" \
        "${sources[@]}" \
        "${fw_flags[@]}" \
        -o "$out/MacOS/$name"

    cat > "$out/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$name</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.$bundle_suffix</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

    td_stamp_version "build/$name.plugin"   # バージョンを焼いてから署名
    codesign --force -s - "build/$name.plugin"
    echo "built: $(pwd)/build/$name.plugin"
}
