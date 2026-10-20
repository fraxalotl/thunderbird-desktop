#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# Builds Thunderbird.app from the Swift package. Usage: ./build-app.sh [debug|release]

set -eu

cd "$(dirname "$0")"
CONFIGURATION="${1:-release}"
APP="build/Thunderbird.app"

swift build -c "$CONFIGURATION" --product Thunderbird
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Thunderbird" "$APP/Contents/MacOS/Thunderbird"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp ../mail/branding/thunderbird/thunderbird.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null

echo "Built $(pwd)/$APP"
