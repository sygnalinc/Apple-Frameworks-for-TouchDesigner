#!/bin/zsh
# CoreAI(1フォルダ3バンドル): CoreAITOP.plugin(画像モデル)/ LLMCoreAIDAT.plugin(LLM / VLM)/ CoreAIImageGenTOP.plugin(拡散)
# dylib はビルド毎に名前を変える(TD/dyld が install name でキャッシュするため)
set -e
cd "$(dirname "$0")"
source ../common/version.sh

TDAPP="${TD_APP:-/Applications/TouchDesigner.app}"
SDK_TOP="$TDAPP/Contents/Resources/tfs/Samples/CPlusPlus/CPUMemoryTOP"
SDK_DAT="$TDAPP/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
EPOCH=$(date +%s)
rm -rf build

plist() {   # $1=NAME $2=bundle id suffix
  cat > "build/$1.plugin/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$1</string>
    <key>CFBundleIdentifier</key><string>tokyo.sygnal.$2</string>
    <key>CFBundleName</key><string>$1</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST
}

# ---------- ① CoreAI TOP(Swift ヘルパ dylib + CPUMem TOP)----------
# CoreAI framework は macOS 27 で追加。26 でもロードできるよう -weak_framework でリンクし、
# Swift 側は全て @available(macOS 27.0, *) の裏(26 では status に理由を返すだけ)。
# SDK 27 が無い環境(macOS 26 機)では canImport(CoreAI) が偽になり、同じ「unavailable」経路になる
NAME=CoreAITOP
OUT="build/$NAME.plugin/Contents"
DYLIB="libCoreAIHelper_${EPOCH}.dylib"
mkdir -p "$OUT/MacOS" "$OUT/Frameworks"
swiftc -O -emit-library -module-name CoreAIHelper \
  -target arm64-apple-macos26.0 \
  CoreAIHelper.swift \
  -Xlinker -weak_framework -Xlinker CoreAI \
  -framework CoreGraphics -framework CoreVideo \
  -Xlinker -install_name -Xlinker "@rpath/$DYLIB" \
  -o "$OUT/Frameworks/$DYLIB"
clang++ -std=c++17 -fobjc-arc -O2 -bundle \
  -I "$SDK_TOP" \
  CoreAITOP.mm \
  -framework Foundation \
  "$OUT/Frameworks/$DYLIB" \
  -Xlinker -rpath -Xlinker @loader_path/../Frameworks \
  -o "$OUT/MacOS/$NAME"
plist "$NAME" coreai-top
codesign --force --deep -s - "build/$NAME.plugin"
echo "built: $(pwd)/build/$NAME.plugin ($DYLIB)"

# ---------- ② LLM CoreAI DAT(ヘルパ実行ファイル + DAT)----------
# opLabel は LLM AFM / LLM MLX と揃えて "LLM CoreAI"。フォルダは coreai-models の Swift パッケージを
# ImageGen と共有するため CoreAI/ のまま(1フォルダ複数バンドルの型)。ヘルパ名 coreai-llm-helper は内部名
# ヘルパは Apple coreai-models(SPM・BSD-3)を使う Swift パッケージ。macOS 27 SDK が要る
# (Package.swift の platforms が 27.0)。26 機ではここをスキップして TOP だけ作る。
SDKVER=$(xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)
if [ "${SDKVER:-0}" -ge 27 ]; then
  NAME=LLMCoreAIDAT
  OUT="build/$NAME.plugin/Contents"
  ( cd helper && swift build -c release --product coreai-llm-cli --product coreai-diffusion-cli 2>&1 | grep -E "error:|Compiling|Build complete" || true )
  HELPER="helper/.build/release/coreai-llm-cli"
  if [ ! -x "$HELPER" ]; then
    echo "ERROR: helper executable not built ($HELPER)"; exit 1
  fi
  # 先にコンパイルし、成功したときだけバンドルを組む(失敗時に実行ファイルの無い骨格が
  # 残ると、それをインストールした TD が起動時にクラッシュする・MapKit で実際に踏んだ)
  clang++ -std=c++17 -fobjc-arc -O2 -bundle \
    -I "$SDK_DAT" \
    LLMCoreAIDAT.mm \
    -framework Foundation -framework CoreGraphics -framework ImageIO \
    -o "build/$NAME.tmp"
  mkdir -p "$OUT/MacOS" "$OUT/Helpers"
  mv "build/$NAME.tmp" "$OUT/MacOS/$NAME"
  cp "$HELPER" "$OUT/Helpers/coreai-llm-helper"
  # SwiftPM の resource bundle(tokenizer 等)があれば実行ファイルの隣へ
  for b in helper/.build/release/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$OUT/Helpers/"
  done
  plist "$NAME" llm-coreai-dat
  codesign --force --deep -s - "build/$NAME.plugin"
  echo "built: $(pwd)/build/$NAME.plugin"

  # ---------- ③ CoreAI ImageGen TOP(拡散モデル。同じ Swift パッケージの2つ目の実行ファイル)----------
  NAME=CoreAIImageGenTOP
  OUT="build/$NAME.plugin/Contents"
  DHELPER="helper/.build/release/coreai-diffusion-cli"
  if [ ! -x "$DHELPER" ]; then
    echo "ERROR: diffusion helper executable not built ($DHELPER)"; exit 1
  fi
  clang++ -std=c++17 -fobjc-arc -O2 -bundle \
    -I "$SDK_TOP" \
    CoreAIImageGenTOP.mm \
    -framework Foundation -framework CoreGraphics -framework ImageIO \
    -o "build/$NAME.tmp"
  mkdir -p "$OUT/MacOS" "$OUT/Helpers"
  mv "build/$NAME.tmp" "$OUT/MacOS/$NAME"
  cp "$DHELPER" "$OUT/Helpers/coreai-diffusion-helper"
  # 拡散ヘルパは Transformers に依存しないので同梱バンドルは不要
  plist "$NAME" coreai-imagegen-top
  codesign --force --deep -s - "build/$NAME.plugin"
  echo "built: $(pwd)/build/$NAME.plugin"
else
  echo "skip LLMCoreAIDAT / CoreAIImageGenTOP (needs macOS 27 SDK; found ${SDKVER:-none})"
fi

td_stamp_all
