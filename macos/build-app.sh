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

# OpenPGP uses RNP, the library Thunderbird bundles. Take it from a local Thunderbird build,
# or an installed Thunderbird, if one is available.
for RNP in "${LIBRNP:-}" ../../obj-*/dist/bin/librnp.dylib /Applications/Thunderbird.app/Contents/MacOS/librnp.dylib; do
  if [ -n "$RNP" ] && [ -f "$RNP" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp "$RNP" "$APP/Contents/Frameworks/librnp.dylib"
    codesign --force --sign - "$APP/Contents/Frameworks/librnp.dylib" >/dev/null
    echo "Bundled $RNP"
    break
  fi
done
# Ad-hoc signatures change with every build. Pinning the designated requirement to the
# bundle identifier lets Keychain recognise rebuilt copies of the app, so saved passwords
# don't prompt for access after each build. Set CODESIGN_IDENTITY to sign with a real identity.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$APP" >/dev/null
else
  codesign --force --sign - --identifier net.thunderbird.mac \
    --requirements '=designated => identifier "net.thunderbird.mac"' "$APP" >/dev/null
fi

echo "Built $(pwd)/$APP"
