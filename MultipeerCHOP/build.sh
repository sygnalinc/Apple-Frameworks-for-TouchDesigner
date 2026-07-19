#!/bin/zsh
# Multipeer CHOP のビルド → build/MultipeerCHOP.plugin
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin MultipeerCHOP multipeer-chop MultipeerCHOP.mm -- MultipeerConnectivity
