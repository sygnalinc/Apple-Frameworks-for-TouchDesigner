#!/bin/bash
set -e
cd "$(dirname "$0")"
source ../common/build_plugin.sh
build_td_plugin HIDCHOP hid-chop HIDCHOP.mm -- IOKit CoreFoundation
