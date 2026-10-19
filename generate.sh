#!/bin/bash
set -e

cd "$(dirname "$0")"

if ! command -v xcodegen &>/dev/null; then
  echo "xcodegen is not installed. Install it with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate
echo "Generated SwiftShot.xcodeproj — open it with: open SwiftShot.xcodeproj"
