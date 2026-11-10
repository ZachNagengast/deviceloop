# Contributing to DeviceLoop

## Overview

Contributions are welcome: bug fixes, documentation, and new commands from the [parity page](docs/parity.md). This guide covers building, testing, the on-device runner project and releases.

## Getting Started

1. Fork the repository on GitHub.

2. Clone your fork:

   ```bash
   git clone https://github.com/[your-username]/deviceloop.git
   cd deviceloop
   ```

3. Install Xcode 27 or later and select it:

   ```bash
   sudo xcode-select -s /Applications/Xcode.app
   ```

   [Install](README.md#install) lists the other requirements.

Use `xcrun swift` for every Swift command. The `Makefile` already does. A toolchain installed with swiftly can come first on `PATH` and fails to build swift-argument-parser against the Xcode 27 SDK.

## Building and Testing

```bash
make build
make test
```

These run `xcrun swift build` and `xcrun swift test`. `make test` sets `DEVICELOOP_HOME` to `.build/deviceloop-home`, so tests leave `~/Library/Caches` alone. Unit tests use Swift Testing and live in `Tests/DeviceLoopKitTests`. Recorded `devicectl --json-output`, `xcresulttool`, `xctrace` and crash report files in `Tests/DeviceLoopKitTests/Resources` let tests run without a device.

Run the CLI from the build directory:

```bash
xcrun swift run deviceloop doctor
```

Set `DEVICELOOP_HOME` to keep runner builds, sessions, runs and artifacts out of `~/Library/Caches/deviceloop` while you work:

```bash
export DEVICELOOP_HOME="$PWD/.build/deviceloop-home"
```

Suites named `*LiveTests` (`ParityLiveTests`, `DeviceStateLiveTests`, `DoctorLiveTests` and `FlowLiveTests`) run against a booted simulator, and only when `DEVICELOOP_TEST_SIMULATOR` names it:

```bash
DEVICELOOP_TEST_SIMULATOR=<udid> xcrun swift test --filter FlowLiveTests
```

`ParityLiveTests` replaces the simulator's pasteboard and leaves its test text on it. `deviceloop pasteboard copy "" --device <udid>` empties it again.

`make lint` checks formatting with `swift format` and the repo's `.swift-format`. Run `xcrun swift format --in-place <file>` on the files you changed, not on the whole tree.

`trace record` and `video capture --instruments` classify xctrace failures from xctrace 27.2 output. A failure before xctrace prints `Ctrl-C to stop the recording`, or one whose `[Error]` line says `not supported`, is `unsupported_on_target`, and any other is `device_error`. Check both strings when Xcode updates.

## Testing on devices

Use simulators by default. On a physical device, prefer read-only commands such as `devices`, `info`, `doctor`, `screenshot` and `crashes`. Install apps, change settings or read the pasteboard only on a device you own for testing, and change any setting back when you are done. Run `deviceloop state scope start` before the changes and `deviceloop state restore` after them to set appearance and orientation back.

`deviceloop doctor` lists what is missing on each device, with one fix per problem. `deviceloop prepare --device <udid>` works through them, as [Requirements and device setup](docs/reference.md#requirements-and-device-setup) describes.

## The runner project

UI commands drive a target through an XCUITest runner built from `Runner/DeviceLoopRunner.xcodeproj`. It has four targets:

- `DeviceLoopHost`: the host app that the UI test bundle needs. Launch arguments turn on the test fixture screens that the smoke tests use.
- `DeviceLoopRunner`: the UI test bundle. It serves the HTTP API the CLI calls, and its `DeviceLoopMeasure` tests run `perf launch` and `perf run`.
- `DeviceLoopIntents`: a framework that links AppIntentsTesting. It is embedded in the runner under `Frameworks` but not linked, and the runner loads it on the first App Intents request on iOS 27 and later. `Runner/Intents/IntentsBridging.swift` is compiled into both, and the framework also compiles `Runner/Shared/RunnerProtocol.swift`.
- `DeviceLoopSiriFixture`: a test app for Siri scenarios, named "deviceloop fixture" on the home screen. The `DeviceLoopRunner` scheme does not build it, so `deviceloop runner start` does not install it. [scripts/README.md](scripts/README.md#the-siri-fixture) shows how to build and install it.

Working on it:

- `Runner/project.yml` is the source of `Runner/DeviceLoopRunner.xcodeproj`. Regenerate the project with `make runner-project`, which needs [XcodeGen](https://github.com/yonaskolb/XcodeGen). Commit both files. `Tests/ExportCheck`, `Examples/Sample` and `Examples/SuiteFixture` have their own `project.yml`. Run `xcodegen generate` in that folder.
- `make runner` builds the runner for the simulator without signing.
- DeviceLoop builds the runner on the first UI command for a target and caches the build under `$DEVICELOOP_HOME/runner`, keyed by the Xcode, SDK and compiler versions, the signing team and every file under `Runner/`. It reuses a live runner started by the same DeviceLoop version, so after changing files under `Runner/`, stop it with `deviceloop runner stop --device <udid>`.
- DeviceLoop finds the project at `$DEVICELOOP_RUNNER_PATH`, then at `share/deviceloop/Runner` next to an installed binary, then at `Runner/` in a checkout.
- `Runner/Configuration/Signing.xcconfig` appends the development team to the host, runner and Siri fixture bundle IDs, the way Apple's sample code projects do, so every team signs IDs of its own. Simulator builds have no team and use `com.argmaxinc.deviceloop.host` and `com.argmaxinc.deviceloop.runner`. For team `ABCDE12345` the host is `com.argmaxinc.deviceloop.hostABCDE12345`.
- For a device, DeviceLoop builds the runner with the team `deviceloop setup` stored, and xcodebuild registers the device with that team when it is not registered yet. The same build by hand:

  ```bash
  xcodebuild build-for-testing \
    -project Runner/DeviceLoopRunner.xcodeproj \
    -scheme DeviceLoopRunner \
    -configuration Debug \
    -destination id=<device UDID> \
    -derivedDataPath .build/runner-device \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM=<team ID>
  ```

- `deviceloop setup --team <team ID>` stores the team in `config.json` under `DEVICELOOP_HOME`. `deviceloop doctor` shows the teams signed in to Xcode and which ones have an Apple Development identity.
- [scripts/README.md](scripts/README.md) describes the smoke tests: the UI fixture, run comparison, runner operations, Siri scenarios and the exported flow check. `make export-check DEVICE=<booted simulator UDID> ARTIFACTS=<new dir>` runs the exported flow check.

## Releasing

DeviceLoop has no release yet. This is the planned process. The Homebrew tap `argmaxinc/homebrew-tap` is not published, so today DeviceLoop installs by [building from source](README.md#install).

- The version is `version` in `Sources/DeviceLoopKit/Core/Version.swift`. Add the release to `CHANGELOG.md` and set its date when you tag.
- `make dist TAG=v<version>` runs `scripts/release.sh` on an Apple silicon Mac. It checks that the tag matches the version, builds the arm64 release binary, signs it and `DeviceLoopCapture.app` with Argmax's Developer ID and the hardened runtime, notarizes both, staples the app, writes `dist/deviceloop-<version>-arm64.tar.gz` and prints its sha256.
- The tarball holds `bin/deviceloop`, `libexec/DeviceLoopCapture.app`, the runner project and agent skill under `share/deviceloop`, `LICENSE` and `NOTICE`. It copies `Runner` and `skills` as they are on disk, so run `make dist` from a clean clone of the tag.
- Notarization uses the App Store Connect API key in `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`, or `NOTARY_PROFILE`, a profile saved with `xcrun notarytool store-credentials`. `SIGN_IDENTITY` picks another identity, and `SIGN_IDENTITY=-` signs ad hoc and skips notarization.
- The script stops before notarizing when the signature has no team ID. A custom trust setting on the Developer ID certificate causes that, and `security dump-trust-settings` lists it.
- `scripts/release.sh --verify <tarball>` checks a built or downloaded tarball: arm64 only, no `/Users/` path in the binary, both signatures, Gatekeeper, the stapled ticket and `--version`.
- The Homebrew formula waits in `Packaging/Formula/deviceloop.rb`. Once the tap exists, copy it to `Formula/deviceloop.rb` there with the release URL and the sha256 that `scripts/release.sh` printed.

## Submitting Your Changes

1. Commit with a short imperative subject, for example `Add orientation rotate`.

2. Push to your fork and open a pull request against `main` with a clear title and description. Include what you ran and on which devices or simulators.

3. Respond to review feedback. A maintainer merges approved pull requests.

## Guidelines

- **Code style**: match the existing files. Every Swift file starts with the two-line license header. Use 4-space indentation with indented `switch` cases, descriptive names, and short `///` comments on public API that say what the code does. No banner comments.
- **Errors**: throw `DeviceLoopError` with the right code and a one-line fix.
- **Output**: `CommandResult.text` is compact. Its first line names the target, and it includes the paths of files it wrote.
- **Dependencies**: Apple frameworks and swift-argument-parser only. Do not add GPL or LGPL code, and do not use private Apple frameworks.
- **Tests**: add a Swift Testing test (`@Suite`, `@Test`) for each behavior you add or fix, one behavior per test, named for the behavior.
- **Docs**: update `README.md` and `docs/parity.md` when commands change, `skills/deviceloop/SKILL.md` when MCP tools change, and `CHANGELOG.md` for every change a user can see.
