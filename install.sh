#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building SwiftShot (Release)..."
xcodebuild -project SwiftShot.xcodeproj \
  -scheme SwiftShot \
  -configuration Release \
  -derivedDataPath .build-release \
  build >/dev/null

echo "Signing SwiftShot with stable Apple Development identity..."
# Find Apple Development certificate if available, otherwise fall back to Scribble Dev or ad-hoc.
CERT=$(security find-identity -v -p codesigning | grep -o 'Apple Development: [^"]*' | head -n 1 || true)
if [ -z "$CERT" ]; then
  CERT=$(security find-identity -v -p codesigning | grep -o 'Scribble Dev' | head -n 1 || true)
fi

APP_PATH=".build-release/Build/Products/Release/SwiftShot.app"
INSTALLED_APP="/Applications/SwiftShot.app"

if [ -n "$CERT" ]; then
  echo "Using identity: $CERT"
else
  echo "WARNING: no developer certificate found — signing ad-hoc."
  echo "         macOS ties the Screen Recording permission to the code signature,"
  echo "         so it will be requested again after every rebuild. Install an"
  echo "         'Apple Development' certificate for a one-time grant."
fi

echo "Installing to $INSTALLED_APP..."
pkill -f "/Applications/SwiftShot.app/Contents/MacOS/SwiftShot" || true
rm -rf "$INSTALLED_APP"
cp -R "$APP_PATH" "$INSTALLED_APP"
cp Sources/Resources/AppIcon.icns "$INSTALLED_APP/Contents/Resources/"

# Sign the executable first, then the bundle — avoids `codesign --deep`, which is
# not recommended because it can sign nested code with the wrong identity.
# IMPORTANT: the *installed* copy has to be signed, not the build directory.
# The app is built with CODE_SIGNING_ALLOWED=NO, so the entitlements have to be
# applied here as well.
ENTITLEMENTS="Sources/SwiftShot.entitlements"
sign_app() {
  if [ -n "$CERT" ]; then
    codesign --force --sign "$CERT" --entitlements "$ENTITLEMENTS" "$INSTALLED_APP/Contents/MacOS/SwiftShot"
    codesign --force --sign "$CERT" --entitlements "$ENTITLEMENTS" "$INSTALLED_APP"
  else
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$INSTALLED_APP/Contents/MacOS/SwiftShot"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$INSTALLED_APP"
  fi
}

# Strip the quarantine flag BEFORE signing so the signature stays valid.
xattr -cr "$INSTALLED_APP"
sign_app

echo "Re-verifying signature..."
codesign -dvvv "$INSTALLED_APP" 2>&1 | grep -E "Identifier|Authority|Signature|TeamIdentifier" || true
codesign -d -r- "$INSTALLED_APP"

echo "Launching SwiftShot..."
open "$INSTALLED_APP"
echo "Done! SwiftShot is up and running."
