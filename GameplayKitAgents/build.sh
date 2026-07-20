#!/bin/bash
set -e
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin GameplayKitAgentsCHOP gameplayagents-chop GameplayKitAgentsCHOP.mm -- GameplayKit
