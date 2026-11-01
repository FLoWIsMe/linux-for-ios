#!/bin/bash
# Puts a Downloads folder with one known file into a Simulator's "On My iPhone" storage, so the
# folder picker in testMountAttachesAFolderFromFiles has something to choose.
#
# usage: scripts/seed-simulator-downloads.sh [simulator UDID]   (defaults to the booted device)
set -euo pipefail

udid="${1:-}"
if [[ -z "$udid" ]]; then
  udid="$(xcrun simctl list devices booted -j | python3 -c 'import json,sys
for runtime in json.load(sys.stdin)["devices"].values():
    for device in runtime:
        if device["state"] == "Booted":
            print(device["udid"]); raise SystemExit
raise SystemExit("no booted simulator")')"
fi

groups="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Containers/Shared/AppGroup"
storage=""
for metadata in "$groups"/*/.com.apple.mobile_container_manager.metadata.plist; do
  if plutil -extract MCMMetadataIdentifier raw -o - "$metadata" 2>/dev/null | grep -q '^group.com.apple.FileProvider.LocalStorage$'; then
    storage="$(dirname "$metadata")/File Provider Storage"
    break
  fi
done
if [[ -z "$storage" ]]; then
  echo "could not find the local Files storage for simulator $udid (has the Files app been opened once?)" >&2
  exit 1
fi

mkdir -p "$storage/Downloads"
printf 'mount-check-ok\n' > "$storage/Downloads/tern-mount-check.txt"
printf 'A folder picked in Files shows up under ~/mnt in Tern.\n' > "$storage/Downloads/readme.txt"
echo "seeded $storage/Downloads"
