#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

pony_selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ -z "${DEVELOPER_DIR:-}" && "$pony_selected_developer_dir" == "/Library/Developer/CommandLineTools" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

pony_check_dir="$(mktemp -d)"
trap 'rm -rf "$pony_check_dir"' EXIT
pony_scratch_path="${PONY_SWIFT_SCRATCH_PATH:-$pony_check_dir/swiftpm}"
pony_swift_options=(--package-path PonyCore --scratch-path "$pony_scratch_path")

swift test "${pony_swift_options[@]}" --parallel --jobs 2
pony_bin_path="$(swift build "${pony_swift_options[@]}" --show-bin-path)"

# SwiftPM 6.3 defaults to the swiftbuild engine, whose products and object
# files use an Xcode-style layout. Older toolchains keep both under the
# traditional debug directory. Locate either layout so this check works with
# Command Line Tools as well as Xcode 27+.
if [[ -d "$pony_bin_path/PonyCore.swiftmodule" ]]; then
  pony_module_path="$pony_bin_path"
  pony_build_root="$(cd "$pony_bin_path/../.." && pwd)"
  pony_object_dir="$(find "$pony_build_root/Intermediates.noindex/PonyCore.build" \
    -type d -path '*/PonyCore-t.build/Objects-normal/*' -print -quit)"
  pony_objects=("$pony_object_dir"/*.o)
else
  pony_module_path="$pony_bin_path/Modules"
  pony_objects=("$pony_bin_path/PonyCore.build/"*.swift.o)
fi
if [[ ! -d "$pony_module_path" || ! -e "${pony_objects[0]}" ]]; then
  echo 'Unable to locate PonyCore build objects.' >&2
  exit 1
fi
swiftc -parse-as-library -swift-version 6 \
  -I "$pony_module_path" \
  Pony/AppStore.swift Checks/AppStoreChecks.swift \
  "${pony_objects[@]}" \
  -o "$pony_check_dir/state-checks"
"$pony_check_dir/state-checks"
swiftc -frontend -parse Pony/*.swift
swift Checks/ProjectCheck.swift
