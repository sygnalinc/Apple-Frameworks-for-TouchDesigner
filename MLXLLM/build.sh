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

SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
NAME=MLXLLMDAT
OUT="build/$NAME.plugin/Contents"
PRODUCTS="helper/.xcbuild/Build/Products/Release"

# ① Swiftヘルパ実行ファイル（xcodebuild。初回は mlx-swift の C++/Metal コンパイルで十数分）
#    -skipPackagePluginValidation: mlx-swift の CudaBuild ビルドツールプラグインの対話承認を回避
#    -skipMacroValidation:         swift-syntax マクロ（MLXHuggingFace）の対話承認を回避
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
  MLXLLMDAT.mm \
  -framework Foundation -framework CoreGraphics -framework ImageIO \
  -o "$OUT/MacOS/$NAME"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MLXLLMDAT</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.mlxllm-dat</string>
    <key>CFBundleName</key><string>MLXLLMDAT</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST

# ヘルパのMetalリソースを含むため署名は --deep で
codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin"