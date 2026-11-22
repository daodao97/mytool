#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION=debug ./Scripts/build.sh
QA_DIR="$PROJECT_DIR/dist/qa"
mkdir -p "$QA_DIR"
PREVIEW_ROOT="$(mktemp -d)"
trap 'rm -rf "$PREVIEW_ROOT"' EXIT
for entry in 'home:home' 'settings:settings' 'screen:概览:screen-overview' 'screen:窗口排布:screen-arrangement' 'screen:设置:screen-settings' 'clip:settings:clip-settings' 'clip:panel:clip-panel' 'clip:json:clip-json' 'clip:json-path:clip-json-path' 'clip:json-fuzzy:clip-json-fuzzy' 'clip:json-panel:clip-json-panel' 'clip:json-cards:clip-json-cards' 'active:idle:active-idle' 'active:running:active-running' 'active:paused:active-paused'; do
    MYTOOL_PREVIEW_ROOT="$PREVIEW_ROOT" \
    MYTOOL_UI_SMOKE_SECTION="${entry%:*}" \
    MYTOOL_UI_SMOKE_OUTPUT="$QA_DIR/${entry##*:}.png" \
        "$PROJECT_DIR/dist/MyTool.app/Contents/MacOS/MyTool"
done
printf 'UI previews: %s\n' "$QA_DIR"
