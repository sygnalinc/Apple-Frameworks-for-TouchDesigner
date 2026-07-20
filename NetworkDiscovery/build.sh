#!/bin/zsh
# Network Discovery DAT のビルド → build/NetworkDiscoveryDAT.plugin
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
source ../common/build_plugin.sh
build_td_plugin NetworkDiscoveryDAT networkdiscovery-dat NetworkDiscoveryDAT.mm --
