#!/bin/zsh
# MLX LLM DAT のビルド → build/MLXLLMDAT.plugin
#
# 重要: mlx-swift の Metal シェーダ（default.metallib）は **SwiftPM の swift build
# （コマンドライン）ではビルドできない**（mlx-swift 公式README明記）。必ず xcodebuild で
# ビルドし、生成される mlx-swift_Cmlx.bundle（metallib入り）を実行ファイルの隣へ同梱する。
#
# 構成: helper(Swiftパッケージ・mlx-swift-lm) を xcodebuild でビルド、
#       .plugin/Contents/Helpers/ に実行ファイル + metallib バンドル + tokenizer バンドルを同梱。
#       DAT本体(.mm)はそのヘルパを別プロセスとして spawn し JSON-lines で通信する。
set -e
cd "$(dirname "$0")"

source ../common/version.sh

# xcodebuild は**フルXcodeが必要**。xcode-select が CommandLineTools を指している環境では
# 素で叩くと "requires Xcode, but active developer directory ... is a command line tools
# instance" で落ちる。xcode-select --switch はグローバル変更で sudo が要るので、
# **このビルドの間だけ DEVELOPER_DIR でフルXcodeを指す**(他プラグインのCLTビルドに影響しない)。
# 既に DEVELOPER_DIR が設定されていればそれを尊重する。
if ! xcodebuild -version >/dev/null 2>&1; then
    for _xc in /Applications/Xcode.app /Applications/Xcode-beta.app \
               "/Volumes/Macintosh HD - Data/Applications/Xcode.app" \
               "/Volumes/Macintosh HD/Applications/Xcode.app"; do
        if [ -x "$_xc/Contents/Developer/usr/bin/xcodebuild" ]; then
            export DEVELOPER_DIR="$_xc/Contents/Developer"
            echo "using DEVELOPER_DIR=$DEVELOPER_DIR"
            break
        fi
    done
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "ERROR: xcodebuild が見つかりません。LLMMLX は mlx-swift の Metal シェーダを"
    echo "       コンパイルするためフルXcodeが必要です(swift build では metallib が作れない)。"
    echo "       Xcode を入れるか、DEVELOPER_DIR=<Xcode.app>/Contents/Developer を指定してください。"
    exit 1
fi

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
NAME=LLMMLXDAT
OUT="build/$NAME.plugin/Contents"
PRODUCTS="helper/.xcbuild/Build/Products/Release"

# ① Swiftヘルパ実行ファイル（xcodebuild。初回は mlx-swift の C++/Metal コンパイルで十数分）
#    -skipPackagePluginValidation: mlx-swift の CudaBuild ビルドツールプラグインの対話承認を回避
#    -skipMacroValidation:         swift-syntax マクロ（MLXHuggingFace）の対話承認を回避
#    Metal Toolchain は Xcode 本体と別コンポーネント。無いと
#    "cannot execute tool 'metal' due to missing Metal Toolchain" で失敗するので先に確認する。
if ! xcrun metal --version >/dev/null 2>&1; then
    echo "ERROR: Metal Toolchain が入っていません。次を実行してから再試行してください:"
    echo "       xcodebuild -downloadComponent MetalToolchain   # 約840MB"
    exit 1
fi

( cd helper && xcodebuild build -scheme MLXLLMHelper -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .xcbuild \
    -skipPackagePluginValidation -skipMacroValidation )

if [ ! -f "$PRODUCTS/mlxllm-cli" ]; then
  echo "ERROR: helper executable not built ($PRODUCTS/mlxllm-cli)"; exit 1
fi

rm -rf build
mkdir -p "$OUT/MacOS" "$OUT/Helpers"

# ヘルパ実行ファイル
cp "$PRODUCTS/mlxllm-cli" "$OUT/Helpers/mlxllm-helper"
# MLX の Metal リソースバンドル（mlx-swift_Cmlx.bundle・default.metallib入り）と
# tokenizer/hub バンドルを実行ファイルの隣へ。SwiftPM実行ファイルの Bundle.module は
# 実行ファイルと同じディレクトリを探すため、隣に置けば見つかる。
for b in "$PRODUCTS"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$OUT/Helpers/"
done
# 動的フレームワーク（あれば）。今回の構成では静的リンクのため通常は無い。
if [ -d "$PRODUCTS/PackageFrameworks" ]; then
  mkdir -p "$OUT/Helpers/PackageFrameworks"
  cp -R "$PRODUCTS/PackageFrameworks/"*.framework "$OUT/Helpers/PackageFrameworks/" 2>/dev/null || true
fi

# ② プラグイン本体（DAT）
clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK" \
  LLMMLXDAT.mm \
  -framework Foundation -framework CoreGraphics -framework ImageIO \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>LLMMLXDAT</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.llmmlx-dat</string>
    <key>CFBundleName</key><string>LLMMLXDAT</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

# ヘルパのMetalリソースを含むため署名は --deep で
codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin"
td_stamp_all
