#!/usr/bin/env bash
# Archives Tern for the App Store and uploads the build to App Store Connect (TestFlight).
#
# Usage:
#   scripts/release.sh --key-id KEYID --issuer-id ISSUER [--build-number N] [--no-upload]
#
# Needs an App Store Connect API key at ~/.appstoreconnect/private_keys/AuthKey_KEYID.p8 with the
# App Manager role. Signing is automatic: Xcode creates or reuses the distribution certificate and
# profile through the API key (cloud managed signing), so nothing has to be installed by hand.
#
# The team id comes from Config/Local.xcconfig if present, else Config/Shared.xcconfig.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

KEY_ID=""
ISSUER_ID=""
BUILD_NUMBER=""
UPLOAD=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-id) KEY_ID="$2"; shift 2 ;;
    --issuer-id) ISSUER_ID="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --no-upload) UPLOAD=0; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$KEY_ID" || -z "$ISSUER_ID" ]]; then
  echo "usage: $0 --key-id KEYID --issuer-id ISSUER [--build-number N] [--no-upload]" >&2
  exit 2
fi

KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8"
if [[ ! -f "$KEY_PATH" ]]; then
  echo "error: API key not found at $KEY_PATH" >&2
  exit 1
fi

read_setting() {
  local name="$1"
  local value=""
  for file in Config/Shared.xcconfig Config/Local.xcconfig; do
    if [[ -f "$file" ]]; then
      local found
      found="$(grep -E "^\s*$name\s*=" "$file" | tail -1 | sed -E 's/^[^=]*=\s*//' | sed -E 's/\s*(\/\/.*)?$//')"
      [[ -n "$found" ]] && value="$found"
    fi
  done
  echo "$value"
}

TEAM_ID="$(read_setting TERN_TEAM_ID)"
BUNDLE_ID="$(read_setting TERN_BUNDLE_ID)"
if [[ -z "$TEAM_ID" ]]; then
  echo "error: TERN_TEAM_ID is not set in Config/Shared.xcconfig or Config/Local.xcconfig" >&2
  exit 1
fi

bash scripts/fetch-toolchain.sh --check >/dev/null 2>&1 || bash scripts/fetch-toolchain.sh
if [[ ! -d Tern.xcodeproj ]]; then
  xcodegen generate
fi

BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/Tern.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD_DIR"

extra_settings=()
if [[ -n "$BUILD_NUMBER" ]]; then
  extra_settings+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
fi

echo "Archiving Tern ($BUNDLE_ID, team $TEAM_ID)"
xcodebuild archive \
  -skipPackagePluginValidation -skipMacroValidation \
  -project Tern.xcodeproj -scheme Tern -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  "${extra_settings[@]}" \
  | tail -40

method="app-store-connect"
destination="upload"
if [[ "$UPLOAD" -eq 0 ]]; then
  destination="export"
fi

cat > "$BUILD_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>$method</string>
	<key>destination</key>
	<string>$destination</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
EOF

echo "Exporting ($destination)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  | tail -40

if [[ "$UPLOAD" -eq 1 ]]; then
  echo "Uploaded. The build appears in App Store Connect > TestFlight after processing (usually 5 to 15 minutes)."
else
  echo "IPA written to $EXPORT_DIR"
fi
