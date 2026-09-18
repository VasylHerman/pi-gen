#!/usr/bin/env bash
# Development image: full Raspberry Pi OS Lite + custom kernel + nginx (config/dev.conf).
# Usage: ./build-dev.sh [build|shell|reset]   — see scripts/build-image.sh for details.
exec "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/scripts/build-image.sh" dev "$@"
