#!/usr/bin/env bash
# Runs the UI tests on an iPhone and an iPad simulator and exports the screenshots they capture
# into fastlane/screenshots/en-US, named for the App Store sizes.
#
# Usage: scripts/export-screenshots.sh [--iphone "iPhone 18 Pro Max"] [--ipad "iPad Pro 13-inch (M5)"]

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IPHONE="iPhone 18 Pro Max"
IPAD="iPad Pro 13-inch (M5)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iphone) IPHONE="$2"; shift 2 ;;
    --ipad) IPAD="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

OUT="$ROOT/fastlane/screenshots/en-US"
mkdir -p "$OUT" "$ROOT/build"

run_device() {
  local device="$1"
  local tag="$2"
  local bundle="$ROOT/build/screenshots-$tag.xcresult"
  rm -rf "$bundle"
  echo "Running UI tests on $device"
  xcodebuild test \
    -skipPackagePluginValidation -skipMacroValidation \
    -project Tern.xcodeproj -scheme Tern \
    -destination "platform=iOS Simulator,name=$device" \
    -only-testing:TernUITests \
    -resultBundlePath "$bundle" \
    CODE_SIGNING_ALLOWED=NO | tail -20 || true
  local export_dir="$ROOT/build/screenshots-$tag"
  rm -rf "$export_dir"
  mkdir -p "$export_dir"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$export_dir" >/dev/null
  # Attachments are exported with their names plus a suffix; copy the PNGs with clean names.
  local index=0
  for file in "$export_dir"/*.png; do
    [[ -f "$file" ]] || continue
    local base
    base="$(basename "$file")"
    local name="${base%%_*}"
    name="${name%.png}"
    cp "$file" "$OUT/${tag}-${name}.png"
    index=$((index + 1))
  done
  echo "Exported $index screenshots for $tag"
}

run_device "$IPHONE" "iphone-6.9"
run_device "$IPAD" "ipad-13"
ls -la "$OUT"
