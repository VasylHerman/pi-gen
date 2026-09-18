#!/usr/bin/env bash
# Release image: same build, then stage-slim strips everything a Wi-Fi/Bluetooth-capable
# nginx server does not need (config/release.conf). Usage: ./build-release.sh [build|shell|reset]
exec "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/scripts/build-image.sh" release "$@"
