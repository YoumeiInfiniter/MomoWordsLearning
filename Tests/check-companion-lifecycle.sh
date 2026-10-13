#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.clang-module-cache"
export SWIFTPM_CACHE_PATH="$PROJECT_DIR/.swiftpm-cache"
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
fi
swift run --disable-sandbox MaimemoCompanion --offline-check
