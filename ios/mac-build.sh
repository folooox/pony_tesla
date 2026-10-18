#!/usr/bin/env bash
# Build an unsigned simulator app; run from any directory.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Requires macOS and full Xcode 27+ with the iOS 27+ SDK.' >&2
  exit 1
fi
pony_selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ -z "${DEVELOPER_DIR:-}" && "$pony_selected_developer_dir" == "/Library/Developer/CommandLineTools" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
xcodebuild -version
pony_sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
if [[ "${pony_sdk_version%%.*}" -lt 27 ]]; then
  echo "iOS Simulator SDK 27+ required; found $pony_sdk_version. Check xcode-select." >&2
  exit 1
fi
mkdir -p artifacts/mac-build
# pipefail preserves build/check failures while tee retains diagnostic logs.
bash ios/check-logic.sh 2>&1 | tee artifacts/mac-build/logic.log
xcodebuild -project ios/Pony.xcodeproj -scheme Pony \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath ios/DerivedData \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | tee artifacts/mac-build/build.log
echo 'Built: ios/DerivedData/Build/Products/Debug-iphonesimulator/Pony.app'
echo 'Next: open ios/Pony.xcodeproj, choose Pony and an iOS 27 simulator, then Run.'
