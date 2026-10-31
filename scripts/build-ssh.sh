#!/usr/bin/env bash
# Builds ssh_cmd, ssh_cmdA and ssh_agent (OpenSSH: ssh, scp, sftp, ssh-keygen, ssh-agent,
# ssh-add) from the ios_system sources with device (arm64) and Simulator (arm64) slices.
#
# Why build them at all: the prebuilt frameworks look for keys, config and known_hosts in
# $HOME/Documents/.ssh, because a-Shell keeps HOME at the sandbox root. Tern's home directory
# is the Documents folder itself, so the OpenSSH user directory must be ~/.ssh like everywhere
# else. That is the only source change (see patch_sources below).
#
# The result lands in Toolchain/local/, which scripts/embed-toolchain.py prefers over the
# manifest's prebuilt archives.
#
# Usage: scripts/build-ssh.sh [--ref <ios_system git ref>] [--zip]
# Needs Xcode, the toolchain fetched (ios_system, openssl and libssh2 frameworks) and a few minutes.
# --zip also writes <name>.xcframework.zip plus sha256 files to Toolchain/local for publishing.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="v3.0.6"
ZIP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --zip) ZIP=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

WORK="$ROOT/Toolchain/cache/src/ios_system"
OUT="$ROOT/Toolchain/local"
FRAMEWORKS="$ROOT/Toolchain/frameworks"
TARGETS=(ssh_cmd ssh_cmdA ssh_agent)
MIN_IOS="15.0"   # Xcode 27 refuses anything older

for name in ios_system openssl libssh2; do
  [[ -d "$FRAMEWORKS/$name.xcframework" ]] || bash "$ROOT/scripts/fetch-toolchain.sh"
done

mkdir -p "$(dirname "$WORK")" "$OUT"
if [[ ! -d "$WORK/.git" ]]; then
  git clone --depth 1 --branch "$REF" https://github.com/holzschu/ios_system.git "$WORK"
else
  git -C "$WORK" fetch --depth 1 origin "$REF" && git -C "$WORK" checkout -q --force FETCH_HEAD
fi
cd "$WORK"
echo "Building OpenSSH frameworks from ios_system $(git log -1 --format=%h) ($REF)"

patch_sources() {
  python3 - "$WORK" <<'EOF'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
edits = [
    (root / "ssh_keygen/pathnames.h",
     '#define _PATH_SSH_USER_DIR\t\t"Documents/.ssh"',
     '#define _PATH_SSH_USER_DIR\t\t".ssh"'),
    (root / "ssh_keygen/sftp.c",
     'path1 = xstrdup("~/Documents/");',
     'path1 = xstrdup("~");'),
]
for path, old, new in edits:
    text = path.read_text()
    if new in text and old not in text:
        continue
    if text.count(old) != 1:
        sys.exit(f"expected exactly one occurrence of {old!r} in {path}")
    path.write_text(text.replace(old, new))
    print(f"patched {path.relative_to(root)}")
EOF
}
patch_sources

# The Xcode project expects the OpenSSL and libssh2 xcframeworks where SwiftPM would put them.
for name in openssl libssh2; do
  mkdir -p "xcfs/.build/artifacts/xcfs/$name"
  ln -sfn "$FRAMEWORKS/$name.xcframework" "xcfs/.build/artifacts/xcfs/$name/$name.xcframework"
done

build_platform() {
  local platform="$1"   # iphoneos | iphonesimulator
  local slice="$2"      # directory inside ios_system.xcframework
  local products="$WORK/build/Release-$platform"
  rm -rf "$products"
  mkdir -p "$products"
  # ios_system.framework is linked from the built products directory.
  cp -R "$FRAMEWORKS/ios_system.xcframework/$slice/ios_system.framework" "$products/"
  for target in "${TARGETS[@]}"; do
    echo "  $target ($platform)"
    xcodebuild -project ios_system.xcodeproj -target "$target" -sdk "$platform" -configuration Release build \
      SYMROOT="$WORK/build" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
      IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS" \
      CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
      > "$ROOT/Toolchain/cache/ssh-$target-$platform.log" 2>&1 || {
        tail -30 "$ROOT/Toolchain/cache/ssh-$target-$platform.log"
        exit 1
      }
  done
}

build_platform iphoneos ios-arm64
build_platform iphonesimulator ios-arm64_x86_64-simulator

for target in "${TARGETS[@]}"; do
  rm -rf "$OUT/$target.xcframework"
  xcodebuild -create-xcframework \
    -framework "build/Release-iphoneos/$target.framework" \
    -framework "build/Release-iphonesimulator/$target.framework" \
    -output "$OUT/$target.xcframework" >/dev/null
  binary="$OUT/$target.xcframework/ios-arm64/$target.framework/$target"
  if strings -a "$binary" | grep -q "Documents/.ssh"; then
    echo "$target still refers to Documents/.ssh" >&2
    exit 1
  fi
  echo "Created $OUT/$target.xcframework"
  if [[ "$ZIP" == 1 ]]; then
    (cd "$OUT" && rm -f "$target.xcframework.zip" && zip -qry "$target.xcframework.zip" "$target.xcframework" \
      && shasum -a 256 "$target.xcframework.zip" | cut -d' ' -f1 > "$target.xcframework.zip.sha256")
    echo "  $(cat "$OUT/$target.xcframework.zip.sha256")  $target.xcframework.zip"
  fi
done
