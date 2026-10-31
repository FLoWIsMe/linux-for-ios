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
  # Attachments come out with generated file names; manifest.json maps them to the names the
  # tests gave them ("01-terminal_0_<uuid>.png").
  local count
  count="$(python3 - "$export_dir" "$OUT" "$tag" <<'PY'
import json, pathlib, shutil, sys
export_dir, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
tag = sys.argv[3]
manifest = json.loads((export_dir / "manifest.json").read_text())
count = 0
for test in manifest:
    for attachment in test.get("attachments", []):
        suggested = attachment.get("suggestedHumanReadableName", "")
        if not suggested.endswith(".png"):
            continue
        name = suggested.split("_")[0]
        shutil.copy(export_dir / attachment["exportedFileName"], out / f"{tag}-{name}.png")
        count += 1
print(count)
PY
)"
  echo "Exported $count screenshots for $tag"
}

run_device "$IPHONE" "iphone-6.9"
run_device "$IPAD" "ipad-13"
ls -la "$OUT"
