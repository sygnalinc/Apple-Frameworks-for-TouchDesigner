#!/bin/zsh
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin CoreMLCHOP coreml-chop CoreMLCHOP.mm -- CoreML Vision CoreVideo
