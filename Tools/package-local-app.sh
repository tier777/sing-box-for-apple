#!/bin/sh
set -eu
# Usage: package-local-app.sh built/SFM.app engine-binary output/SFM-Routes.app
sfm_source_app=${1:?built app}
sfm_engine=${2:?engine binary}
sfm_destination=${3:?destination app}
[ -d "$sfm_source_app" ] && [ -f "$sfm_engine" ]
[ ! -e "$sfm_destination" ] || { echo 'Destination already exists; choose a fresh path.' >&2; exit 1; }
sfm_tools=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
/usr/bin/ditto "$sfm_source_app" "$sfm_destination"
# No Apple VPN entitlement or unused signed-extension/helper dependency.
/bin/rm -rf "$sfm_destination/Contents/Library/SystemExtensions" "$sfm_destination/Contents/Library/LaunchServices" "$sfm_destination/Contents/Library/LaunchDaemons" "$sfm_destination/Contents/PlugIns" "$sfm_destination/Contents/Extensions"
/usr/bin/install -m 755 "$sfm_engine" "$sfm_destination/Contents/Resources/sfm-route-engine"
/usr/bin/install -m 755 "$sfm_tools/install-local-engine.sh" "$sfm_destination/Contents/Resources/install-local-engine.sh"
/usr/bin/install -m 755 "$sfm_tools/uninstall-local-engine.sh" "$sfm_destination/Contents/Resources/uninstall-local-engine.sh"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName SFM Routes' "$sfm_destination/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName SFM Routes' "$sfm_destination/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$sfm_destination/Contents/Resources/sfm-route-engine"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$sfm_destination"
/usr/bin/codesign --verify --deep --strict "$sfm_destination"
