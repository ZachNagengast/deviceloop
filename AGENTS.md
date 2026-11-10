# Instructions for coding agents

DeviceLoop is a Swift CLI and MCP server that drives iPhones, iPads and simulators through `xcrun devicectl`, `xcrun simctl`, an XCUITest runner and AVFoundation.

## Build and test

- Build: `xcrun swift build`, or `make build`.
- Test: `xcrun swift test`, or `make test`.
- Use `xcrun swift`, not `swift`. Another toolchain may come first on `PATH` and fail to build the dependencies.
- When several agents share a checkout, give each one its own build directory: `xcrun swift build --scratch-path .build/<name>`.
- Set `DEVICELOOP_HOME=$PWD/.build/deviceloop-home` so runner sessions, runs and artifacts stay in the repo. `make test` already does.
- Suites named `*LiveTests` need a booted simulator and run only when `DEVICELOOP_TEST_SIMULATOR` is set. See [Building and Testing](CONTRIBUTING.md#building-and-testing).
- After editing files under `Runner/`, run `deviceloop runner stop --device <udid>`. [The runner project](CONTRIBUTING.md#the-runner-project) says why.
- The smoke scripts and `make export-check` drive a real target. [scripts/README.md](scripts/README.md) says how to run them.

## Layout

- `Sources/DeviceLoopKit/Core`: shared types. `Target`, `DeviceLoopError`, `CommandResult`, `JSONValue`, `Shell`, `Paths`, `Redactor` and the version.
- `Sources/DeviceLoopKit/Devices`: the `devicectl`, `simctl` and `xcresulttool` wrappers, target selection and screenshots.
- `Sources/DeviceLoopKit/Commands`: one public function per command, used by both the CLI and the MCP server.
- `Sources/DeviceLoopKit/Runner`: building, starting and talking to the XCUITest runner. Build cache, session file, locks, HTTP client and UI tree.
- `Sources/DeviceLoopKit/Flows`: flow files. Parsing and validation, the engine behind `flow run` and `ui do`, and the XCTest exporter.
- `Sources/DeviceLoopKit/Runs`: run folders. Recorder, store, `report.html`, `run compare` with tree and screenshot diffs, and `run export`.
- `Sources/DeviceLoopKit/State`: device state snapshots, diffs and the change journal behind `state scope` and `state restore`.
- `Sources/DeviceLoopKit/Video`: screen recording, USB capture, animation analysis, contact sheets and xctrace tables.
- `Sources/DeviceLoopKit/MCP`: the stdio MCP server, its tools and the activity log.
- `Sources/deviceloop`: the ArgumentParser CLI.
- `Runner/Shared`: the runner wire protocol. SwiftPM builds it as the `DeviceLoopProtocol` module that the CLI imports, and the runner compiles it too.
- `Runner`: the rest is built by xcodebuild, not SwiftPM, from `Runner/project.yml`, the XcodeGen source of `DeviceLoopRunner.xcodeproj`. `Host` is the runner's host app with the test fixture screens, `UITests` the XCUITest runner, `Intents` the App Intents bridge framework the runner loads at run time, `SiriFixture` the test app for `siri test` scenarios, and `Configuration` the signing settings.
- `Tests/DeviceLoopKitTests`: Swift Testing suites with recorded `devicectl`, `xcresulttool`, `xctrace` and crash report output.
- `Tests/ExportCheck`: an Xcode project that runs the flows `flow export` wrote.
- `Examples`: sample flows, `Sample` for the demo and animation timing, and `SuiteFixture` for `test` and `perf`.
- `Packaging`: the capture helper's Info.plist and entitlements, and the Homebrew formula.
- `scripts`: smoke tests, the release script and `scripts/demo`, which records the demo video.
- `skills/deviceloop`: the agent skill.
- `docs`: design docs, including the `simctl` parity table and the validation evidence. [docs/README.md](docs/README.md) lists them.

## Rules

- Backends are Apple developer tools only: `devicectl` with `--json-output`, `simctl`, `xcodebuild`, `xcresulttool`, `xctrace` and public frameworks. No private frameworks.
- Prefer simulators. On physical devices run read-only commands only, unless the owner says the device is for testing.
- Follow the [CONTRIBUTING.md guidelines](CONTRIBUTING.md#guidelines) for style, errors, output and tests.
- Write ASCII only in code, comments, docs and commit messages. No em dashes, curly quotes or Unicode arrows, and no semicolons in prose.
- Do not add `Co-Authored-By` or "Generated with" attribution lines to commits or pull requests.
