#!/bin/zsh
# Shortcuts DAT のビルド → build/ShortcutsDAT.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
source ../common/build_plugin.sh
build_td_plugin ShortcutsDAT shortcuts-dat ShortcutsDAT.mm --
