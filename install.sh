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
# Find Apple Development certificate if available, otherwise fall back to Scribble Dev or ad-hoc with stable designated requirement
CERT=$(security find-identity -v -p codesigning | grep -o 'Apple Development: [^"]*' | head -n 1 || true)
if [ -z "$CERT" ]; then
  CERT=$(security find-identity -v -p codesigning | grep -o 'Scribble Dev' | head -n 1 || true)
fi

APP_PATH=".build-release/Build/Products/Release/SwiftShot.app"

if [ -n "$CERT" ]; then
  echo "Using identity: $CERT"
  codesign --force --deep --sign "$CERT" "$APP_PATH"
else
  echo "No developer certificate found, signing ad-hoc..."
  codesign --force --deep --sign - "$APP_PATH"
fi

echo "Installing to /Applications/SwiftShot.app..."
pkill -f "/Applications/SwiftShot.app/Contents/MacOS/SwiftShot" || true
rm -rf /Applications/SwiftShot.app
cp -R "$APP_PATH" /Applications/
cp Sources/Resources/AppIcon.icns /Applications/SwiftShot.app/Contents/Resources/
xattr -cr /Applications/SwiftShot.app

echo "Re-verifying signature..."
if [ -n "$CERT" ]; then
  codesign --force --deep --sign "$CERT" /Applications/SwiftShot.app
else
  codesign --force --deep --sign - /Applications/SwiftShot.app
fi
codesign -d -r- /Applications/SwiftShot.app

echo "Launching SwiftShot..."
open /Applications/SwiftShot.app
echo "Done! SwiftShot is up and running."
