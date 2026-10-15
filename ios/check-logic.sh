#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
swift test --package-path PonyCore --parallel --jobs 2
pony_bin_path="$(swift build --package-path PonyCore --show-bin-path)"
pony_check_dir="$(mktemp -d)"
trap 'rm -rf "$pony_check_dir"' EXIT
swiftc -parse-as-library -swift-version 6 \
  -I "$pony_bin_path/Modules" \
  Pony/AppStore.swift Checks/AppStoreChecks.swift \
  "$pony_bin_path/PonyCore.build/"*.swift.o \
  -o "$pony_check_dir/state-checks"
"$pony_check_dir/state-checks"
swiftc -frontend -parse Pony/*.swift
swift Checks/ProjectCheck.swift
