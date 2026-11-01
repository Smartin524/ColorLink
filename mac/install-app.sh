#!/bin/bash
# Install only this application's bundle; keep its identity and user settings.
set -euo pipefail
cd "$(dirname "$0")"
SOURCE_APP="build/ColorLink.app"
DESTINATION="/Applications/ColorLink.app"
EXPECTED_ID="com.colorlink.mac"
read_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist"; }
[[ "$(read_id "$SOURCE_APP")" == "$EXPECTED_ID" ]] || { echo "Unexpected source application" >&2; exit 1; }
if [[ -e "$DESTINATION" ]]; then
    [[ "$(read_id "$DESTINATION")" == "$EXPECTED_ID" ]] || { echo "Destination belongs to another application" >&2; exit 1; }
fi
codesign --verify --deep --strict "$SOURCE_APP"
STAGE=$(mktemp -d /Applications/.local-app-install.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
ditto "$SOURCE_APP" "$STAGE/new.app"
codesign --verify --deep --strict "$STAGE/new.app"
if [[ -e "$DESTINATION" ]]; then mv "$DESTINATION" "$STAGE/previous.app"; fi
if ! mv "$STAGE/new.app" "$DESTINATION"; then
    if [[ -e "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$DESTINATION"; fi
    exit 1
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DESTINATION"
mdimport "$DESTINATION"
echo "Installed: $DESTINATION (restart the application to use the update)"
