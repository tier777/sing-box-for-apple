#!/bin/bash
# Builds the iOS Routes screens into a Simulator-only app without Libbox,
# signing or Xcode targets. Usage: Tools/RoutesPreviewIOS/build.sh [output-dir]
set -euo pipefail

cd "$(dirname "$0")/../.."
OUT="${1:-build/RoutesPreviewIOS}"
APP="$OUT/SFM Routes.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios16.0-simulator"

rm -rf "$OUT"
mkdir -p "$OUT/modules" "$APP"

# Library holds the shared model types; build it as its own module so the
# view files keep their `import Library`.
xcrun --sdk iphonesimulator swiftc -sdk "$SDK" -target "$TARGET" -parse-as-library -O \
    -module-name Library -emit-module -emit-module-path "$OUT/modules/Library.swiftmodule" \
    -emit-library -static -o "$OUT/modules/libLibrary.a" \
    Library/Network/RouteHealthState.swift Library/Network/ProfileRulesDocument.swift

xcrun --sdk iphonesimulator swiftc -sdk "$SDK" -target "$TARGET" -parse-as-library -O \
    -module-name RoutesPreview -I "$OUT/modules" -L "$OUT/modules" -lLibrary \
    -o "$APP/RoutesPreview" \
    ApplicationLibrary/Views/Routes/RoutesVocabulary.swift \
    ApplicationLibrary/Views/Routes/iOS/*.swift \
    Tools/RoutesPreviewIOS/main.swift

cp Tools/RoutesPreviewIOS/Info.plist "$APP/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
