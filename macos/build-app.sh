#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# Builds Zapdos.app from the Swift package. Usage: ./build-app.sh [debug|release]

set -eu

cd "$(dirname "$0")"
CONFIGURATION="${1:-release}"
APP="build/Zapdos.app"

swift build -c "$CONFIGURATION" --product Thunderbird
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Thunderbird" "$APP/Contents/MacOS/Zapdos"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

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
# Keychain remembers which apps may read saved passwords by their signature. For an ad-hoc
# signature that is the hash of this exact build, so every rebuild asks for the keychain
# password again, once per account. A certificate gives rebuilt copies the same identity, so
# sign with one when there is one: CODESIGN_IDENTITY if set, otherwise the first Developer ID
# or Apple Development identity in the keychain.
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Developer ID Application:/ { print $2; exit }')"
fi
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development:/ { print $2; exit }')"
fi
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$APP" >/dev/null
else
  codesign --force --sign - --identifier net.thunderbird.mac \
    --requirements '=designated => identifier "net.thunderbird.mac"' "$APP" >/dev/null
fi

echo "Built $(pwd)/$APP"
