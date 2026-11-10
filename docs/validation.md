# Validation

DeviceLoop is tested in three layers: host tests that need no device, smoke tests against a simulator, and checks on physical devices. Host tests do not run the on-device runner, and simulator results do not establish device behavior.

## Host tests

`make test` runs the Swift Testing suites in `Tests/DeviceLoopKitTests`. They cover the command layer without a device: target selection, the runner's operation store, refs and session files, the state journal, flows and their export, run journals and comparisons, redaction, perf scenarios and video analysis of synthetic recordings.

Suites named `*LiveTests` run against a booted simulator only when `DEVICELOOP_TEST_SIMULATOR` is set. `make runner` builds the runner for the simulator without signing, which checks that it compiles. [CONTRIBUTING.md](../CONTRIBUTING.md#building-and-testing) has the commands and the recorded tool output the tests parse.

## Simulator smoke tests

The scripts in `scripts/` drive a real runner on a simulator and save a `report.json` with every command or request, its output and each assertion. Most run the `deviceloop` binary against an exact UDID. `smoke-operations.py` instead reads a runner session file and sends HTTP requests to the runner itself. None of them picks, boots or erases a target. [scripts/README.md](../scripts/README.md) describes each one and the fixture identifiers.

- `smoke-runner.py`: the runner host's fixture screen. Counting, text entry and read-back, duplicate labels told apart by identifier, navigation, restart, stale refs, an alert, gestures, a switch row, an off-screen tap, rotation, the accessibility audit screens, and with `--location` the simulated location.
- `smoke-operations.py`: runner admission and receipts. Duplicate replay without a second input, conflicts, wrong epochs, a zero dispatch budget rejected as `bad_request`, busy rejection, receipts during a blocked wait, and a stale ref after a Siri request.
- `smoke-compare.py`: `run compare` on the same scenario recorded twice and once with a fixture variant.
- `smoke-siri.py`: `siri test` against the Siri fixture app, on a target where AppIntentsTesting loads.
- `export-check.py` (`make export-check`): runs the XCTest files `flow export` writes for `Examples/Flows`.

The fixtures are test infrastructure, not an SDK for apps under test: the runner host app's fixture screens (launch arguments `--deviceloop-fixture` and `--deviceloop-fixture-a11y`), the Siri fixture in `Runner/SiriFixture`, the Motion tab of `Examples/Sample` for animation timing, `Examples/SuiteFixture` for `test run` and `perf`, and `Tests/ExportCheck`.

## Device checks

Checks on physical devices run by hand with a person at the device, because the UI Automation passcode prompt, Trust, unlocking and Siri need one. They use the same scripts with a device UDID, and touch only DeviceLoop's own host app and fixtures unless a check says otherwise. They run only on devices whose owner has set them aside for testing.

Devices so far: an iPhone 15 Pro Max (iOS 27.0, later 27.2, 120 Hz display), an iPhone 13 Pro (iOS 18.7.8) and an iPad Air 11-inch with M2 (iPadOS 26.6.2).

## Results

### Oct 22nd, 2026, Xcode 27.1 (27A9275)

Runner protocol revision 3. [Simulator evidence](evidence/simulator-foundation-2026-10-22.json), [device evidence](evidence/devices-2026-10-22.json).

- An iPhone 15 Pro Max simulator on iOS 27.0 passed 13 fixture checks, 40 operation checks and 5 lifecycle checks on one CLI build.
- An iPhone 13 Pro on iOS 18.7.8 over USB and an iPad Air on iPadOS 26.6.2 over Wi-Fi passed the same checks and a receipt lookup through the CoreDevice tunnel on CLI build 4b79cd1a. An iPhone 15 Pro Max on iOS 27.0 passed all of them on CLI build 8597bc5f. On 4b79cd1a it passed the fixture, operation and receipt checks, then a restart waited on the passcode prompt nobody answered.
- The iPhones asked for the passcode to enable UI Automation at least once. Without it, startup failed with `ui_automation_passcode`.
- Siri requests held the runner as the [Siri](siri.md#how-a-request-runs) table shows for Xcode 27.1.

Animation, on the iPhone 15 Pro Max over USB at 60 fps, with a test app that moved a square for 800 ms ([evidence](evidence/animation-2026-10-22.json)):

- DeviceLoop measured 783 to 817 ms.
- A 100 ms main thread stall during a SwiftUI `withAnimation` move produced no candidate and the video stayed smooth, so that animation ran without the main thread. With the frame-driven route, which moves the square from the main thread every frame, every 100 ms stall showed as a 100 ms jump.
- A 200 ms stall was missed at first because long holes were skipped. After the analyzer fix, re-analysis reported 183 ms and four new runs reported 183 to 200 ms.
- Instruments Animation Hitches, attached during a 100 ms frame-driven stall, listed no hitch rows and showed a 116.7 ms gap in displayed surfaces where DeviceLoop reported its 100 ms jump. This suggests Instruments counts late frames and not frames the app did not produce.
- USB capture missed 2 to 13 frames per recording. A 16.7 ms delay at motion start appeared in 4 of 12 frame-driven recordings and is not attributed yet.

### Nov 8th, 2026, Xcode 27.2 (27B52)

Runner protocol revision 5.

- Host tests: 849 passed three times in a row on Nov 8th, 2026.
- Simulator: `smoke-runner.py` passed 51 checks with `--location`.
- Devices, on the Nov 8th, 2026 build: the iPad Air passed 39 checks, and the iPhone 13 Pro and iPhone 15 Pro Max (iOS 27.2) 37 each. The rotation check was skipped on both iPhones, because `devicectl device orientation set` returns success there and the orientation stays portrait.
- USB capture: with the 5 s wait between captures, 15 of 15 back-to-back recordings across the three devices succeeded, and 3 of 3 back-to-back captures on the iPhone 13 Pro ended with the exact fixture count.
- Run comparison, on an iOS 27.0 simulator: `smoke-compare.py` passed 3 of 3 times. Run A against itself compared `same` with the 59 pt status bar masked. Against the variant it found the 40 pt move of `Submit text`, the `Show detail` label and the slower slide, 265 to 283 ms against 667 to 683 ms. Across the passes, the animation of the same run differed by at most 16.6 ms and the latency by at most 7.2 ms, under the 50 ms floor. [Evidence](evidence/compare-simulator-2026-11-08.json).
- Accessibility audit, on an iOS 27.0 simulator: `ui audit` reported exactly one issue on each seeded element (`contrast`, `dynamicType`, `hitRegion`, `sufficientElementDescription`, `textClipped` and `trait`) and exited 7, and the clean screen reported none and exited 0, in three runs. `elementDetection` has no seeded fault.
- Siri, on an iOS 27.0 simulator: `siri say` was accepted in about 0.2 s. XCTest's call returned after 4.8 s, and 59 ms for a later request. With `--wait` the call took 4 to 91 ms over five requests, `--expect` reported `verified` true for a present element and false for a missing one, and a ref from before the request was rejected with `stale_ref`. [Evidence](evidence/simulator-siri-2026-11-08.json).
- `siri test`, on an iOS 27.0 simulator with UI verification and the fixture store written before each run: one matching task was `verified`, two were a `duplicate` and another title a `wrong_entity`. Each run took 6 to 7 s. These runs check the read-back and classification on a seeded store, not an effect of Siri.
- State, on the iPad Air: a capture was written with mode 0600, a diff against the live state showed no changes, a scope journaled an appearance and an orientation change, and restore set both back.
- Test jobs: a failing test through `--xctestrun` took 2.7 s with a 384 KB result bundle on an iOS 27.0 simulator, and 15.6 s with 57 MB with `--diagnostics`. On the iPad Air `--diagnostics` runs `devicectl diagnose`, which failed, and the run took 3.6 s with 392 KB. Ctrl-C cancelled a job on the iPad within 4 s. Over MCP on the simulator, `test_cancel` took 34.8 s to finish a job.
- Perf on the iPad Air: launch medians were 0.14 to 0.33 s, against 2.2 to 2.6 s on the simulator, and a 300 ms launch delay added about 0.33 s. CPU and memory metrics are process totals on the device as on the simulator. XCTest's hitch metric reported 0 hitches for 100 ms main thread stalls in a test app, and whether that is XCTest's definition or a miss is unknown. A scroll metric added a 55 fps frame rate and hitch sub-metrics, and Frame Count read 0.
- Timings on devices: the first device runner build took 14.6 s on the iPhone 13 Pro. A runner start 18 minutes after the last approval asked for no passcode and took 4.4 s on the iPhone 15 Pro Max, and a stop 0.7 s. A crash report appeared within about 1 s on iOS 18.7.8. `terminate` took about 0.9 s and `logs start` about 1.75 s.
- Hardware buttons on the iPhone 15 Pro Max: `home`, `volumeUp`, `volumeDown` and `action`. Volume on the home screen changes the ringer.

## Open questions

Nothing below has been measured yet. Each item is a gap in the evidence, not a known bug.

Runner and setup:

- Whether the 3 s gap DeviceLoop allows between `Running tests` and the ready line sends the passcode warning and notification on slow startups that show no prompt, and how macOS presents and attributes that notification.
- Whether a live runner keeps working after the device asks for the passcode again hours later. `automation.json` records the last start, not whether UI Automation is still enabled.
- The 75 s wait after `Running tests` was measured with Xcode 27.1 only. Whether a second xcodebuild right after a timed-out one shows a new prompt, and whether a phone that locks during the first prompt ends the retries, is unmeasured.
- Registering a new device through `-allowProvisioningDeviceRegistration`, the rebuild that adds a device to the profile, and the profile error texts (including `0xe8008015`) come from Xcode's documentation and forum reports, not a captured run.
- Whether a runner from a second checkout with other runner sources, installed on the same simulator, crashes the first checkout's runner at launch.

Pairing and disk images:

- Whether `devicectl manage pair` raises Trust and when it returns, and whether a pair request to a device seen only over the network starts wireless pairing.
- Whether `devicectl manage ddis update` needs sudo, what the host disk image check reads on a Mac with no iOS image, and which key reports an image the device rejects.
- Whether devicectl leaves out Developer Mode status for an unpaired or just-connected phone. Capability statuses for unpaired devices and devices with Developer Mode off come from devicectl's list, not a recording.

Screen and input:

- Whether screenshot point coordinates match `ui tap` in landscape, and whether point taps and the app frame check work in iPad landscape and in a Stage Manager window smaller than the screen.
- What a phone lying flat reports as its orientation, and whether picking it up makes refs stale.
- Whether XCTest applies drag velocity in pixels or points.
- Whether a simulator shows anything when the Action button is pressed.
- The placeholder check in `ui type --into` on OS versions that report the placeholder as the value, and the caret tap on a short iPhone such as the iPhone SE.
- Why a first `ui type --into` after `launch --restart` in a new runner session failed once.

Apps, files and settings:

- Why the fixture's marker and Logger lines were missing from `launch --console` output in four sessions.
- `location` set and clear on a device, and against a location set by an Xcode scheme.
- A byte-exact pasteboard round trip on a device. It was measured on a simulator only.
- Whether iOS 18 reports the accessibility keys of `devicectl device info appearance`.

Video and traces:

- On USB a hole with no frames counts as a recorder gap at any length, which could hide a real stall. Comparing recorder gaps with an Animation Hitches trace on a device would show it.
- Whether the first `marker` flash of the Motion tab in `Examples/Sample` reaches a device screen a frame late, as on the simulator, and how far the USB session clock is from the host clock.
- Whether the tap feedback limits, set from synthetic and simulator runs, hide an early stall in an ease-in move or shift the latency of one.
- Whether xctrace writes its device temporary files under the per-trace folder, how long table exports of long device traces take against the 120 s export timeout, and whether xctrace can attach to simulator system apps at all.
- Whether the trace ownership check accepts apps whose process name differs from their bundle folder, and whether an attached trace's hitch table lists other processes.
- For `video capture --instruments`: the error of the clock estimate, false gaps when the display mixes 60 and 120 Hz, an idle trace start, the 10 s trace margin on a device whose tunnel moves, and when xctrace reports that tracing started on a device.

Siri and App Intents:

- `siri say --wait` against the long hold on an iOS 27 iPhone, including a wait that runs out.
- Whether the runner's language values match Settings on a device, and whether they go stale until the runner restarts.
- The App Intents routes on a simulator that loads AppIntentsTesting, a `Double` parameter sent as a whole number, and an intent that does not return, which would hold the runner with no timeout.
- The entity-backed `siri test` acceptance on a device. The fixture's App Shortcut phrases carry no title yet.
- How long a real lock takes to report `passcodeRequired`, and whether a Require Passcode delay hides it.
- How the "Turn on '<app>' shortcuts with Siri?" dialog appears to XCTest, and whether the 10 s default settle time fits devices.

Tests and metrics:

- How test cases from a run with several destinations or configurations read, whether `--only-testing` selects a Swift Testing test, and how a device destination reads in `summary.json`.
- Whether Xcode 27.1's `xcresulttool` reads result schema 0.5.0.
- Whether the passcode hint of a device test job prints before the prompt and only when one shows. It printed on every device test and perf run on the iPad Air.
- Baselines in metric output and whether Xcode shows the sample or population standard deviation.
- On a device: launch metrics for an app other than the runner host, the hitch metric identifiers, a launch delay over three block pairs, and scroll metric identifiers with the final prefix.

Flows:

- Whether a flow that presses the Action button is refused before setup on a device without one.
- Whether reinstalling the runner's own host app in a flow keeps the runner reachable.
- Why a first tap right after activating a backgrounded app passed once with no effect, and a signal 11 seen once with no crash log.
- The exported flow check on a simulator after the latest exporter changes.

Release:

- Notarization and stapling have not run on a real build.
- The Homebrew formula has not been audited or installed, and whether the helper's camera grant survives `brew reinstall` and `brew upgrade` is unknown.
