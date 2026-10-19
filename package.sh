#!/bin/bash
#
# Builds, signs and packages SwiftShot for a GitHub release.
#
#   ./package.sh [version]        # default: 1.0.0
#
# Produces dist/SwiftShot-v<version>-macOS.zip, ready to be uploaded with:
#   gh release upload v<version> dist/SwiftShot-v<version>-macOS.zip --clobber
#
set -e

cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
APP="SwiftShot"
BUILD_APP=".build-release/Build/Products/Release/${APP}.app"
DIST_DIR="dist"
ZIP_NAME="${APP}-v${VERSION}-macOS.zip"

echo "==> Building ${APP} v${VERSION} (Release)..."
xcodebuild -project SwiftShot.xcodeproj \
  -scheme SwiftShot \
  -configuration Release \
  -derivedDataPath .build-release \
  build >/dev/null

echo "==> Signing..."
CERT=$(security find-identity -v -p codesigning | grep -o 'Apple Development: [^"]*' | head -n 1 || true)
if [ -z "$CERT" ]; then
  CERT=$(security find-identity -v -p codesigning | grep -o 'Scribble Dev' | head -n 1 || true)
fi

if [ -n "$CERT" ]; then
  echo "    Using identity: $CERT"
  SIGN_IDENTITY="$CERT"
else
  echo "    WARNING: no developer certificate found — signing ad-hoc."
  echo "    The Screen Recording permission will be requested again after every rebuild."
  SIGN_IDENTITY="-"
fi

# The app is built with CODE_SIGNING_ALLOWED=NO, so signing (and the entitlements)
# happen here. Strip the quarantine flag BEFORE signing.
xattr -cr "$BUILD_APP"
codesign --force --sign "$SIGN_IDENTITY" --entitlements Sources/SwiftShot.entitlements "$BUILD_APP/Contents/MacOS/${APP}"
codesign --force --sign "$SIGN_IDENTITY" --entitlements Sources/SwiftShot.entitlements "$BUILD_APP"
codesign --verify --strict "$BUILD_APP"

echo "==> Packaging..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -R "$BUILD_APP" "$DIST_DIR/"

# --norsrc is essential: without it the archive contains AppleDouble (`._*`) sidecar
# files that get restored into the bundle on extraction and invalidate the code
# signature of the extracted app.
ditto -c -k --keepParent --norsrc "$DIST_DIR/${APP}.app" "$ZIP_NAME"

echo "==> Verifying the archive..."
VERIFY_DIR=$(mktemp -d)
unzip -q "$ZIP_NAME" -d "$VERIFY_DIR"
codesign --verify --strict "$VERIFY_DIR/${APP}.app"
rm -rf "$VERIFY_DIR"

echo "==> Signature:"
codesign -dvv "$BUILD_APP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" || true

echo
echo "Done: $ZIP_NAME"
echo "Upload with:"
echo "  gh release upload v${VERSION} ${ZIP_NAME} --clobber"
