#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION="${CONFIGURATION:-release}"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
IDENTITY_FILE="$PROJECT_DIR/.codesign-identity.local"
if [[ -z "$SIGNING_IDENTITY" && -f "$IDENTITY_FILE" ]]; then SIGNING_IDENTITY="$(cat "$IDENTITY_FILE")"; fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '
        /"(Developer ID Application|Apple Development|Mac Developer):/ && !/CSSMERR/ && length($2) == 40 { print $2; exit }
    ')"
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
./Scripts/swift.sh build --configuration "$CONFIGURATION"
BINARY_DIR="$(./Scripts/swift.sh build --configuration "$CONFIGURATION" --show-bin-path)"
export SDKROOT="$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
if [[ ! -f Resources/AppIcon.icns || Scripts/GenerateIcon.swift -nt Resources/AppIcon.icns ]]; then
    ICON_PARENT="$(mktemp -d)"
    swift Scripts/GenerateIcon.swift "$ICON_PARENT/AppIcon.iconset"
    cp "$ICON_PARENT/AppIcon.icns" Resources/AppIcon.icns
    rm -r "$ICON_PARENT"
fi
if [[ ! -f Resources/MyActive.icns || Scripts/GenerateIcon.swift -nt Resources/MyActive.icns ]]; then
    ICON_PARENT="$(mktemp -d)"
    swift Scripts/GenerateIcon.swift "$ICON_PARENT/MyActive.iconset" MyActive
    cp "$ICON_PARENT/MyActive.icns" Resources/MyActive.icns
    rm -r "$ICON_PARENT"
fi
mkdir -p dist
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/dist/.mytool-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP="$STAGING_DIR/MyTool.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY_DIR/MyTool" "$APP/Contents/MacOS/MyTool"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/*.icns "$APP/Contents/Resources/"
codesign --force --sign "$SIGNING_IDENTITY" --identifier dev.daodao.MyTool "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict "$APP"
if [[ "$SIGNING_IDENTITY" != '-' ]]; then printf '%s\n' "$SIGNING_IDENTITY" > "$IDENTITY_FILE"; fi
if [[ -d dist/MyTool.app ]]; then mv dist/MyTool.app "$STAGING_DIR/previous.app"; fi
if ! mv "$APP" dist/MyTool.app; then
    if [[ -d "$STAGING_DIR/previous.app" ]]; then mv "$STAGING_DIR/previous.app" dist/MyTool.app; fi
    exit 1
fi
printf 'Built: %s/dist/MyTool.app\n' "$PROJECT_DIR"
