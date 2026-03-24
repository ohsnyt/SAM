#!/bin/bash
#
# build-dmg.sh — Create a drag-to-Applications DMG installer for SAM.
#
# Usage:
#   ./scripts/build-dmg.sh                         # Archive in Xcode, then package DMG
#   ./scripts/build-dmg.sh /path/to/SAM.app        # Skip archive, package existing .app
#
# Prerequisites:
#   brew install create-dmg
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
DMG_STAGING="${BUILD_DIR}/dmg-staging"
ARCHIVE_PATH="${BUILD_DIR}/SAM.xcarchive"
APP_NAME="SAM"

# Read version from Xcode project
VERSION=$(grep -m1 'MARKETING_VERSION' "${PROJECT_DIR}/SAM.xcodeproj/project.pbxproj" \
    | head -1 | sed 's/.*= *\(.*\);/\1/' | tr -d ' "')
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_OUTPUT="${BUILD_DIR}/${DMG_NAME}"

echo "==> SAM DMG Builder (v${VERSION})"
echo ""

# Check for create-dmg
if ! command -v create-dmg &>/dev/null; then
    echo "Error: create-dmg not found. Install with: brew install create-dmg"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────
# Step 1: Get the .app
# ─────────────────────────────────────────────────────────────────────

if [[ ${1:-} != "" ]]; then
    # User provided a path to an already-signed .app
    APP_PATH="$1"
    if [[ ! -d "$APP_PATH" ]]; then
        echo "Error: $APP_PATH does not exist"
        exit 1
    fi
    echo "==> Using provided app: ${APP_PATH}"
else
    # Archive via xcodebuild, then prompt user to distribute via Organizer
    echo "==> Step 1: Archiving ${APP_NAME}..."
    xcodebuild -project "${PROJECT_DIR}/SAM.xcodeproj" \
        -scheme SAM \
        -configuration Release \
        -archivePath "${ARCHIVE_PATH}" \
        archive \
        | tail -3

    echo ""
    echo "==> Archive complete: ${ARCHIVE_PATH}"
    echo ""
    echo "    The archive will open in Xcode's Organizer."
    echo "    Please:"
    echo "      1. Click 'Distribute App'"
    echo "      2. Wait for Apple to return the signed build"
    echo "      3. Export the notarized app to a folder"
    echo ""

    # Open the archive in Organizer
    open "${ARCHIVE_PATH}"

    echo -n "    Enter the path to the exported SAM.app (drag it here): "
    read -r APP_PATH

    # Strip quotes that drag-and-drop may add
    APP_PATH="${APP_PATH%\"}"
    APP_PATH="${APP_PATH#\"}"
    APP_PATH="${APP_PATH%\'}"
    APP_PATH="${APP_PATH#\'}"
    # Strip trailing whitespace
    APP_PATH="$(echo -n "$APP_PATH" | sed 's/[[:space:]]*$//')"

    if [[ ! -d "$APP_PATH" ]]; then
        echo "Error: ${APP_PATH} does not exist"
        exit 1
    fi
fi

# Verify it's actually an .app bundle
if [[ ! -f "${APP_PATH}/Contents/Info.plist" ]]; then
    echo "Error: ${APP_PATH} doesn't look like a valid .app bundle"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────
# Step 2: Create DMG
# ─────────────────────────────────────────────────────────────────────

echo "==> Step 2: Creating DMG..."

# Clean previous build artifacts
rm -rf "${DMG_STAGING}"
rm -f "${DMG_OUTPUT}"
mkdir -p "${DMG_STAGING}"

# Copy app to staging
cp -R "${APP_PATH}" "${DMG_STAGING}/${APP_NAME}.app"

# Create DMG with drag-to-Applications layout
create-dmg \
    --volname "${APP_NAME}" \
    --volicon "${APP_PATH}/Contents/Resources/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 150 190 \
    --app-drop-link 450 190 \
    --hide-extension "${APP_NAME}.app" \
    --no-internet-enable \
    "${DMG_OUTPUT}" \
    "${DMG_STAGING}" \
    || true  # create-dmg exits 2 on success if no background image set

# Verify DMG was created
if [[ ! -f "${DMG_OUTPUT}" ]]; then
    echo "Error: DMG creation failed"
    exit 1
fi

# Clean up staging
rm -rf "${DMG_STAGING}"

# ─────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────

DMG_SIZE=$(du -h "${DMG_OUTPUT}" | cut -f1 | tr -d ' ')
echo ""
echo "==> Done! DMG created:"
echo "    ${DMG_OUTPUT} (${DMG_SIZE})"
echo ""
echo "    To verify: open \"${DMG_OUTPUT}\""
