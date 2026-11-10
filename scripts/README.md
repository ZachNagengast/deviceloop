# Smoke tests

These scripts check DeviceLoop against a booted simulator or a test device. They run only when you start them.

| Script | What it checks |
| --- | --- |
| [`smoke-runner.py`](#ui-fixture-smoke-test) | UI commands on the host fixture: refs, typing, alerts, gestures, rotation, location and `ui audit` |
| [`smoke-compare.py`](#run-comparison-smoke-test) | `run compare` finds a seeded move, label change and slower animation, and no change between two equal runs |
| [`smoke-operations.py`](#operation-admission-smoke-test) | The runner's operation receipts, replay and admission, over its HTTP API |
| [`smoke-siri.py`](#siri-scenario-smoke-test) | `siri test` outcomes against the Siri fixture |
| [`export-check.py`](#exported-flow-check) | The XCTest files that `flow export` writes, run with `xcodebuild test` |

`release.sh` builds the release tarball. [CONTRIBUTING.md](../CONTRIBUTING.md#releasing) describes it.

`demo` records the demo video. [Demo](#demo) describes it.

## Running them

Build DeviceLoop with `make build`. Every script except `smoke-operations.py` takes:

- `--binary`, the `deviceloop` executable to test, such as `"$PWD/.build/debug/deviceloop"`.
- `--device`, the exact UDID of the target. The scripts do not pick, boot or erase a target, and refuse a name, `booted` or `usb`.
- `--artifacts`, a directory that does not exist yet. The script creates it and writes `report.json` there after every command, so a rerun cannot overwrite earlier evidence.

Set `DEVICELOOP_HOME` first, as [Building and Testing](../CONTRIBUTING.md#building-and-testing) shows, to keep runner sessions and runs in the checkout.

The scripts start the runner when they need it, which builds it the first time, and leave it running for diagnosis. Stop it with `deviceloop runner stop --device <udid>`. No script retries input. A command that timed out has an unknown outcome, so look at the target before running the script again. `smoke-runner.py`, `smoke-compare.py` and `smoke-siri.py` give each command 120 seconds and the first runner start 720 seconds. `--timeout` and `--startup-timeout` change these, up to 1200 seconds.

### On a simulator

Boot the simulator and pass its UDID. `xcrun simctl list devices booted` lists booted simulators. The runner builds without signing, and the fixture host is `com.argmaxinc.deviceloop.host`.

```sh
xcrun simctl boot <udid>
python3 scripts/smoke-runner.py --binary "$PWD/.build/debug/deviceloop" --device <udid> --artifacts "$PWD/.build/smoke/runner-1"
```

### On a device

Run them only on a device that its owner set aside for testing, after `deviceloop prepare --device <udid>`. A device build appends the team to the bundle IDs, so the scripts read the host app from `deviceloop runner start` (`hostApp`), and `--app` overrides it.

- Physical iPhones accept `deviceloop orientation` but stay in portrait, so `smoke-runner.py` skips its rotation check there and records the reason as `rotationSkipped` in `report.json`.
- The video step of `smoke-compare.py` needs the device on USB.
- `export-check.py` runs on simulators only.

## The host fixture

The runner's host app reads these launch arguments. The first three show a disposable fixture screen, and relaunching the app resets its state. Without them the host shows its normal screen.

| Argument | Effect |
| --- | --- |
| `--deviceloop-fixture` | Shows the fixture screen |
| `--deviceloop-fixture-variant=b` | With `--deviceloop-fixture`, moves `Submit text` 40 pt right, renames `Open detail` to `Show detail` and slows the slide from 300 to 700 ms |
| `--deviceloop-fixture-a11y faults` or `clean` | Shows an accessibility audit screen |
| `--deviceloop-log <marker>` | Prints the marker to stdout and logs it with `Logger`, subsystem the host bundle ID, category `fixture` |
| `--deviceloop-write <name>` | Writes the marker, or the name when no marker is passed, to `Documents/<name>` in the app's data container |
| `--deviceloop-crash` | Traps with `fatalError` after the first frame |
| `-DeviceLoopLaunchDelayMs <ms>` | Sleeps this long before the first frame, a seeded launch regression for `perf launch` and `perf compare` |

`deviceloop launch` passes them after `--`, and `perf` takes each one with `--launch-arg`. Without `--restart`, a running host comes to the front and ignores the new arguments.

```sh
deviceloop launch <host bundle ID> --restart --device <udid> -- --deviceloop-fixture
deviceloop launch <host bundle ID> --console --restart --device <udid> -- --deviceloop-log M1
deviceloop perf launch <host bundle ID> --launch-arg -DeviceLoopLaunchDelayMs --launch-arg 300 --device <udid>
```

The fixture marks the time from the `Open detail` tap until the detail screen appears as the os_signpost interval `OpenDetail`, subsystem `com.argmaxinc.deviceloop.host`, category `fixture`. `perf run --metric signpost:com.argmaxinc.deviceloop.host/fixture/OpenDetail` measures it.

### Fixture screen

| Identifier | Meaning |
| --- | --- |
| `fixture.counter.increment` | `Increment` button |
| `fixture.counter.value` | `Count: N` |
| `fixture.text.input` | Text field with the placeholder `Test text`, autocorrection and capitalization off |
| `fixture.text.submit` | `Submit text`, which copies the field to the echo and dismisses the keyboard |
| `fixture.text.echo` | The submitted text, or `No text submitted` |
| `fixture.secure.input` | Secure field |
| `fixture.secure.length` | `Secret length: N` |
| `fixture.prefilled.input` | 300 pt wide monospaced field that starts as `abc` |
| `fixture.placeholder.input` | Empty field with a placeholder |
| `fixture.placeholder.deletes` | `Deletes: N`, delete key presses in that field, empty or not |
| `fixture.navigation.open` | `Open detail`, which opens the detail screen |
| `fixture.duplicate.first` | First `Choose` button |
| `fixture.duplicate.second` | Second `Choose` button |
| `fixture.duplicate.result` | `Choice: none`, `Choice: first` or `Choice: second` |

### Detail screen

These controls are on the detail screen so the fixture screen still fits above the software keyboard.

| Identifier | Meaning |
| --- | --- |
| `fixture.navigation.detail` | `Detail screen` |
| `fixture.navigation.back` | `Back to fixture` |
| `fixture.alert.open` | `Show alert`, which shows an app alert with `Keep Draft`, `Delete Draft` and `Ask Later` |
| `fixture.alert.result` | `Alert: none`, or the label of the button tapped |
| `fixture.location.request` | `Request location`, which asks for When In Use location access |
| `fixture.location.value` | `Location: <lat>,<lon>` with six decimals, or `Location: not requested`, `waiting`, `not authorized` or `unavailable` |
| `fixture.transition.toggle` | `Slide`, text with the button trait and no pressed highlight. A tap moves a 44 pt square 160 pt right in 300 ms, linearly, and the next tap moves it back |
| `fixture.gesture.pad` | `Gesture pad`, 200 by 140 points |
| `fixture.gesture.taps` | `Taps: N` |
| `fixture.gesture.doubletaps` | `Double taps: N` |
| `fixture.gesture.longpresses` | `Long presses: N` |
| `fixture.gesture.swipe` | `Swipe: none`, `left`, `right`, `up` or `down`, the direction of the last pan |
| `fixture.gesture.drag` | `Drag: none` or `Drag: dx,dy`, the last pan from touch-down to lift |
| `fixture.switch` | `Fixture switch` toggle, 280 points wide, off at launch |
| `fixture.offscreen` | `Off screen` button, 1000 points right of the switch, off the screen |

### Accessibility screens

`--deviceloop-fixture-a11y faults` seeds one audit type on each element. `--deviceloop-fixture-a11y clean` shows a screen with no issues. `elementDetection` has no seeded fault. [Validation](../docs/validation.md) has the audit results measured on a simulator.

| Identifier | Meaning | Audit type |
| --- | --- | --- |
| `fixture.a11y.screen` | Title, `Accessibility faults` or `Accessible screen` | none |
| `fixture.a11y.sufficientElementDescription` | Button whose only content is a drawn circle, with no label | `sufficientElementDescription` |
| `fixture.a11y.hitRegion` | Button with an 8 by 8 point hit area | `hitRegion` |
| `fixture.a11y.contrast` | Light gray text on white | `contrast` |
| `fixture.a11y.dynamicType` | Text in a fixed 15 point font | `dynamicType` |
| `fixture.a11y.textClipped` | One-line text in a 110 point frame that clips at larger text sizes | `textClipped` |
| `fixture.a11y.trait` | Button labeled `Save button`, which repeats its button trait | `trait` |
| `fixture.a11y.clean.text` | Body text on the clean screen | none |
| `fixture.a11y.clean.button` | Prominent `Continue` button on the clean screen | none |

## UI fixture smoke test

`smoke-runner.py` drives the host fixture. It changes nothing else on the target apart from the orientation and, with `--location`, the simulated location, which it clears.

```sh
python3 scripts/smoke-runner.py \
  --binary "$PWD/.build/debug/deviceloop" \
  --device <udid> \
  --artifacts "$PWD/.build/smoke/runner-1"
```

It runs `runner start` and turns the target to portrait, where the fixture screen fits above the keyboard. It launches the host once through `ui do` so XCTest installs it, then restarts it with `--deviceloop-fixture`. Then it checks, in order:

- Start: the counter reads `Count: 0`, the echo `No text submitted` and the choice `Choice: none`.
- Rotation: it turns the target to landscapeLeft. A tap on the `Increment` ref from the portrait tree fails with `stale_ref` naming the rotation, and the counter stays at 0. It then turns the target back and waits for the screen to settle. A target whose orientation does not change skips this check.
- Refs: a tap on the `Increment` ref adds exactly one. The same ref again fails with `stale_ref`, and so does a ref from a tree older than the latest one. The counter stays at `Count: 1`.
- Typing: `deviceloop fixture 42` typed into `fixture.text.input` reads back exactly, without the placeholder, and `Submit text` echoes it.
- Duplicate labels: the two `Choose` buttons are tapped by identifier, and each sets its own choice.
- Navigation: `Open detail` shows `Detail screen`, and `Back to fixture` returns with the counter intact.
- Restart: relaunching the fixture clears the counter, the submitted text and the choice.
- Alert, on the detail screen: `ui alert accept` and `ui alert dismiss` fail with `element_ambiguous` and list all three labels, because none is a label they know. `ui alert --button "Delete Draft"` taps that button.
- Gestures, on the detail screen: a tap, a double tap (`--count 2`) and an 800 ms hold each add one to their own counter and none to the others. A left swipe on the pad reads `Swipe: left`. A drag across the pad reads within 10 points of its translation. `ui do 'tap -5,10'` fails that step with `bad_arguments`, exits 1 and adds no tap.
- Switch, on the detail screen: a tap on `fixture.switch` by identifier turns its value to 1 and a tap on its ref turns it back to 0. Taps on `fixture.offscreen` by identifier and by ref fail with `element_not_hittable`.
- Secure text: typing into `fixture.secure.input` reports `textVerified: false` and no `readBack`, the text is not in the command's output, and `Secret length` matches it.
- Editing `fixture.prefilled.input`: `def` typed after `abc` reads back `abcdef`. `--clear` replaces the text, a short one and a sentence. A tap a quarter of the way into the field puts the caret mid-text, and `--clear` from there still empties the field.
- Empty field: a delete in `fixture.placeholder.input` counts `Deletes: 1`. `--clear` in the empty field sends no delete, and the typed text reads back.
- Location, only with `--location`. See [Location check](#location-check).
- Audit: on the faults screen `ui audit` exits 7 and reports each seeded type on its `fixture.a11y.<type>` element. Below iOS 26 it does not check `trait`, which XCTest's audit can miss there, and records that as `auditSkipped`. On the clean screen `ui audit` exits 0 with no issues.

When every check passes it saves `fixture-final.png`. `report.json` holds the binary path and SHA256, the device, each command with its arguments, output, exit status and elapsed time, and each check with the expected and observed values.

Cleanup turns the target back to portraitUpsideDown, landscapeLeft or landscapeRight when it started in one of them, relaunches the host app with no launch arguments so it shows its idle screen, and presses Home. A failed relaunch is recorded as `cleanupRelaunchError`. It does not stop the Home press or change the exit status. It runs after a pass, a failure or Ctrl-C, and `report.json` records it as `cleanupOutcome`, separate from `testOutcome`. A completed Home request does not prove the Home screen is showing. The script exits 0 when the checks pass and cleanup completed, 1 when a check or cleanup fails, 130 after Ctrl-C, and 2 when it cannot start.

Checks read the accessibility tree: exact labels, exactly one element per identifier, and a frame at least partly inside the app's frame. They do not prove that pixels are visible or that nothing covers an element. It is a smoke test, not a reliability benchmark.

### Location check

`--location` needs location access for the host app before the run. On a simulator, grant it with `xcrun simctl privacy <udid> grant location <host app>` and remove it afterwards with `xcrun simctl privacy <udid> reset location <host app>`. On a device, open the detail screen, tap `Request location` and allow it.

The check records the fixture's reading before the run as `locationBefore`. It runs `deviceloop location 37.3349,-122.0090` and waits up to 15 seconds for a reading within 0.001 degrees of it. It then runs `deviceloop location clear`, relaunches the fixture, because a running app keeps its last fix after clear, and expects `Location: unavailable` or coordinates away from that point. The simulated location stays cleared. DeviceLoop cannot read a simulated location, so it cannot put back one that was set before the run.

### Permission alert check by hand

The smoke test does not answer a system permission alert, because a device cannot reset a granted permission without reinstalling the app. On a simulator with the runner started:

```sh
xcrun simctl privacy <udid> reset location <host app>
deviceloop launch <host app> --restart --device <udid> -- --deviceloop-fixture
deviceloop ui tap id=fixture.navigation.open --app <host app> --device <udid>
deviceloop ui tap id=fixture.location.request --app <host app> --device <udid>
deviceloop ui alert --device <udid>
deviceloop ui alert accept --device <udid>
deviceloop ui alert --device <udid>
xcrun simctl privacy <udid> reset location <host app>
```

The first `ui alert` lists `Allow Once`, `Allow While Using App` and `Don't Allow`. `ui alert accept` taps `Allow While Using App`, the only accept label it knows on that alert, and prints `tapped "Allow While Using App"`. The last `ui alert` prints `no alert`.

## Run comparison smoke test

`smoke-compare.py` records the same fixture scenario as run A, run A again and run B, then compares A with each through `deviceloop run compare`. Run B adds `--deviceloop-fixture-variant=b`.

```sh
python3 scripts/smoke-compare.py \
  --binary "$PWD/.build/debug/deviceloop" \
  --device <udid> \
  --artifacts "$PWD/.build/smoke/compare-1"
```

Each run is `run start`, `launch <host> --restart` with the fixture arguments, `ui tree`, `screenshot`, `ui tap id=fixture.navigation.open`, `video capture --do 'tap id=fixture.transition.toggle' --keep-video` and `run stop`. Both comparisons mask the status bar, which is the screen above the fixture's navigation bar. The test passes when A against A is `same`, and A against B is `different` with the frame of `fixture.text.submit` moved by 40,0,0,0, the label of `fixture.navigation.open` changed and the animation of the capture step longer by more than the timing floor. Each of these three findings records its step, the event of each run and the files both runs kept for that step, and fails when a file is missing.

`report.json` holds the run and comparison IDs, the mask, every command with its output, and the checks. The runs and comparisons stay under `$DEVICELOOP_HOME/runs`, with `comparison.html` in each comparison folder. Each run is a single recording, so its timings are uncalibrated visual estimates. Cleanup and the exit statuses are those of `smoke-runner.py`.

## Operation admission smoke test

`smoke-operations.py` sends requests straight to a running runner, with the address and token from its session file, against the fixture already in front. It does not print the token, launch an app, select a device or retry uncertain input. Start the runner and the fixture first:

```sh
app=$(deviceloop runner status --device <udid> --json | plutil -extract hostApp raw -o - -)
deviceloop launch "$app" --restart --device <udid> -- --deviceloop-fixture
```

```sh
python3 scripts/smoke-operations.py \
  --session-file "${DEVICELOOP_HOME:-$HOME/Library/Caches/deviceloop}/sessions/<udid>/session.json" \
  --artifacts "$PWD/.build/smoke/operations-1"
```

It reads the host app from the session's xctestrun, and `--app` overrides it. It increments only the fixture counter and checks that:

- Health reports a UUID session epoch and an idle runner.
- A repeated request with the same operation ID returns the first response and increments once.
- The same ID with a different body is `operation_conflict`, a missing or wrong epoch is `session_mismatch`, and a zero dispatch budget is `bad_request`. None of them change the counter.
- While a 2.5 second wait for a missing element holds the runner, a competing tap is `busy` at once instead of queuing, the same wait ID is `operation_in_progress`, and health and the receipt still answer, the receipt as `running`.
- The wait ends with `timeout`, its receipt keeps that response, and replaying the wait returns it without waiting again.
- An unknown receipt ID is `receipt_unknown`.
- A malformed Siri request is `bad_request` before it is accepted.
- A screenshot too large for the receipt store replays as `result_not_retained`.
- A Siri request, "what time is it", is accepted with its receipt, the receipt stays readable and finishes within 180 seconds, and a ref from a tree taken before the request is then `stale_ref`.

The evidence directory holds `requests.jsonl`, each request and response with the token redacted, and `report.json` with every assertion. The script exits 0 when every check passes, 1 when one fails and 130 after Ctrl-C. It leaves the runner running.

## Siri scenario smoke test

`smoke-siri.py` runs `deviceloop siri test` against the Siri fixture. It needs the fixture installed, App Intents testing on the target, and a phrase that makes Siri add one fixture task with a known title. The fixture's App Shortcut phrases carry no title yet. The first request for the fixture's shortcut asks "Turn on 'deviceloop fixture' shortcuts with Siri?", so tap Turn On once before the run.

```sh
python3 scripts/smoke-siri.py \
  --binary "$PWD/.build/debug/deviceloop" \
  --device <udid> \
  --artifacts "$PWD/.build/smoke/siri-1" \
  --phrase "<phrase that adds a fixture task>" \
  --title "<title of the task it adds>"
```

It sends the phrase in three scenarios and checks that it is `verified` when the title is expected, `duplicate` after a seeded task with the same title, and `wrong_entity` when another title is expected. Each scenario must read entities through App Intents and run the reset intent in cleanup. The restarted fixture must then show no task. Each scenario, its report and its screenshots are saved in the artifacts directory, next to `report.json`. Scenarios time out after 600 seconds, and `--scenario-timeout` changes that. Cleanup and exit statuses are those of `smoke-runner.py`.

### The Siri fixture

`DeviceLoopSiriFixture` in `Runner/DeviceLoopRunner.xcodeproj` is a task list app named "deviceloop fixture". Its bundle ID is `com.argmaxinc.deviceloop.siri-fixture`, followed by the signing team on a device. `smoke-siri.py` derives it from the runner's host app, and `--app` overrides it.

- `AddFixtureTaskIntent`, "Add Fixture Task", adds a task with its String parameter `title`.
- `ResetFixtureTasksIntent` removes every task. Shortcuts and Siri do not show it.
- `FixtureTaskEntity` has `id` and `title`. Its query matches a case-insensitive part of the title.
- The App Shortcut phrases are "Add a task in deviceloop fixture" and "Add a fixture task in deviceloop fixture".
- Tasks are stored in `Library/Application Support/fixture-tasks.json` in the app's data container. The `Fixture Tasks` list shows each one with the identifier `siri.fixture.task.<position from 1>`, and `No tasks` when there are none.

`deviceloop runner start` does not build or install the fixture. Build it with `clean build`, because with Xcode 27.2 an incremental build after a source change drops the `nlu` and `root.ssu.yaml` phrase files from `Metadata.appintents`. On a simulator:

```sh
xcodebuild clean build \
  -project Runner/DeviceLoopRunner.xcodeproj \
  -scheme DeviceLoopSiriFixture \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/siri-fixture \
  CODE_SIGNING_ALLOWED=NO
deviceloop install .build/siri-fixture/Build/Products/Debug-iphonesimulator/DeviceLoopSiriFixture.app --device <udid>
```

For a device, replace the destination and `CODE_SIGNING_ALLOWED=NO` with `-destination id=<udid> -allowProvisioningUpdates DEVELOPMENT_TEAM=<team ID>`, and install `Debug-iphoneos/DeviceLoopSiriFixture.app`. Remove the fixture with `deviceloop uninstall <fixture bundle ID> --device <udid>`.

## Exported flow check

`export-check.py` runs the XCTest files that `deviceloop flow export` writes for `Examples/Flows/fixture.json` and `fixture-fail.json`. `Tests/ExportCheck/ExportCheck.xcodeproj` builds the runner host sources as a separate app, `com.argmaxinc.deviceloop.exportcheck`, and a UI test target with both files. It lives outside `Runner/`, so it does not change the runner's build cache key. The fixture test must pass, and the fixture-fail test must fail at its `Count: 2` assert with `XCTAssertEqual failed: ("Count: 1") is not equal to ("Count: 2")`.

```sh
make export-check DEVICE=<udid> ARTIFACTS="$PWD/.build/smoke/export-1"
```

The script needs the exact UDID of a booted simulator. It does not boot or erase a simulator. It refuses when `deviceloop runner status` reports a runner on that simulator, because both run XCUITest there. Stop it first with `deviceloop runner stop --device <udid>`. The script runs `xcodebuild test` without signing, with derived data in `.build/export-check`, and writes `export.xcresult`, `xcodebuild.log` and `report.json` to the new directory. `report.json` lists each command and the test results that `xcrun xcresulttool` reads from the result bundle.

xcodebuild runs in its own process group with a 1200 second timeout. Ctrl-C or the timeout sends it SIGINT so it can finish `export.xcresult`, and a second Ctrl-C or 60 seconds later kills it. The step in `report.json` records the outcome (`interrupted` or `timeout`), whether it was killed, and the exit status. The script exits 0 when both tests end as expected, 1 when they do not, 2 when it refuses to run and 130 after Ctrl-C. The ExportCheck app and its test runner stay installed on the simulator.

The check runs only the step kinds in the two fixture flows: assert by label or hittable, tap, type into, launch, screenshot, and press home in cleanup. The other exported kinds are only compiled.

`FlowExportTests` compares both files to the exporter's output. After a change to the exporter, delete the two files and export them again:

```sh
deviceloop flow export Examples/Flows/fixture.json -o Tests/ExportCheck/UITests/FixtureFlowTests.swift --app com.argmaxinc.deviceloop.exportcheck
deviceloop flow export Examples/Flows/fixture-fail.json -o Tests/ExportCheck/UITests/FixtureFailFlowTests.swift --app com.argmaxinc.deviceloop.exportcheck
```

Run `xcodegen generate` in `Tests/ExportCheck` after adding or removing files there.

## Demo

`demo` records a video of a terminal running DeviceLoop commands next to the target's screen.

- `demo.json` lists the steps: chapter titles, captions, commands and pauses.
- `record.py` runs the steps on one target while it records the screen, and writes `timeline.json` with each command's output. It replaces device names, UDIDs, times and the home directory in the output.
- `agent.py` runs `claude -p` with only DeviceLoop's MCP tools and prints each tool call. The last step runs it.
- `render.swift` draws the timeline and the screen recording into one MP4.

It needs the `claude` CLI and a booted simulator with [Examples/Sample](../Examples/Sample) installed. The agent step names the iPhone 17 Pro simulator. Run it from the repo root.

The `video inspect` step reads `.build/demo/assets/sample-stall.mp4`. Record that clip first:

```sh
mkdir -p .build/demo/assets
deviceloop video record -o .build/demo/assets/sample-stall.mp4 --duration-ms 4000 --device <udid> &
sleep 2
deviceloop open 'deviceloop-sample://move?driver=frames&stall=150' --device <udid>
wait
```

`deviceloop video inspect .build/demo/assets/sample-stall.mp4 --no-sheet` should report one jump of about 150 ms. A simulator recording misses the stall now and then, in one of three runs on Nov 9th, 2026, so record again when it reports none.

Then record the demo and render it:

```sh
python3 scripts/demo/record.py --binary "$PWD/.build/debug/deviceloop" --device <udid> --script scripts/demo/demo.json --out .build/demo
xcrun swift scripts/demo/render.swift .build/demo/timeline.json .build/demo/demo.mp4
```
