# Mac build and first run

[简体中文](mac-build.zh-CN.md) | [README](../README.en.md)

First build and run the existing demo on a Mac, then validate on a device. This is a procedure to execute, not a successful Mac build record. The native demo needs no backend or Tesla credentials.

## 1. Prepare Xcode

1. Install full **Xcode 27** with the iOS 27 SDK. Command Line Tools alone are insufficient. Check your Mac against [Apple’s system requirements](https://developer.apple.com/xcode/system-requirements/).
2. Open Xcode, accept its license and finish installing initial components.
3. Download an iOS 27 Simulator Runtime under Xcode → Settings → Components. Create an iPhone simulator under Window → Devices and Simulators.
4. Select the toolchain below. Adjust the first path if Xcode is installed elsewhere:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
xcodebuild -version
xcrun --sdk iphonesimulator --show-sdk-version
swift --version
xcrun simctl list devices available
```

Requires iOS Simulator SDK 27+ and Swift 6.2+. The deployment target is iOS 27.0; lowering it does not fix a missing SDK.

## 2. Clone and build

```sh
mkdir -p ~/Developer
cd ~/Developer
git clone https://github.com/folooox/pony_tesla.git
cd pony_tesla
bash ios/mac-build.sh
```

For an existing clean checkout, use `git pull --ff-only`. A private repository requires access through your GitHub account.

The script runs PonyCore tests, AppStore checks, syntax and project checks, then builds the shared Pony scheme for the simulator without signing. It does not download Xcode, change signing or launch a simulator. PonyCore is a local package; no remote Swift packages are needed.

Generated outputs, excluded from Git:

- App: `ios/DerivedData/Build/Products/Debug-iphonesimulator/Pony.app`
- Logic log: `artifacts/mac-build/logic.log`
- Build log: `artifacts/mac-build/build.log`

## 3. Run in Simulator

```sh
open ios/Pony.xcodeproj
```

Choose the **Pony** scheme and an iPhone running iOS 27, then press **⌘R**. Start with a simulator destination. No signing team is needed.

The default scenario is `normal`. Switch under Profile → simulator testing, or add two separate launch arguments under Product → Scheme → Edit Scheme → Run → Arguments: `-scenario` and `missingData`. Supported values: `normal`, `empty`, `asleep`, `offline`, `error`, `expired`, `missingData`. Remove launch arguments afterward to restore the default.

Follow the [simulator checklist](../ios/SIMULATOR-CHECKLIST.md) (Chinese) to test all four tabs, command confirmation, chart playback, CSV, notes, error scenarios and accessibility. Maps and place search need network access. Other demo flows need no real account. Demo history and notes reset between launches; shortcut ordering persists.

## 4. Run on an iPhone

1. Use an iPhone running iOS 27+. Connect it, trust the Mac and enable Developer Mode when prompted.
2. Add your Apple account under Xcode Settings → Accounts.
3. Select the Pony target → Signing & Capabilities → Automatically manage signing, then choose your Team.
4. If needed, replace `party.ponypro.Pony` with your own unique bundle identifier. Do not commit another person’s signing configuration or credentials.
5. Select the connected iPhone and press ⌘R. The app still uses demo data and does not control a vehicle.

Personal account signing limits follow Apple/Xcode rules. TestFlight and App Store distribution also require developer membership, icons, distribution signing and store materials. This procedure does not establish release readiness.

## 5. Troubleshooting and handoff

| Symptom | Action |
| --- | --- |
| `xcodebuild` uses Command Line Tools | Repeat `xcode-select` above or set `DEVELOPER_DIR` for the current terminal to your full Xcode installation |
| Missing SDK or destination | Install the SDK/runtime; inspect `xcodebuild -project ios/Pony.xcodeproj -scheme Pony -showdestinations` |
| Missing PonyCore | Clone the full repository, preserve `ios/PonyCore`, and open `ios/Pony.xcodeproj` |
| SwiftUI API, actor isolation or linker errors | Keep the full log and first error; these require actual iOS SDK validation, beyond syntax checks |
| Signing failure | Use the unsigned script for simulator builds; configure Team and a unique bundle ID for devices |
| Suspected stale build cache | Close Xcode, delete only generated `ios/DerivedData`, and rerun the script |
| No tests in `xcodebuild test` | The app scheme has no XCTest/UI Test target; run `bash ios/check-logic.sh` for existing logic checks |

Append your Mac model/architecture, macOS, Xcode, SDK, simulator model/OS, commit SHA (`git rev-parse HEAD`), build result and outstanding issues to the [validation record](../ios/VALIDATION.md). Capture actual simulator/device screenshots, not the older web prototype. On failure, retain both logs and the first error. After a successful build, proceed with visual acceptance and later real-service integration.
