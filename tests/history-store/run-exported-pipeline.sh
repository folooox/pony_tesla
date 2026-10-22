#!/bin/bash
# macOS only. Run from repository root, with exact backend bundle directory as $1.
set -euo pipefail
bundle="$(cd "${1:?Usage: bash tests/history-store/run-exported-pipeline.sh /absolute/export-bundle}" && pwd -P)"
harness=.airbuild/history-store-harness
mkdir -p "$harness/Sources/HistoryStoreHarness" "$harness/Tests/HistoryStoreHarnessTests"
cp tests/history-store/Package.swift "$harness/Package.swift"
cp ios/Pony/NativeTeslaClient.swift ios/Pony/NativeHistoryStore.swift "$harness/Sources/HistoryStoreHarness/"
cp tests/history-store/HistoryStoreTests.swift tests/history-store/ExportedPipelineTests.swift "$harness/Tests/HistoryStoreHarnessTests/"
NATIVE_HISTORY_PIPELINE_BUNDLE="$bundle" swift test --package-path "$harness" --filter ExportedPipelineTests
