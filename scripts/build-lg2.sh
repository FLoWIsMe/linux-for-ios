#!/usr/bin/env bash
# Builds lg2.xcframework (the libgit2 command line client) from Nicolas Holzschuch's iOS fork of
# libgit2, with device (arm64) and Simulator (arm64) slices. Output: Toolchain/local/lg2.xcframework,
# which scripts/embed-toolchain.py prefers over the prebuilt archive from the manifest.
#
# Usage: scripts/build-lg2.sh [--ref <git ref>] [--jobs N]
# Needs Xcode, cmake (brew install cmake) and the toolchain fetched (ios_system, libssh2, openssl).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="master"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

command -v cmake >/dev/null || { echo "error: cmake is required (brew install cmake)" >&2; exit 1; }

FW="$ROOT/Toolchain/frameworks"
for name in ios_system libssh2 openssl; do
  [[ -d "$FW/$name.xcframework" ]] || bash "$ROOT/scripts/fetch-toolchain.sh"
done

WORK="$ROOT/Toolchain/cache/src/libgit2"
OUT="$ROOT/Toolchain/local"
mkdir -p "$(dirname "$WORK")" "$OUT"
if [[ ! -d "$WORK/.git" ]]; then
  git clone --depth 1 --branch "$REF" https://github.com/holzschu/libgit2.git "$WORK"
else
  git -C "$WORK" fetch --depth 1 origin "$REF" && git -C "$WORK" checkout -q FETCH_HEAD
fi
cd "$WORK"
echo "Building lg2 from holzschu/libgit2 $(git log -1 --format=%h) (libgit2 $(grep LIBGIT2_VERSION include/git2/version.h | head -1 | awk '{print $3}'))"
curl -sSL -o examples/ios_error.h https://github.com/holzschu/ios_system/releases/download/v3.0.6/ios_error.h

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
export M4="$(xcrun -f m4)"

prepare_frameworks() {
  local platform="$1"
  local dir="$WORK/Frameworks_$platform"
  rm -rf "$dir"; mkdir -p "$dir"
  if [[ "$platform" == "iphoneos" ]]; then
    cp -R "$FW/ios_system.xcframework/ios-arm64/ios_system.framework" "$dir/"
    cp -R "$FW/libssh2.xcframework/ios-arm64_arm64e/libssh2.framework" "$dir/"
    cp -R "$FW/openssl.xcframework/ios-arm64/openssl.framework" "$dir/"
  else
    cp -R "$FW/ios_system.xcframework/ios-arm64_x86_64-simulator/ios_system.framework" "$dir/"
    cp -R "$FW/libssh2.xcframework/ios-arm64_x86_64-simulator/libssh2.framework" "$dir/"
    cp -R "$FW/openssl.xcframework/ios-arm64_x86_64-simulator/openssl.framework" "$dir/"
  fi
}

build_platform() {
  local platform="$1"
  local sdk="$2"
  local target="$3"
  local minflag="$4"
  prepare_frameworks "$platform"
  local fwdir="$WORK/Frameworks_$platform"
  local build="$WORK/build-$platform"
  rm -rf "$build"; mkdir -p "$build"
  pushd "$build" >/dev/null
  local common="-arch arm64 -target $target -O2 $minflag"
  cmake "$WORK" \
    -DREGEX_BACKEND=builtin -DBUILD_CLAR=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=ON -DBUILD_SHARED_LIBS=OFF -DTHREADSAFE=OFF \
    -DCMAKE_INSTALL_PREFIX=@rpath \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_C_COMPILER="$(xcrun --sdk "$platform" -f clang)" \
    -DCMAKE_C_FLAGS="$common -I$fwdir/libssh2.framework/Headers -I$fwdir/openssl.framework/Headers -I$WORK/examples" \
    -DCMAKE_MODULE_LINKER_FLAGS="$common -F$fwdir" \
    -DCMAKE_SHARED_LINKER_FLAGS="$common -F$fwdir" \
    -DCMAKE_EXE_LINKER_FLAGS="$common -F$fwdir -framework ios_system -framework libssh2 -framework openssl" \
    -DCMAKE_LIBRARY_PATH="$sdk/usr/lib" \
    -DCMAKE_INCLUDE_PATH="$sdk/usr/include" > "$ROOT/Toolchain/cache/lg2-cmake-$platform.log" 2>&1
  make -j"$JOBS" > "$ROOT/Toolchain/cache/lg2-make-$platform.log" 2>&1 || true
  # The example target is an executable; relink the objects as a dynamic library.
  local objects
  objects="$(find examples -name '*.c.o' | sort)"
  [[ -n "$objects" ]] || { echo "error: no lg2 objects built, see $ROOT/Toolchain/cache/lg2-make-$platform.log" >&2; exit 1; }
  local lib="libgit2.a"
  [[ -f "$lib" ]] || lib="$(find . -name 'libgit2.a' | head -1)"
  ld -arch arm64 -dylib -syslibroot "$sdk" -platform_version "${platform/iphoneos/ios}" "${minflag##*=}" "$(xcrun --sdk "$platform" --show-sdk-version)" \
    -F"$fwdir" $objects "$lib" $(find . -name 'libgit2*.a' -o -name 'libpcre.a' -o -name 'libxdiff.a' -o -name 'libntlmclient.a' -o -name 'libhttp-parser.a' -o -name 'libllhttp.a' 2>/dev/null | grep -v "^./$lib$" | sort -u) \
    -lpthread -lSystem -framework CoreFoundation -framework Security -framework libssh2 -framework openssl -framework ios_system -liconv -lz \
    -o lg2.dylib 2> "$ROOT/Toolchain/cache/lg2-link-$platform.log" || { echo "error: link failed, see $ROOT/Toolchain/cache/lg2-link-$platform.log" >&2; exit 1; }
  local dest="$fwdir/lg2.framework"
  rm -rf "$dest"; mkdir -p "$dest"
  cp lg2.dylib "$dest/lg2"
  local plist="$WORK/basic_Info.plist"
  [[ "$platform" == "iphonesimulator" ]] && plist="$WORK/basic_Info_Simulator.plist"
  cp "$plist" "$dest/Info.plist"
  plutil -replace CFBundleExecutable -string lg2 "$dest/Info.plist"
  plutil -replace CFBundleName -string lg2 "$dest/Info.plist"
  plutil -replace CFBundleIdentifier -string Nicolas-Holzschuch.lg2 "$dest/Info.plist"
  plutil -replace MinimumOSVersion -string "${minflag##*=}" "$dest/Info.plist"
  install_name_tool -id @rpath/lg2.framework/lg2 "$dest/lg2"
  popd >/dev/null
}

build_platform iphoneos "$IOS_SDK" arm64-apple-ios14.0 -miphoneos-version-min=14.0
build_platform iphonesimulator "$SIM_SDK" arm64-apple-ios14.0-simulator -mios-simulator-version-min=14.0

rm -rf "$OUT/lg2.xcframework"
xcodebuild -create-xcframework \
  -framework "$WORK/Frameworks_iphoneos/lg2.framework" \
  -framework "$WORK/Frameworks_iphonesimulator/lg2.framework" \
  -output "$OUT/lg2.xcframework" >/dev/null
echo "Created $OUT/lg2.xcframework"
otool -L "$OUT/lg2.xcframework/ios-arm64/lg2.framework/lg2" | grep rpath
