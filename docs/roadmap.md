# Roadmap

Planned work, in no fixed order. Nothing on this page is in the current build. [Parity](parity.md) lists the planned simctl and Xcode features one row each, and [validation](validation.md#open-questions) lists what is not measured yet.

## Distribution

- The Homebrew tap, `argmaxinc/homebrew-tap`, is not published yet. Until it is, build from source as the [README](../README.md#install) describes.
- The release tarball copies `Runner` and `skills` as they are on disk, and its bytes are not reproducible.

## Remote devices

Phones attached to a Mac you own, driven from another machine:

- An authenticated connection to the Mac, such as SSH with a pinned host key. Credentials stay in the SSH agent or the keychain and out of logs and run exports.
- An inventory whose device IDs name the host, so they do not collide with local ones.
- Exclusive reservations with an expiry and a fencing generation, so a client whose reservation expired cannot send input to a device someone else now holds.
- Release that stops new work, finishes the artifacts and keeps a device out of the pool while an action's outcome is unknown. Release does not erase user data.
- Remote test jobs, so a Linux or Windows machine can start `test run` on the Mac, poll it and fetch the result bundle. xcodebuild still runs on the Mac.

The runner's port stays private to the Mac. A hosted device cloud comes only through its documented API, after a real integration test.

## Runner and operations

- Receipts that survive a runner restart, and cancellation of work the runner already admitted.
- A verified outcome for every action. Today an action that returns was executed, and it is verified only where DeviceLoop checks a result: `install`, `uninstall`, `terminate`, `orientation`, `ui type --into`, `siri say --expect`, `lock` and flow asserts.
- Receipt, timing and XCTest warnings on flow steps that passed.
- `enabled` in the runner's find results, so an `enabled` assert takes one request.
- Reusing a runner after the device tunnel moves. The runner listens on the tunnel address it was launched with, so DeviceLoop starts a new runner instead.
- Keeping a runner rebuild for one device from rewriting products another device is launching from.

## Devices and settings

- Setters for text size, contrast and VoiceOver, which `state` already reads.
- Hardware buttons in `info`, which reports them as unknown although the runner can read them.
- The color filter type in `state`.
- Recovery from a journal line torn by a crash, one of the [device state limits](device-state.md#limits).
- Booting a shut-down simulator in `prepare`.
- Comparing the Mac's developer disk image build with the one the device mounted.
- A wait limit for the `device_prepare` tool based on a measured client timeout, in place of 120 s.
- Fold posture, once Apple's tools have a documented control for it.
- Thermal and network conditions. `devicectl device simulate` offers biometrics, location and the status bar only, and Xcode exposes device conditions in its interface, not on the command line. Each condition profile would say whether it is automatic, assisted through Xcode or an app-level mock, and set the previous condition back.

## Siri and App Intents

- A command and MCP tool that run an App Intent or an entity query directly.
- MCP tools for `siri test` and `perf`, as background jobs like `test_run`.
- App Shortcut phrases with a title in the Siri fixture, so the entity path of `siri test` has an acceptance run.
- Detecting the "Turn on '<app>' shortcuts with Siri?" dialog in `siri test`.
- A timeout on intent runs and entity queries, which today can hold the runner.
- A passcode hint for test and perf jobs that reaches MCP clients and notifications. It needs a signal that a prompt is on screen first.

## Flows

- Steps for Siri, location, appearance, orientation and audits, and resuming from a checkpoint.
- A finished-step count in flow progress and the run ID in the result.
- Faster exported asserts, which take about 2.2 s each on a simulator.

## Runs and comparison

- Keeping the step error when stopping a recording also fails.
- Keeping `run prune --keep 0` from removing a run that is still being created.
- Smaller report thumbnails, which are full-size images today, and a check of file hashes in the report.
- Links to artifacts in the finished event of a failed command.
- Hittable changes in `run compare`.
- Faster screenshot diffs, which took 3.75 s per pair in a debug build and keep their images in memory.
- A faster token check in `run export` for large videos.
- Whole-word matching for hidden typed text, which today also hides matching parts of other values.
- Shared types and a schema key for `perf compare` and `run compare`.

## Apps and logs

- Live tests for `logs`.
- Matching a crash report to the launched process on devices.
- A faster existence check for `container push` on devices, which lists the whole container.
- Device unified logs. `logs start --system` works on simulators only.
