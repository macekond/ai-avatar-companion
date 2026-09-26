#!/usr/bin/env bash
#
# Cross-compiles espeak-ng (Piper's phonemizer dependency — see
# ios/spikes/03-tts-piper/README.md) for iOS device + simulator and packages
# an espeak-ng.xcframework, following the same combine-static-libs-into-a-
# dynamic-framework pattern as build-llama-ios-only.sh.
#
# espeak-ng ships a CMake build (contrary to this repo's earlier notes,
# which were based on a stale/pre-CMake version or a misreading — current
# upstream master has CMakeLists.txt throughout), but its COMPILE_INTONATIONS
# step needs a *native* espeak-ng binary to compile the dictionary/intonation
# data at configure/build time even when cross-compiling for iOS (its own
# CMakeLists.txt documents this via the NativeBuild_DIR variable). So this
# script first builds a native (macOS host) espeak-ng to produce that binary,
# then cross-compiles device + simulator libraries against it.
#
# Two non-obvious fixes over a naive `-DCMAKE_SYSTEM_NAME=iOS` invocation:
# - `-DCMAKE_MACOSX_BUNDLE=OFF`: without it, configuring fails outright
#   ("install TARGETS given no BUNDLE DESTINATION for MACOSX_BUNDLE
#   executable") because CMake's iOS platform defaults executables to
#   MACOSX_BUNDLE — irrelevant here since only the `espeak-ng` *library*
#   target is built, never the CLI binary.
# - `-DNativeBuild_DIR=<dir containing the native espeak-ng binary>`: the
#   upstream CMakeLists.txt's own help text says `-DNativeBuild=...`, but the
#   variable it actually reads is `NativeBuild_DIR` (passed to
#   `find_program(... PATHS ${NativeBuild_DIR} NO_DEFAULT_PATH)`) — a real
#   upstream inconsistency between the message and the code.
#
# Usage: ios/scripts/build-espeak-ng-ios.sh   (run from anywhere)
set -e
cd "$(dirname "${BASH_SOURCE[0]}")/../../NativeCores/espeak-ng"

IOS_MIN_OS_VERSION=17.0
FRAMEWORK_NAME=espeak-ng

echo "Building native espeak-ng (macOS host) to compile dictionary/intonation data..."
cmake -B build-native \
    -DBUILD_SHARED_LIBS=OFF -DENABLE_TESTS=OFF -DCMAKE_BUILD_TYPE=Release
cmake --build build-native --config Release -j "$(sysctl -n hw.ncpu)"
NATIVE_BIN_DIR="$(pwd)/build-native/src"

configure_and_build() {
    local build_dir="$1" sysroot="$2" archs="$3"
    cmake -B "${build_dir}" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="${sysroot}" \
        -DCMAKE_OSX_ARCHITECTURES="${archs}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_MIN_OS_VERSION}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_TESTS=OFF \
        -DCOMPILE_INTONATIONS=ON \
        -DNativeBuild_DIR="${NATIVE_BIN_DIR}" \
        -DCMAKE_MACOSX_BUNDLE=OFF \
        -DCMAKE_BUILD_TYPE=Release
    cmake --build "${build_dir}" --target espeak-ng --config Release -j "$(sysctl -n hw.ncpu)"
    cmake --build "${build_dir}" --target data --config Release -j "$(sysctl -n hw.ncpu)"
}

echo "Building for iOS device (arm64)..."
configure_and_build build-ios-device iphoneos arm64

echo "Building for iOS simulator (arm64 + x86_64)..."
configure_and_build build-ios-sim iphonesimulator "arm64;x86_64"

setup_framework_structure() {
    local build_dir="$1"
    mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers"
    mkdir -p "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Modules"
    cp src/include/espeak-ng/*.h "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Headers/"
    cat > "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Modules/module.modulemap" << EOF
framework module ${FRAMEWORK_NAME} {
    umbrella "Headers"
    export *
}
EOF
    cat > "${build_dir}/framework/${FRAMEWORK_NAME}.framework/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key><string>org.espeak-ng.espeak-ng</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.53.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>${IOS_MIN_OS_VERSION}</string>
    <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
</dict>
</plist>
EOF
}

combine_and_link() {
    local build_dir="$1" sdk="$2" archs="$3" min_version_flag="$4"
    local base_dir="$(pwd)"
    local output_lib="${build_dir}/framework/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}"
    local temp_dir="${build_dir}/temp"
    mkdir -p "${temp_dir}"

    xcrun libtool -static -o "${temp_dir}/combined.a" \
        "${base_dir}/${build_dir}/src/libespeak-ng/libespeak-ng.a" \
        "${base_dir}/${build_dir}/src/speechPlayer/libspeechPlayer.a" \
        "${base_dir}/${build_dir}/src/ucd-tools/libucd.a" \
        2>/dev/null

    local arch_flags=""
    for arch in ${archs}; do arch_flags+=" -arch ${arch}"; done

    xcrun -sdk "${sdk}" clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk "${sdk}" --show-sdk-path)" \
        ${arch_flags} ${min_version_flag} \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -install_name "@rpath/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}" \
        -o "${base_dir}/${output_lib}"

    rm -rf "${temp_dir}"

    # App Store validation rejects an archive missing a dSYM for any
    # embedded dynamic framework with debug info expected — this hand-linked
    # dylib never had one (unlike whisper.cpp/llama.cpp's own
    # build-xcframework.sh, which generates dSYMs as standard practice).
    # dsymutil against the exact final binary guarantees the dSYM's UUID
    # matches what Apple's validator checks for, even though there isn't
    # much DWARF info to recover from a vendored C library's Release build.
    xcrun dsymutil "${base_dir}/${output_lib}" -o "${base_dir}/${build_dir}/${FRAMEWORK_NAME}.framework.dSYM"
}

echo "Assembling frameworks..."
setup_framework_structure build-ios-device
setup_framework_structure build-ios-sim
combine_and_link build-ios-device iphoneos arm64 "-mios-version-min=${IOS_MIN_OS_VERSION}"
combine_and_link build-ios-sim iphonesimulator "arm64 x86_64" "-mios-simulator-version-min=${IOS_MIN_OS_VERSION}"

echo "Creating XCFramework..."
mkdir -p build-apple
rm -rf build-apple/${FRAMEWORK_NAME}.xcframework
xcrun xcodebuild -create-xcframework \
    -framework "$(pwd)/build-ios-device/framework/${FRAMEWORK_NAME}.framework" \
    -debug-symbols "$(pwd)/build-ios-device/${FRAMEWORK_NAME}.framework.dSYM" \
    -framework "$(pwd)/build-ios-sim/framework/${FRAMEWORK_NAME}.framework" \
    -debug-symbols "$(pwd)/build-ios-sim/${FRAMEWORK_NAME}.framework.dSYM" \
    -output "$(pwd)/build-apple/${FRAMEWORK_NAME}.xcframework"

echo "Copying compiled dictionary/voice data (from the device build; identical across archs)..."
rm -rf build-apple/espeak-ng-data
cp -R build-ios-device/espeak-ng-data build-apple/espeak-ng-data

# Flattened, platform-independent header copy for HEADER_SEARCH_PATHS — same
# reason as fetch-onnxruntime.sh: an xcframework's per-slice header paths
# aren't referenceable via a single static search path. Imported directly via
# the bridging header (`#import <speak_lib.h>`), not as a Swift module —
# espeak-ng's public headers are plain C with no module map needed, same
# pattern as onnxruntime.
echo "Flattening headers for HEADER_SEARCH_PATHS..."
mkdir -p build-apple/Headers
cp src/include/espeak-ng/*.h build-apple/Headers/

echo "Cleaning up intermediates (disk quota is tight in this environment)..."
rm -rf build-native build-ios-sim build-ios-device

echo "Done: build-apple/${FRAMEWORK_NAME}.xcframework + build-apple/espeak-ng-data"
