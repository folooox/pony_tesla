#!/bin/bash
set -e -o pipefail
ROOT="$PWD"
OUT="$ROOT/wake-base-evidence"
mkdir -p "$OUT"
{ sw_vers; xcodebuild -version; } > "$OUT/environment.txt"
shasum -a 256 backend/*.mjs ios/PonyCore/Sources/PonyCore/*.swift ios/PonyCore/Tests/PonyCoreTests/*.swift > "$OUT/source.sha256"
NODE_VERSION=24.5.0
NODE_ARCHIVE="node-v${NODE_VERSION}-darwin-arm64.tar.gz"
NODE_DIR=$(mktemp -d /tmp/pony-wake-node.XXXXXX)
trap 'rm -rf "$NODE_DIR"' EXIT
cd "$NODE_DIR"
curl --connect-timeout 15 --max-time 180 -fsSLo "$NODE_ARCHIVE" "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ARCHIVE}"
curl --connect-timeout 15 --max-time 60 -fsSLo SHASUMS256.txt "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"
grep "  ${NODE_ARCHIVE}$" SHASUMS256.txt > expected.sha256
shasum -a 256 -c expected.sha256 > "$OUT/node-checksum.txt"
tar -xzf "$NODE_ARCHIVE"
export PATH="$NODE_DIR/node-v${NODE_VERSION}-darwin-arm64/bin:$PATH"
cd "$ROOT"
node --version > "$OUT/node-version.txt"
set +e
node --test backend/*.test.mjs > "$OUT/backend-tests.log" 2>&1
BACKEND=$?
(cd ios/PonyCore && swift test) > "$OUT/core-tests.log" 2>&1
CORE=$?
set -e
printf '{"backendExit":%s,"coreExit":%s,"syntheticOnly":true}\n' "$BACKEND" "$CORE" > "$OUT/result.json"
cat "$OUT/result.json"
if [ "$BACKEND" -ne 0 ] || [ "$CORE" -ne 0 ]; then grep -n -E 'not ok|error:|failed|Error' "$OUT/backend-tests.log" "$OUT/core-tests.log" || true; exit 1; fi
