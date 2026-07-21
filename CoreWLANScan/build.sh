#!/bin/zsh
# CoreWLAN Scan CHOP のビルド → build/CoreWLANScanCHOP.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/CHOP"
source ../common/build_plugin.sh
build_td_plugin CoreWLANScanCHOP corewlanscan-chop CoreWLANScanCHOP.mm -- CoreWLAN
