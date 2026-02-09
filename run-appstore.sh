#!/bin/bash
set -euo pipefail

SCHEME="Dimmerly App Store"
CONFIG="Debug-AppStore"

echo "Building $SCHEME ($CONFIG)..."
xcodebuild build -scheme "$SCHEME" -configuration "$CONFIG" -quiet

BUILD_DIR=$(xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -showBuildSettings 2>/dev/null \
    | sed -n 's/^ *BUILD_DIR = //p')

echo "Launching $BUILD_DIR/$CONFIG/Dimmerly.app"
open "$BUILD_DIR/$CONFIG/Dimmerly.app"
