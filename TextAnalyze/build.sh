#!/bin/zsh
# Text Analyze DAT のビルド → build/TextAnalyzeDAT.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
source ../common/build_plugin.sh
build_td_plugin TextAnalyzeDAT textanalyze-dat TextAnalyzeDAT.mm -- NaturalLanguage
