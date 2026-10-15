# Pony Tesla

English | [简体中文](README.md)

A third-party iOS app for Tesla owners in mainland China, initially targeting the China-built 2022 Model 3. Built with SwiftUI, MapKit, Swift Charts and native Liquid Glass for vehicle controls, charging and the latest 168 hours of trips.

> The native client currently uses synthetic data and does not control a real vehicle. The backend provides connection testing and history APIs, but native authentication, live commands, continuous telemetry and backend sessions are not integrated. No iOS SDK build, simulator run or device validation has been performed in this environment.

## Start on a Mac

Use **Xcode 27, the iOS 27 SDK and an iOS 27 simulator**. The deployment target is iOS 27.0. Your Mac must meet [Apple’s requirements for your Xcode version](https://developer.apple.com/xcode/system-requirements/). The native demo needs no Node.js, Tesla credentials, backend or paid developer account.

```sh
git clone https://github.com/folooox/pony_tesla.git
cd pony_tesla
bash ios/mac-build.sh
open ios/Pony.xcodeproj
```

Select **Pony → an iOS 27 simulator → Run (⌘R)** in Xcode. The script checks the toolchain, runs logic checks and builds an unsigned simulator app. It does not launch a simulator.

Follow the [complete Mac build guide](docs/mac-build.en.md) for Xcode setup, simulator installation, device signing, logs and troubleshooting.

## Implementation status

| Component | Status |
| --- | --- |
| Native Vehicle, Trips, Charging and Profile | Demo interactions, saved shortcut layout, maps, playback, notes, CSV and seven scenarios |
| Native core and state management | Swift checks available; see the [validation record](ios/VALIDATION.md) |
| Tesla connection tool | China-region OAuth, encrypted token storage/refresh, vehicle list and single status read; real authorization pending |
| History backend | SQLite status cache, trip list/detail/notes/deletion/CSV, 168-hour retention and isolated synthetic ingestion |
| Remaining work | Native real sessions/commands, continuous collection, vehicle integration, iOS build/visual acceptance, release icons and store materials |

Demo vehicle state, notes and history reset between launches. Shortcut layout persists in UserDefaults. Existing `screenshots/` and `prototype/` show an earlier web design, not the current native interface.

## Optional local backend

Requires Node.js 24.5+ for built-in SQLite. No third-party runtime dependencies:

```sh
npm test
npm run test:history-flow
npm run setup
npm start
```

Run `setup` once to create `.env` and `.private/`; existing configuration is never overwritten. Complete configuration in `.env`. The default local port is 8787; the admin username is `owner`, with its generated password in the local `.env`. Real OAuth requires Tesla developer credentials and a matching HTTPS origin; see [connection setup](docs/connection-test.md) (Chinese). Never commit credentials, authorization data, private keys or runtime databases.

Browser tests additionally need development dependencies:

```sh
npm ci
npx playwright install chromium
npm run test:browser
```

On Linux, use `npx playwright install --with-deps chromium` if system libraries are missing. Native builds do not require npm installation.

## Repository and documentation

- `ios/`: native project, local PonyCore Swift package, logic checks and Mac build script.
- `backend/`: single-owner connection tool, history services and admin web UI.
- `deploy/`: Linux service, Nginx, certificate renewal and deployment checks.
- [Mac build guide](docs/mac-build.en.md) / [中文流程](docs/mac-build.zh-CN.md)
- [Native project](ios/README.md), [simulator checklist](ios/SIMULATOR-CHECKLIST.md), [validation record](ios/VALIDATION.md) (Chinese)
- [Product scope](docs/product-requirements.md), [backend API](docs/backend-api.md), [deployment](docs/deployment.md), [backend test record](docs/test-report.md) (Chinese)

An independent third-party project, not affiliated with or endorsed by Tesla. No open-source license has been selected for this repository.
