#!/bin/zsh
# Network Discovery DAT のビルド → build/NetworkDiscoveryDAT.plugin
# MACベンダー判定用の oui.txt(IEEE OUIデータベース)を Contents/Resources に同梱する。
cd "$(dirname "$0")"
export TD_SDK="/Applications/TouchDesigner.app/Contents/Resources/tfs/Samples/CPlusPlus/DAT"
source ../common/build_plugin.sh
# dns_sd(mDNS逆引き)は libSystem に含まれ追加フレームワーク不要
build_td_plugin NetworkDiscoveryDAT networkdiscovery-dat NetworkDiscoveryDAT.mm --

# OUIデータベースを Resources に同梱して ad-hoc 再署名
RES="build/NetworkDiscoveryDAT.plugin/Contents/Resources"
mkdir -p "$RES"
cp oui.txt "$RES/oui.txt"
codesign --force -s - "build/NetworkDiscoveryDAT.plugin"
echo "bundled oui.txt ($(wc -l < oui.txt) entries)"
