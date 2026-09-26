#!/usr/bin/env bash
# Fetches the official prebuilt onnxruntime.xcframework (needed for Piper's
# and Kokoro's acoustic models) into NativeCores/onnxruntime/build-apple/.
#
# onnxruntime ships NO iOS binary in its GitHub releases (checked
# api.github.com/repos/microsoft/onnxruntime/releases/latest — only linux/
# macos/windows assets). Its iOS distribution goes through CocoaPods
# ("onnxruntime-c"), whose podspec points at a prebuilt xcframework hosted
# directly by Microsoft — found via the CocoaPods CDN's MD5-sharded path:
#   https://cdn.cocoapods.org/Specs/<h[0]>/<h[1]>/<h[2]>/onnxruntime-c/<version>/onnxruntime-c.podspec.json
# where h = md5("onnxruntime-c"). That podspec's `source.http` is this URL.
#
# Not vendored in git — same reasoning as whisper.xcframework/llama.xcframework/
# openjtalk.xcframework (all gitignored build artifacts, regenerated locally).
set -e
VERSION="1.20.0"
URL="https://download.onnxruntime.ai/pod-archive-onnxruntime-c-${VERSION}.zip"
DEST="$(dirname "${BASH_SOURCE[0]}")/../../NativeCores/onnxruntime"

mkdir -p "$DEST/build-apple"
curl -sL "$URL" -o /tmp/onnxruntime-c.zip
unzip -oq /tmp/onnxruntime-c.zip -d /tmp/onnxruntime-c-extracted
rm -rf "$DEST/build-apple/onnxruntime.xcframework"
mv /tmp/onnxruntime-c-extracted/onnxruntime.xcframework "$DEST/build-apple/"
rm -rf /tmp/onnxruntime-c.zip /tmp/onnxruntime-c-extracted

# Flattened headers dir (project.yml's HEADER_SEARCH_PATHS): the xcframework's
# per-platform slice paths (ios-arm64 vs ios-arm64_x86_64-simulator) aren't a
# fixed path Xcode's HEADER_SEARCH_PATHS can reference directly the way
# framework-search-path-based linking can, so the bridging header's
# `#import <onnxruntime_c_api.h>` needs a stable, platform-independent copy.
rm -rf "$DEST/build-apple/Headers"
cp -R "$DEST/build-apple/onnxruntime.xcframework/ios-arm64/onnxruntime.framework/Headers" "$DEST/build-apple/Headers"

echo "onnxruntime.xcframework fetched to $DEST/build-apple/"
