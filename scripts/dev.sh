#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
export CLANG_MODULE_CACHE_PATH="$root/.cache/clang"
export SWIFT_MODULECACHE_PATH="$root/.cache/swift-modules"
npm --prefix runtime run build
swift run --cache-path .cache/swift --config-path .cache/swift-config --security-path .cache/swift-security --disable-sandbox Ragdoll
