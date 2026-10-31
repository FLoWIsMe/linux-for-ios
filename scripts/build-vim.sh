#!/usr/bin/env bash
# Builds vim.xcframework and xxd.xcframework from Nicolas Holzschuch's iOS fork of Vim, with
# device (arm64) and Simulator (arm64) slices, so Tern can ship a current Vim and run it in the
# Simulator on Apple silicon Macs. The result lands in Toolchain/local/, which
# scripts/embed-toolchain.py prefers over the manifest's prebuilt archives. The matching runtime
# files are copied to Toolchain/local/vim-runtime.
#
# Usage: scripts/build-vim.sh [--ref <git ref>] [--jobs N]
# Needs Xcode, the toolchain fetched (for ios_system.framework) and about 10 minutes.

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

WORK="$ROOT/Toolchain/cache/src/vim"
OUT="$ROOT/Toolchain/local"
IOS_SYSTEM="$ROOT/Toolchain/frameworks/ios_system.xcframework"
LUA="$ROOT/Toolchain/frameworks/lua_ios.xcframework"
[[ -d "$IOS_SYSTEM" && -d "$LUA" ]] || bash "$ROOT/scripts/fetch-toolchain.sh"

mkdir -p "$(dirname "$WORK")" "$OUT"
if [[ ! -d "$WORK/.git" ]]; then
  git clone --depth 1 --branch "$REF" https://github.com/holzschu/vim.git "$WORK"
else
  git -C "$WORK" fetch --depth 1 origin "$REF" && git -C "$WORK" checkout -q FETCH_HEAD
fi
cd "$WORK"
echo "Building Vim $(git log -1 --format=%h) from holzschu/vim"

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
MIN_IOS="14.0"

# ios_error.h is included by the port; take the header that matches the ios_system release in use.
curl -sSL -o src/ios_error.h https://github.com/holzschu/ios_system/releases/download/v3.0.6/ios_error.h

build_slice() {
  local platform="$1"      # iphoneos | iphonesimulator
  local sdk="$2"
  local frameworks_dir="$WORK/Frameworks_$platform"
  local minflag
  if [[ "$platform" == "iphoneos" ]]; then
    minflag="-miphoneos-version-min=$MIN_IOS"
    rm -rf "$frameworks_dir"; mkdir -p "$frameworks_dir"
    cp -R "$IOS_SYSTEM/ios-arm64/ios_system.framework" "$frameworks_dir/"
    # The port's configure links lua_ios unconditionally.
    cp -R "$LUA/ios-arm64/lua_ios.framework" "$frameworks_dir/"
  else
    minflag="-mios-simulator-version-min=$MIN_IOS"
    rm -rf "$frameworks_dir"; mkdir -p "$frameworks_dir"
    cp -R "$IOS_SYSTEM/ios-arm64_x86_64-simulator/ios_system.framework" "$frameworks_dir/"
    cp -R "$LUA/ios-arm64_x86_64-simulator/lua_ios.framework" "$frameworks_dir/"
  fi
  rm -f Frameworks
  ln -s "$frameworks_dir" Frameworks

  make distclean >/dev/null 2>&1 || true
  local cflags="-DEXITFREE -arch arm64 -O2 $minflag -isysroot $sdk"
  ./configure \
    vim_cv_toupper_broken=no vim_cv_terminfo=no vim_cv_tgetent=zero \
    vim_cv_memmove_handles_overlap=no vim_cv_memcpy_handles_overlap=no vim_cv_bcopy_handles_overlap=no \
    vim_cv_tty_group=world vim_cv_stat_ignores_slash=yes vim_cv_getcwd_broken=no \
    --with-tlib=ncurses --with-features=big --enable-terminal \
    CC=clang CXX=clang++ \
    CFLAGS="$cflags" CPPFLAGS="$cflags" CXXFLAGS="$cflags" \
    LDFLAGS="-shared -arch arm64 -O2 $minflag -isysroot $sdk -F$frameworks_dir -framework ios_system" \
    --build=arm64-apple-darwin --host=armv7-apple-darwin > "$ROOT/Toolchain/cache/vim-configure-$platform.log" 2>&1
  make -j"$JOBS" > "$ROOT/Toolchain/cache/vim-make-$platform.log" 2>&1

  for framework in vim xxd; do
    local binary="src/$framework"
    [[ "$framework" == "xxd" ]] && binary="src/xxd/xxd"
    local dest="$frameworks_dir/$framework.framework"
    rm -rf "$dest"; mkdir -p "$dest"
    cp "$binary" "$dest/$framework"
    local plist="basic_Info.plist"
    [[ "$platform" == "iphonesimulator" ]] && plist="basic_Info_Simulator.plist"
    cp "$plist" "$dest/Info.plist"
    plutil -replace CFBundleExecutable -string "$framework" "$dest/Info.plist"
    plutil -replace CFBundleName -string "$framework" "$dest/Info.plist"
    plutil -replace CFBundleIdentifier -string "Nicolas-Holzschuch.$framework" "$dest/Info.plist"
    plutil -replace MinimumOSVersion -string "$MIN_IOS" "$dest/Info.plist"
    install_name_tool -id "@rpath/$framework.framework/$framework" "$dest/$framework"
  done
  rm -f Frameworks
}

build_slice iphoneos "$IOS_SDK"
build_slice iphonesimulator "$SIM_SDK"

for framework in vim xxd; do
  rm -rf "$OUT/$framework.xcframework"
  xcodebuild -create-xcframework \
    -framework "Frameworks_iphoneos/$framework.framework" \
    -framework "Frameworks_iphonesimulator/$framework.framework" \
    -output "$OUT/$framework.xcframework" >/dev/null
  echo "Created $OUT/$framework.xcframework"
done

rm -rf "$OUT/vim-runtime"
mkdir -p "$OUT/vim-runtime"
cp -R runtime "$OUT/vim-runtime/vim"
rm -rf "$OUT/vim-runtime/vim/lang" "$OUT/vim-runtime/vim/tutor" "$OUT/vim-runtime/vim/print" "$OUT/vim-runtime/vim/icons" "$OUT/vim-runtime/vim/tools"
rm -f "$OUT/vim-runtime/vim"/vimlogo.* "$OUT/vim-runtime/vim"/vim16x16.* "$OUT/vim-runtime/vim"/vim32x32.* "$OUT/vim-runtime/vim"/vim48x48.*
find "$OUT/vim-runtime/vim/spell" -type f ! -name 'en.utf-8.spl' ! -name 'en.utf-8.sug' ! -name '*.vim' -delete 2>/dev/null || true
echo "Runtime copied to $OUT/vim-runtime/vim ($(du -sh "$OUT/vim-runtime/vim" | cut -f1))"
strings "Frameworks_iphoneos/vim.framework/vim" | grep -m1 "^VIM - Vi IMproved"
