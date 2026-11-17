#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
export CLANG_MODULE_CACHE_PATH="$root/.cache/clang"
export SWIFT_MODULECACHE_PATH="$root/.cache/swift-modules"
mkdir -p .cache dist
swift build -c release --cache-path .cache/swift --config-path .cache/swift-config --security-path .cache/swift-security --disable-sandbox
npm --prefix runtime ci --ignore-scripts --cache "$root/.cache/npm"
npm --prefix runtime run build
node_version=26.13.0
node_name="node-v${node_version}-darwin-arm64"
if [ ! -x ".cache/$node_name/bin/node" ]; then
  curl --fail --location --retry 2 "https://nodejs.org/dist/v${node_version}/${node_name}.tar.gz" -o ".cache/${node_name}.tar.gz"
  curl --fail --location "https://nodejs.org/dist/v${node_version}/SHASUMS256.txt" -o .cache/SHASUMS256.txt
  rg " ${node_name}\.tar\.gz$" .cache/SHASUMS256.txt > .cache/node-checksums.txt
  (cd .cache && shasum -a 256 -c node-checksums.txt)
  tar -xzf ".cache/${node_name}.tar.gz" -C .cache
fi
stage="$root/dist/Ragdoll.staging.app"
if [ -d "$stage" ]; then rm -rf "$stage"; fi
mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources/runtime/app"
trap 'rm -rf "$stage"' EXIT
cp .build/release/Ragdoll "$stage/Contents/MacOS/Ragdoll"
cp .build/release/RagdollService "$stage/Contents/MacOS/RagdollService"
mkdir -p "$stage/Contents/Library/LaunchAgents"
cp packaging/com.oyamameek.ragdoll.service.plist "$stage/Contents/Library/LaunchAgents/"
cp packaging/Info.plist "$stage/Contents/Info.plist"
cp -R ".cache/$node_name" "$stage/Contents/Resources/runtime/node"
cp runtime/package.json runtime/package-lock.json "$stage/Contents/Resources/runtime/app/"
cp -R runtime/dist "$stage/Contents/Resources/runtime/app/dist"
npm --prefix "$stage/Contents/Resources/runtime/app" ci --omit=dev --omit=optional --ignore-scripts --cache "$root/.cache/npm"
for bundle in .build/release/*.bundle; do
  if [ -d "$bundle" ]; then cp -R "$bundle" "$stage/Contents/Resources/"; fi
done
cp -R docs "$stage/Contents/Resources/docs"
codesign --force --deep --sign "${CODE_SIGN_IDENTITY:--}" "$stage"
codesign --verify --deep --strict "$stage"
"$stage/Contents/Resources/runtime/node/bin/node" "$stage/Contents/Resources/runtime/app/dist/main.mjs" --self-check
if [ -d dist/Ragdoll.previous.app ]; then rm -rf dist/Ragdoll.previous.app; fi
if [ -d dist/Ragdoll.app ]; then mv dist/Ragdoll.app dist/Ragdoll.previous.app; fi
mv "$stage" dist/Ragdoll.app
trap - EXIT
echo "Built: $root/dist/Ragdoll.app"
