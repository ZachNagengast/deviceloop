# DeviceLoop reference

Everything the [README](../README.md) leaves out: device setup, every command and MCP tool, animation analysis, limits on real devices, doctor's checks, the files DeviceLoop writes, upgrading and uninstalling.

- [Requirements and device setup](#requirements-and-device-setup)
- [Quick start](#quick-start)
- [Use with agents](#use-with-agents)
- [Commands](#commands)
- [Animation debugging with video](#animation-debugging-with-video)
- [Limits on real devices](#limits-on-real-devices)
- [Troubleshooting with doctor](#troubleshooting-with-doctor)
- [Privacy and data on disk](#privacy-and-data-on-disk)
- [Upgrade and uninstall](#upgrade-and-uninstall)

## Requirements and device setup

A simulator needs no setup. Boot it first, for example with `xcrun simctl bootstatus <udid> -b`.

A device needs:

- iOS or iPadOS 17 or later. The runner builds for iOS 17, and the oldest version tested is iOS 18.7.8.
- An Apple developer account signed in to Xcode under Settings > Accounts. DeviceLoop signs its UI runner with that team, and the first runner build for a device registers the device with the team. A free personal team has not been tested.
- A signing team stored with `deviceloop setup`. It picks the team signed in to Xcode, or the one you pass with `--team <ID>`, saves it in `config.json`, prints the MCP registration command for each agent it finds (`--yes` runs them, see [Register the MCP server](#register-the-mcp-server)) and runs `doctor`. `--dry-run` changes nothing.
- Pairing. Connect the device with a cable, unlock it, tap Trust and enter the passcode.
- Developer Mode. On the device open Settings > Privacy & Security > Developer Mode, turn it on, restart and confirm. If the switch is missing, run any Xcode build to the device once.
- A USB cable for screen video.

The first UI command on a device builds and launches the runner, and the device asks for its passcode to enable UI Automation. Unlock it and enter the passcode. XCTest gives up after 60 s if nobody answers, and DeviceLoop does not bypass the prompt. A device with no passcode does not prompt. A device can ask again after some hours. While the runner waits for a person, DeviceLoop posts one macOS notification with a sound per command. Set `DEVICELOOP_NOTIFY=0` to turn it off. Simulators do not notify.

`deviceloop prepare --device <udid>` walks through these steps in order and stops at the first one that is not done:

- `pair`, `developerMode` and `unlock` are owner steps. DeviceLoop prints what to do on the device and waits up to `--wait` seconds for each (default 300). `--pair` also sends `xcrun devicectl manage pair` to a device that is not paired, once per run. After Don't Trust, reconnect the cable and run prepare again.
- `mountDDI` mounts the developer disk image, `signingTeam` stores the team as `setup` does, and `uiAutomation` starts the runner. When nobody enters the passcode in time, prepare starts the runner again until `--wait-for-owner` seconds have passed (default 180).
- Without `--all`, prepare acts on one target: the one `--device` or `DEVICELOOP_DEVICE` names, or the only ready one. `--all` prepares every device and booted simulator at the same time, so one visit answers every device. `--dry-run` runs doctor's read-only checks, prints the plan and changes nothing.
- prepare exits 1 when a target is not ready. It does not unpair, clean disk images, reset settings, change a passcode or boot a simulator.
- When devicectl cannot read the lock state, for example over the network, prepare plans no unlock step. Unlock the device before the runner step starts.
- While prepare restarts the runner after a passcode timeout, other commands on that device wait for it, and `runner status` fails with `device_busy` after 120 s.

Use a test device when you can. A phone that is also someone's daily phone has their apps, data and notifications on screen, and screenshots and videos capture all of it.

## Quick start

```bash
deviceloop devices --all
xcrun simctl bootstatus <udid> -b
export DEVICELOOP_DEVICE=<udid>
deviceloop screenshot
deviceloop launch com.apple.Preferences
deviceloop ui tree
deviceloop ui tap General
deviceloop video capture --do 'tap About'
```

`devices --all` lists every device and simulator with its UDID, ready ones first. `xcrun simctl bootstatus <udid> -b` boots the simulator if it is shut down and waits until it is ready. `screenshot` saves a full-resolution PNG and prints its path. `ui tree` lists the elements on screen with a ref on each. `video capture` records around one step and reports how the screen moved. Files go to `~/Library/Caches/deviceloop/artifacts`, or to `$DEVICELOOP_HOME/artifacts` when `DEVICELOOP_HOME` is set. While a [run](#runs-and-comparisons) records on the target, they go to that run's `artifacts/` folder.

`--device` takes a UDID, a name or a unique part of it, `booted` for the booted simulator, `usb` for the device connected with a cable, or `device` for any connected device, wired or over the network. `booted`, `usb` and `device` work when exactly one target matches. When several match, the command fails with `device_ambiguous` and lists the candidates, so pass a name or UDID. When none matches, it fails with `device_not_found`. `DEVICELOOP_DEVICE` sets a default. `devices` names the target it picks and gives its UDID as `defaultDevice` in `--json`, and the MCP server names it in its instructions. When exactly one device or simulator is ready, `--device` can be left out. A connected device counts as ready, so with one phone connected and no simulator booted, a command without `--device` acts on the phone.

On a device, run `deviceloop setup` and `deviceloop prepare --device <udid>` first. [Requirements and device setup](#requirements-and-device-setup) describes both.

[Examples/Sample](../Examples/Sample) is a small app to try these commands on: a list of palettes with detail pages, a sign-in form, a Motion tab and a page of accessibility issues for `ui audit`. Open it in Xcode, pick your team in Signing & Capabilities and run it.

## Use with agents

### Register the MCP server

`deviceloop mcp` serves MCP over stdio. `deviceloop setup` prints the registration command for Claude Code, Codex, Cursor and Gemini CLI when it finds them. `--yes` runs those commands and `--no-agents` skips them. Register the absolute path to the binary. Agents started from the Dock often do not get your shell's `PATH`.

Claude Code:

```bash
claude mcp add -s user deviceloop -- ~/.local/bin/deviceloop mcp
```

Codex:

```bash
codex mcp add deviceloop -- ~/.local/bin/deviceloop mcp
```

Codex stops a tool call after 60 s by default. `flow_run`, `flow_status`, `flow_cancel`, `test_run` and `test_status` return within 45 s by default and hand back a job to poll. `trace_record` takes its `duration_ms` plus about 10 to 15 s, `device_prepare` can wait minutes for the passcode, and `video_record` `stop` analyzes the whole recording. For those, add `tool_timeout_sec = 300` to the `[mcp_servers.deviceloop]` table that `codex mcp add` wrote to `~/.codex/config.toml`.

### The skill

[`skills/deviceloop/SKILL.md`](../skills/deviceloop/SKILL.md) tells an agent how to pick a device, the screenshot, act and verify loop, and what to do for each error code. For Claude Code, copy it to `~/.claude/skills/deviceloop/`:

```bash
mkdir -p ~/.claude/skills/deviceloop
cp skills/deviceloop/SKILL.md ~/.claude/skills/deviceloop/
```

Once the Homebrew tap is published, a Homebrew install has it in `$(brew --prefix deviceloop)/share/deviceloop/skills/deviceloop`.

### MCP tools

Tools take `device` the way commands take `--device`. Results of tools that act on one target start with a line that names it, and errors start with `ERROR <code>`. The UI tools read `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&#34;`, `&#39;`, `&#x27;` and `&apos;` in `element`, `into`, `on`, `label`, `label_contains` and the `ui_alert` `answer` as the characters they stand for. The first `ui_*` call on a target starts the UI runner, which can take a minute on a device.

Devices and setup:

- `device_list` lists the ready iPhones, iPads and simulators. `all` adds shut-down simulators, unavailable devices and other platforms, ready ones first.
- `device_info` reports model, OS, connection, lock state, screen and each capability with its status and reason.
- `device_doctor` runs the `doctor` checks with one fix line per problem.
- `device_prepare` runs `prepare`, waiting up to `wait` seconds (0 to 120) for each owner step, and makes one runner start attempt.
- `device_view` opens the live screen in Device Hub on the Mac.

Screen and UI:

- `screen_capture` takes a screenshot at point size, so image pixels are screen points, and saves the full-resolution PNG.
- `ui_tree` lists the elements on screen with a ref on each line, up to `max_rows` (default 200).
- `ui_tap` taps, double taps or long presses a point, a ref or an element.
- `ui_type` types text, and with `into` reports `textVerified`.
- `ui_swipe` swipes on the app or on one element.
- `ui_drag` presses, drags in a straight line and releases.
- `ui_press` presses a hardware button the target has.
- `ui_find` finds elements by label, identifier or type.
- `ui_wait` waits until an element exists, is gone, hittable or enabled, or until the screen is stable.
- `ui_alert` reads the current alert or taps one of its buttons.
- `ui_audit` runs XCTest's accessibility audit on the screen in front.
- `runner_status` reports whether the UI runner is running, its uptime and whether it is busy.
- `runner_stop` stops the UI runner. The next `ui_*` call starts it again.
- `device_operation` reads a runner receipt without sending input.

Apps, logs and files:

- `app_list` lists installed apps, only those whose name or bundle ID contains `name` when it is given, or running apps with pids, and the foreground app when a UI runner is already running (otherwise `foreground: unknown` with the reason).
- `app_install` installs an `.app` or `.ipa` and checks the installed version and build.
- `app_uninstall` uninstalls an app and deletes its data.
- `app_launch` launches an app with optional arguments and environment, and reports whether it launched, relaunched or was already running.
- `app_terminate` stops a running app.
- `url_open` opens a URL or deep link and names the app that handled it.
- `app_logs` captures an app's stdout, stderr and os_log, or a simulator's unified log, in the background.
- `app_files` lists, pulls and pushes files in an app's data container.
- `crash_list` lists crash reports, newest first.
- `crash_pull` copies one crash report to the Mac.

State and settings:

- `device_set` sets the simulated location, appearance or orientation.
- `pasteboard` copies text to the pasteboard or reads it.
- `device_state` inspects, captures and diffs identity and settings.
- `state_scope` starts or reports a scope that journals setting changes.
- `state_restore` sets the journaled changes back and closes the scope.

Video and traces:

- `video_capture` records around one step and reports latency, motion and visual gap candidates with a contact sheet.
- `video_record` starts a background recording, then stops and analyzes it.
- `video_inspect` analyzes an MP4 or MOV on the Mac.
- `trace_record` records an Instruments trace of one running app.

Flows, runs and tests:

- `flow_validate` checks a flow without a device and lists what it needs.
- `flow_run` runs a flow, from a file or inline, and returns the result or a `run_id`.
- `flow_status` waits for a running flow and returns its result.
- `flow_cancel` stops a flow before its next step and runs cleanup.
- `flow_export` writes a flow as a new XCTest UI test file.
- `run` records the calls on a device into a run folder, and reports, lists, compares and exports runs.
- `test_run` runs XCTest and Swift Testing suites with xcodebuild as a job.
- `test_status` waits for a test job and returns its summary.
- `test_cancel` cancels a test job this server started.

Siri and system controls:

- `device_lock` locks the screen through Siri.
- `system_control` toggles Wi-Fi, Bluetooth, Low Power Mode, Do Not Disturb or Airplane Mode, or sets brightness or volume.
- `device_siri` says anything to Siri.

`setup`, `doctor --export`, `runner start`, `ui do`, `video record`, `launch --console`, `keep-awake`, `siri test`, `test results`, `perf` and `run prune` have no MCP tool. `device_siri` takes only `text`, so it has no `--wait` or `--expect`.

While a test job runs, SIGINT or SIGTERM to `deviceloop mcp` cancels the job instead of stopping the server. When stdin closes, the server cancels running flows and waits for its flows and test jobs to write their results before it exits.

### Activity log

Every MCP tool call appends one JSON line to `$DEVICELOOP_HOME/logs/mcp.jsonl` with `time`, `tool`, `device`, `deviceName`, `arguments`, `result` and `durationMs`. `result` is `ok`, the error code, `failed` for a failed result such as a failed flow, or `cancelled`. The `text` of `ui_type`, `pasteboard` and `device_siri`, and typed text in a `video_capture` step or an inline flow, is logged as its length. Environment variables are logged as their keys. At 10 MB the file moves to `mcp.jsonl.1`, replacing the previous one. The log stays on the Mac and has no viewer command.

## Commands

Every command except `mcp` takes `--json`, and commands that act on a target take `--device`. Their results start with a line that names the target. `deviceloop help <command>` lists every option. `deviceloop --generate-completion-script zsh` prints a completion script, and `bash` and `fish` work the same way. For zsh, save it as `_deviceloop` in a folder on `fpath`.

Errors print `ERROR <code>: <message>` to stderr with `Fix:`, `Try:`, `Detail:` and `Receipt:` lines, and `(needs user)` after the code when only the person at the device or Mac can fix it. With `--json` an error prints `{"ok": false, "error": {...}}` to stdout, with `code`, `message`, `actor` and `retryable`, and `fix` when there is one. [SKILL.md](../skills/deviceloop/SKILL.md#errors) explains each code.

Exit codes: 0 success, 1 failure, 2 bad arguments or no matching target, 3 needs the user to act, 4 device or runner unavailable, 5 timeout, 6 not supported on this target, 7 `ui audit` found issues or `state restore` left changes (`cleanup_incomplete`), 8 a `siri test` phrase was not verified or not sent, 130 interrupted with Ctrl-C. `video record`, `launch --console`, `keep-awake` and `trace record` take Ctrl-C as their normal end and exit 0. An unknown command or option, a missing argument or a bad value is a `bad_arguments` error and exits 2. Its `Detail:` line has the command's usage, and its fix names the closest command or option for a typo, or the `deviceloop help` page to read. `deviceloop help` with an unknown command fails with `bad_arguments` too.

`deviceloop --help` groups the commands by task and lists the first commands to run and the environment variables DeviceLoop reads. Durations are in seconds, except options ending in `-ms`, which take milliseconds, and `run prune --older-than`, which takes days.

Some simulator features have no device equivalent in Apple's tools, for example status bar overrides and erase. A command the target cannot run fails with `unsupported_on_target` and names the missing capability. [docs/parity.md](parity.md) maps every `simctl` command to its device path.

### Devices and setup

| Command | What it does |
|---|---|
| `deviceloop setup [--team <ID>] [--yes] [--dry-run] [--no-agents]` | Stores the signing team, prints the MCP registration for each agent (`--yes` runs it), runs `doctor` |
| `deviceloop doctor [--export <dir>] [--include-runner-logs]` | Checks Xcode, signing and the target `--device` or `DEVICELOOP_DEVICE` names, or every target without either, with one fix per problem |
| `deviceloop prepare [--all] [--pair] [--wait <s>] [--wait-for-owner <s>] [--dry-run]` | Gets a device ready for UI commands |
| `deviceloop devices [--all]` | Lists devices and simulators |
| `deviceloop info` | Shows model, OS, connection, lock state, screen, and what works on the target with a reason for the rest |
| `deviceloop view` | Opens the live screen in Device Hub |
| `deviceloop screenshot [-o <file>] [--native]` | Saves a full-resolution PNG and prints its path |
| `deviceloop mcp` | Serves the MCP protocol over stdio |

`info` gives each capability a status: `available`, `unavailable`, `needsOwnerAction` or `unknown`. The UI runner is `needsOwnerAction` on a device that is not paired, has Developer Mode off or has no stored team, and `unknown` on other devices, because the passcode prompt cannot be predicted.

### UI

| Command | What it does |
|---|---|
| `deviceloop ui tree [--app <id>] [--frames] [--max-rows <n>] [--screenshot]` | Prints the accessibility tree with a ref on each element |
| `deviceloop ui tap <target> [--count 2] [--hold-ms <ms>]` | Taps, double taps or long presses |
| `deviceloop ui swipe <up\|down\|left\|right> [--on <target>] [--velocity <px/s>]` | Swipes on the app or on one element |
| `deviceloop ui drag <x,y> <x,y> [--velocity <px/s>] [--hold-ms <ms>]` | Presses, drags in a straight line and releases |
| `deviceloop ui type <text> [--into <target>] [--clear]` | Types text, and with `--into` reads the field back |
| `deviceloop ui press <home\|volumeUp\|volumeDown\|action\|camera>` | Presses a hardware button the target has |
| `deviceloop ui find [--label <s>] [--label-contains <s>] [--id <s>] [--type <type>] [--all]` | Finds elements |
| `deviceloop ui wait [--until <condition>] [--label <s>] [--label-contains <s>] [--id <s>] [--type <type>] [--timeout-ms <ms>]` | Waits until an element exists, is gone, hittable or enabled, or until the screen is stable |
| `deviceloop ui alert [accept\|dismiss\|<label>] [--button <label>]` | Reads or answers a system or app alert |
| `deviceloop ui do '<step>' '<step>' ... [--screenshot]` | Runs steps in order and stops at the first failure |
| `deviceloop ui audit [--type <type>] [--suppressions <file>] [--no-screenshot]` | Runs XCTest's accessibility audit on the screen in front |
| `deviceloop keep-awake --at <x,y> [--interval <s>] [--for <s>]` | Sends periodic taps to an inert app point you choose |

`ui` commands drive the screen through the XCUITest runner, which DeviceLoop builds, signs with your team and launches over the CoreDevice tunnel. `ui` is verified on simulators and on the devices in [Limits on real devices](#limits-on-real-devices). The [runner section](#runner) covers how it starts.

- Targets are a point (`120,640`), a ref from `ui tree`, as printed or with `@` in front (`@e5457f2fb.1.42`), an identifier (`id=login`), a label substring (`label~=Wi`), or any other text as an exact label. Without `--app`, `ui` commands act on the app in front, however it was opened.
- A ref works only until the next `ui tree`, `ui audit`, input or Siri request on that target, and only for the same app and device orientation. A tap, swipe or type by an older ref fails with `stale_ref` before any input. Points, `id=` and labels are not affected.
- A label or query that matches nested elements, such as a button and the text inside it with the same label, acts on the outer one. Matches that are not nested fail with `element_ambiguous` and list up to 8 matches with their ids and frames under `Try:`. Element actions wait up to 2 s for a query to match, so a tap right after a navigation finds the new screen. Use `ui wait` for longer waits.
- A tap on a switch row, such as a SwiftUI `Toggle`, taps the switch inside it, so the toggle flips when tapped by its identifier or label.
- `ui tree` text leaves out `other` elements that have no label, id, value or placeholder, and their children take their depth. `--json` keeps every node. On an iOS 27 simulator the Settings root went from 178 lines to 75.
- A point outside the app's frame fails with `bad_arguments` before any input. A tap on an element whose center is outside the app's frame, such as an icon on another Home Screen page, fails with `element_not_hittable`, also before any input.
- `ui type --into` reads the field back and reports `textVerified`. A mismatch prints `typed "...", not verified` with what the field reads and exits 0. A secure field is not verified and its text is not printed. Without `--into` the field type is unknown and the text is echoed, so pass `--into` for passwords.
- `ui type --clear` taps near the field's right edge, deletes one character per character of the old text and reads the field again. When text is left it fails with `text_mismatch` before typing, which can happen in a right-to-left or multi-line field.
- `ui alert accept` and `dismiss` tap the one button with a known label: Allow, OK, Allow While Using App, Allow Full Access, Continue or Open for accept, and Don't Allow, Cancel, Not Now or Dismiss for dismiss. With no match or several, nothing is tapped and the command fails with `element_ambiguous` and lists every button. Pass one with `--button`. The labels are English, so on a device in another language use `--button`. On a location alert, accept taps Allow While Using App.
- `ui swipe` with a direction other than up, down, left or right, and `ui press` with a button other than home, volumeUp, volumeDown, action or camera, fail with `bad_arguments` before the runner starts. `ui press` with a button the target lacks fails with `unsupported_on_target`, sends nothing and lists the buttons it has. The volume buttons work only on devices.
- `ui do` steps: `tap id=login`, `doubletap @<ref>`, `hold 120,640 800`, `swipe up`, `drag 200,700 200,200`, `type "hello"`, `press home`, `launch com.apple.Preferences`, `open myapp://route` and `sleep 500`. `type "hello" id=email` types into that field. As in a flow, that step fails with `text_mismatch` when the field does not read back the typed text or cannot be read after typing, and a secure field is not checked. A `sleep` over 120000 ms fails with `bad_arguments` before any step runs. A failing step exits 1 and prints its error on stdout with the result. Errors before the first step, such as target selection or runner start, keep their own exit status and print like any other error. `--json` prints a `deviceloop.flow-result/1` object, so the point a tap hit appears only in the text output.
- Ctrl-C or SIGTERM stops `ui do` before the next step and exits 130. A second Ctrl-C does not force an exit.
- `ui audit` types are `contrast`, `elementDetection`, `hitRegion`, `sufficientElementDescription`, `dynamicType`, `textClipped` and `trait`. It saves a screenshot and a JSON report and exits 7 when issues remain after the suppressions. A suppressions file is a JSON array of rules such as `[{"type": "contrast", "id": "login", "reason": "Brand color"}]`. Rules that match no issue are listed as stale and do not change the exit status. An issue whose element is gone after the audit has no element, so no rule can match it.
- `keep-awake` needs an inert point in the current app at least 64 points from every screen edge. It sends one short tap every 25 s by default and stops on the first failed or uncertain input, on Ctrl-C or SIGTERM, or after `--for` seconds. It does not verify or guarantee that the screen stays awake, including in Low Power Mode. Stop it before changing the app or layout.

### Apps and logs

| Command | What it does |
|---|---|
| `deviceloop apps [--system] [--running] [--name <text>]` | Lists installed apps, or those whose name or bundle ID contains the text, or running apps with pids and, when a UI runner is already running, the foreground app |
| `deviceloop install <path>` | Installs an `.app` or `.ipa` and checks the installed version and build |
| `deviceloop uninstall <bundle-id>` | Uninstalls an app and checks that it is gone |
| `deviceloop launch <bundle-id> [--env K=V] [--restart] [--console] [-- <args>]` | Launches an app and reports its pid |
| `deviceloop terminate <bundle-id>` | Stops an app and waits up to 3 s for its pids to exit |
| `deviceloop open <url>` | Opens a URL or deep link and names the app that handled it |
| `deviceloop logs start <bundle-id> [--env K=V] [-- <args>]` | Relaunches an app with its stdout, stderr and os_log saved to a log file |
| `deviceloop logs start --system [--predicate <p>]` | Streams a simulator's unified log to a file |
| `deviceloop logs read <handle> [--tail <n>] [--grep <text>]` | Prints the lines captured so far |
| `deviceloop logs stop <handle>` | Ends the capture and reports how the app exited |
| `deviceloop crashes [--process <name>] [--since <time>] [--limit <n>]` | Lists crash reports, newest first |
| `deviceloop crashes pull <name> [-o <dir>]` | Copies a crash report to the Mac |
| `deviceloop container <bundle-id> [--path <folder>]` | Lists the files in an app's data container |
| `deviceloop container pull <bundle-id> <path> [-o <dir>]` | Copies one file out of the container |
| `deviceloop container push <bundle-id> <file> <path> [--overwrite]` | Copies one file into the container |

- `install` reads the bundle's Info.plist first and refuses a simulator build on a device, a device build on a simulator, or a build that needs a newer OS. It prints the version, build and signing.
- `launch` reports `launched`, `relaunched` with `--restart`, or `activated` when the app was already running, in which case the arguments and environment did not apply. It prints `launchedAt`, which `crashes --since` takes.
- `launch --env` and `logs start --env` values go on the `devicectl` command line, where other accounts on the Mac can read them with `ps`. [Threat model](../SECURITY.md#threat-model) says how to pass secrets instead.
- `launch --console` streams the app's stdout, stderr and os_log until it exits and saves them to `artifacts/log-<bundle ID>-<time>.log`. With `--json` the app's output goes to stderr and the JSON result to stdout. Output connects only to a new process, so pass `--restart` for an app that may be running.
- `logs start` terminates a running instance and relaunches the app for the same reason. A second capture of the same app on the same device fails with `device_busy`. While `ui` commands drive the app, the capture also holds XCTest's query log lines.
- `logs start --system` runs `log stream` on a simulator at its default level, so os_log info and debug messages are not captured. On a device it fails with `unsupported_on_target`. Use Console.app there.
- `logs stop` and Ctrl-C on `launch --console` end the app with SIGKILL, like `terminate`. When devicectl is still running 5 s after DeviceLoop ends the app, or on a second Ctrl-C, `launch --console` stops it and exits 130.
- When the app ends by a crash signal such as SIGSEGV, SIGABRT or SIGTRAP, `launch --console`, `logs read` and `logs stop` wait up to 45 s for its crash report and fail with `app_crashed` naming it. The captured lines stay in the log file named in the error's detail. After a SIGKILL, such as a watchdog termination, run `deviceloop crashes --since <launchedAt>`.
- `crashes --since` compares the time a report was written, which on a simulator is about 25 s after the crash. Reports are not symbolicated. Open them in Xcode with the app's dSYM.
- `crashes pull` and `container pull` do not replace a different file at the destination, and succeed without writing when it holds the same bytes.
- On a device, `container` needs a development-signed build of the app.
- `container push` refuses while the app runs (`app_running`), checked just before the copy, so an app that starts during the push is not caught. It replaces a file only with `--overwrite` and creates no folders. Pushes are not journaled, so `state restore` does not undo them.

### State and settings

| Command | What it does |
|---|---|
| `deviceloop location <lat,lon> \| clear` | Sets or clears the simulated location |
| `deviceloop appearance [light\|dark]` | Reads or sets the appearance |
| `deviceloop orientation [<orientation>]` | Reads or sets the orientation and reports the previous value |
| `deviceloop pasteboard copy <text> \| paste` | Writes or reads the pasteboard |
| `deviceloop state inspect` | Shows every identity and settings field, and why the unknown ones are unknown |
| `deviceloop state capture [-o <file>]` | Saves the state to a JSON file only you can read |
| `deviceloop state diff <before> [<after> \| --live]` | Compares two captures, or a capture with the live state |
| `deviceloop state scope start [--strict]` | Journals each later setting change with its original value |
| `deviceloop state scope status` | Shows the open scope and its changes |
| `deviceloop state restore [--dry-run] [--overwrite-conflicts] [--accept-residual] [--clear-location]` | Sets the journaled changes back, newest first, and closes the scope |

- Put `--` before a negative latitude: `deviceloop location -- -33.8568,151.2153`.
- devicectl and simctl cannot read the simulated location, so DeviceLoop cannot put back one set earlier. `location clear` removes any simulated location, including one another tool set. An app that is already running keeps its last coordinates until it is relaunched.
- `orientation <value>` sets `verified` from the orientation devicectl reads back right after the change, not from the app's interface. The home screen and portrait-only apps stay portrait, so confirm with a screenshot. Physical iPhones do not rotate, see [Limits on real devices](#limits-on-real-devices).
- `pasteboard copy` replaces the contents without saving them. DeviceLoop does not read or write the Mac's pasteboard.
- `state` marks each field `observed`, `unknown`, `unsupported` or `unavailable`, with a reason. Location, pasteboard, battery, thermal state and Low Power Mode are unknown on every target. `statusBarOverrides` lists the lines `simctl status_bar list` prints, so some values are simctl's enum numbers, for example `DataNetworkType: 1`.
- A scope journals `location`, `appearance`, `orientation`, the Siri system controls and `pasteboard copy`. `restore` sets appearance and orientation back. Location, the Siri system controls and pasteboard copy cannot be set back, and a `--strict` scope refuses them. `restore --clear-location` clears the simulated location instead, including one another tool set after DeviceLoop, and the location from before the scope is lost. `siri say`, `lock` and UI input are not journaled, and a strict scope does not refuse them.
- A field that changed since DeviceLoop set it is a conflict and stays as it is, also when something else set it back to its original value. Close such a scope with `--overwrite-conflicts` or `--accept-residual`. Otherwise `restore` exits 7 with `cleanup_incomplete` and keeps the scope open.
- Captures, `cleanup.json` and closed journals stay in `$DEVICELOOP_HOME/state/<udid>/` until you delete them. `doctor` shows an open scope only for targets devicectl still lists, so a scope left on a deleted simulator stays in `changes.jsonl` there. Without `--device` or `DEVICELOOP_DEVICE`, `doctor` also checks a shut-down simulator with an open scope, and its boot check fails until you boot it and run `deviceloop state restore`.

### Video and animation

| Command | What it does |
|---|---|
| `deviceloop video record [-o <file>] [--duration-ms <ms>]` | Records until Ctrl-C, or for `--duration-ms`, to a new file |
| `deviceloop video start` | Starts recording in the background and prints a handle |
| `deviceloop video stop <handle> [--no-analyze] [--region <x,y,w,h>] [--mask <x,y,w,h>]` | Stops a recording and analyzes it |
| `deviceloop video capture --do <step> [--pre-ms <ms>] [--wait-ms <ms>] [--keep-video] [--instruments --app <id> [--keep-trace]]` | Records around one step and times the screen's response |
| `deviceloop video inspect <file> [--no-sheet] [--region <x,y,w,h>] [--mask <x,y,w,h>]` | Analyzes any MP4 or MOV |
| `deviceloop trace record --app <id> [--template <name>] [--duration-ms <ms>] [-o <file.trace>]` | Records an Instruments trace of one running app |

[Animation debugging with video](#animation-debugging-with-video) explains the recordings and the report.

### Runs and comparisons

| Command | What it does |
|---|---|
| `deviceloop run start [--name <name>] [--app <id>] [--source <dir>]` | Starts recording the device's commands into a new run |
| `deviceloop run status` | Prints the report of the device's active run |
| `deviceloop run stop` | Finishes the run, prints its report and writes `report.html` |
| `deviceloop run show <id>` | Prints the report of any run |
| `deviceloop run report <id>` | Renders `report.html` again |
| `deviceloop run list` | Lists runs, newest first, with status, first failure and size |
| `deviceloop run prune [--older-than <days>] [--keep <n>]` | Removes old runs |
| `deviceloop run compare <baseline> <candidate> [--ignore id=<id>] [--mask <x,y,w,h>] [--max-diff <percent>] [--min-ms <ms>]` | Compares two runs step by step |
| `deviceloop run export <id> --out <dir> [--no-media] [--keep-typed-text] [--zip]` | Copies a run into a redacted folder for a bug report |
| `deviceloop run export --comparison <id> --out <dir>` | Copies a comparison and its two runs the same way |

- A run lives in `$DEVICELOOP_HOME/runs/<id>` with `manifest.json` (DeviceLoop, macOS, Xcode, device, app and source commit), `events.jsonl`, each command's result in `results/` and its files in `artifacts/`. A device has one active run at a time. Every command that names the device is recorded into it, except `devices`, `doctor`, `setup`, `prepare`, `state diff`, `video inspect`, `mcp` and `run` itself. `logs read` and `logs stop` are not recorded either. The MCP `run` tool has every action except `prune`.
- A run started over MCP reads `incomplete` once that MCP server exits, and commands on the device keep recording into it until `deviceloop run stop`.
- Stopping a run while another command on that device is still running marks the run failed, with that command listed as not finished.
- A command that fails with an error is journaled as `error`, and a cancelled one as `cancelled`. A `ui do`, `flow run` or `flow_run` that returns a failed or cancelled flow result is journaled the same way. Any other command that prints its result and exits non-zero, such as a failed `test run` or a `ui audit` with issues, and an MCP tool that returns an error result, such as a failed `test_run` job, are journaled as `error`. Each of these fails the run.
- Event offsets and command durations use the Mac's host clock, which pauses while the Mac sleeps and restarts at boot. Use each event's `time` for runs that span a sleep or restart.
- Runs hide the text of `ui type`, the type steps of `ui do`, `video capture --do`, `perf run --setup` and `perf run --measure`, `siri say`, `pasteboard copy` and the MCP `text` argument as `[hidden]`, replacing every occurrence in that command's arguments, result and error. A short text such as one digit also hides that character elsewhere in the result. Text the app shows on screen still appears in later trees and screenshots, and launch environment values and app arguments are saved as given. `flow run` hides the typed text of the flow file in the journal. While a run records, a flow run saves `flow.json` and `result.json` in the run's `artifacts/flows/` with its typed text as `[hidden]`.
- `run prune` deletes run folders and is not run automatically. It keeps runs that a device still records into. It reports each run's logical size, and copied artifacts share disk blocks on APFS, so it can free less space than it reports. It does not check comparisons, so pruning a run breaks the links in comparisons that name it.
- `run compare` writes `comparison.json` and `comparison.html` under `$DEVICELOOP_HOME/runs/comparisons/`. The verdict is `same`, `different` or `inconclusive`, and the command exits 0 for every verdict, so read `verdict` from `--json` to fail a script or CI job. It is `inconclusive` when the product type, OS build, screen, orientation, app or command sequence differ. CLI and MCP name commands differently, so a CLI run and an MCP run do not line up.
- UI trees compare where both runs saved a `ui tree`. Elements with an identifier match by type and identifier, others by type and label, and those with neither by type alone. A label change on an element without an identifier shows as one element removed and one added. A group of elements with neither an identifier nor a label and the same count on both sides is not compared element by element. Frame changes of 2 pt or less are not reported. Give the elements you check an accessibility identifier.
- Screenshots compare only for screenshot steps (`screenshot`, MCP `screen_capture`), not the image `ui tree --screenshot` saves. A pixel counts as changed when a color channel differs by more than 16 of 255, and changed areas group in 32 px tiles. Neither has a flag. The status bar is not masked, so pass `--mask` over it (for example `0,0,430,54` on a 430 pt wide screen) or the clock alone marks a screenshot changed. Screenshots compare in 8-bit sRGB, so Display P3 colors outside sRGB are clamped.
- Video timings compare where both runs saved an animation report. They are visual estimates from one capture each, so a timing is only `changed`, not `regressed`.
- `run export` turns device names, UDIDs, teams, tokens and the home path into aliases, hides typed text and pasteboard contents, and lists the SHA256 of every file in `EXPORT.txt`. Screenshots, videos and UI text such as tree labels and values are copied as recorded, so review them before you share the folder. Typed text of three or more characters is hidden wherever it appears, which can also replace matching parts of other values such as bundle IDs. `--keep-typed-text` cannot restore text the run already journaled as `[hidden]`. Device names are replaced for devices devicectl lists at export time and devices a command named with `--device`, so export while devicectl still lists the device.

### Flows

| Command | What it does |
|---|---|
| `deviceloop flow validate <file>` | Checks a flow file without a device and lists what it needs |
| `deviceloop flow run <file> [--app <id>] [--timeout-ms <ms>]` | Runs a flow and saves its result and screenshots |
| `deviceloop flow export <file> -o <File.swift> [--class <name>] [--app <id>]` | Writes a flow as a new XCTest UI test file |

A flow is a JSON file with the schema `deviceloop.flow/1`:

```json
{
  "schema": "deviceloop.flow/1",
  "name": "login",
  "app": {"bundleID": "com.example.MyApp"},
  "reset": "relaunch",
  "steps": [
    {"tap": {"id": "login"}},
    {"type": {"text": "user@example.com", "into": {"id": "email"}}},
    {"assert": {"element": {"id": "welcome"}, "is": "exists"}},
    {"screenshot": {"name": "home"}}
  ],
  "cleanup": [{"press": {"button": "home"}}]
}
```

- Top-level fields are `schema`, `name`, `app` (`bundleID`, and optional `arguments`, `environment`, `version` and `build`), `reset` (`none` by default, `relaunch` or `reinstall`), `appPath` (the `.app` or `.ipa` that `reinstall` installs), `requires`, `timeoutMs` (default 300000), `setup`, `steps` and `cleanup`.
- Step kinds are `tap`, `doubletap`, `hold`, `swipe`, `drag`, `type`, `press` (home or action), `launch`, `open`, `sleep`, `assert`, `settle`, `screenshot` and `alert`. Each takes a `timeoutMs` (default 30000). A target is `x` and `y`, or one of `id`, `label` and `labelContains` with an optional `type`. Refs are not accepted because they do not replay.
- Flow v1 has no Siri, location, appearance, orientation, audit or checkpoint steps, and cannot resume from a checkpoint.
- [Examples/Flows](../Examples/Flows) has two flows for the runner's fixture app. They name the simulator host app `com.argmaxinc.deviceloop.host`, which is installed when the runner starts, so run `deviceloop runner start` before the first flow on a target. A device build adds the signing team to that ID, so on a device pass `--app` with the host bundle ID that `deviceloop runner start` prints.
- Each run writes `flow.json`, `result.json` (schema `deviceloop.flow-result/1`) and its screenshots to `$DEVICELOOP_HOME/artifacts/flows/flow-<time>-<id>/`. A failing step also saves `failure.png`, taken inside that step, so its `endMs` includes it. A run stopped by the deadline or by cancellation has no failure screenshot.
- The app start before setup is not a step and does not count toward `timeoutMs`. A run that fails while it reinstalls or starts the app reports the error and leaves `flow.json` without `result.json`.
- Setup and steps stop at the first step that does not pass. Every cleanup step runs, also after the deadline and after an earlier cleanup step failed, each for up to its own `timeoutMs`. A cleanup failure turns a passed run into `cleanup_failed`.
- A step reports `unknown` only for `action_outcome_unknown`. A step that fails with `xctest_issue` reports `failed` although its action may have taken effect, so check the screen before you run the flow again. A `type` step with `into` fails with `text_mismatch` when the field does not read back the typed text.
- Ctrl-C, SIGTERM or `flow_cancel` lets the step in progress finish, up to its `timeoutMs`, then runs cleanup. `flow run` then exits 130. A second Ctrl-C does not force an exit.
- `requires` takes `ui runner`, `home button`, `action button`, `install` and `uninstall`, which differ from the capability names `deviceloop info` prints. `flow validate` lists everything a flow needs. Buttons are checked through the UI runner, so a missing button is reported after the runner starts, which on a device can include its first build.
- `reset: reinstall` does not reset keychain items, iCloud or server data, or permission grants, and `result.json` lists what was not reset under `notReset`. A relative `appPath` resolves against the current directory of the `deviceloop` process, which for `flow_run` is the MCP server's directory, not the folder of the flow file.
- While a flow runs, UI commands that start after it on that device fail with `device_busy`. A UI command that connected before the flow started, such as `keep-awake` or a long `ui do`, keeps sending input and can interleave with the flow.
- `flow export` writes one XCTestCase class with one test method to a new file and does not edit an Xcode project. It exits 2 for `settle`, `type` with `clear` and `reset: reinstall`, and lists fragile steps: points, drags and sleeps.
- An exported test differs from `flow run`. An assert can wait up to twice the step's `timeoutMs` and the flow's `timeoutMs` is not applied. A `type` step with `into` does not read the field back. Taps call `XCUIElement.tap()` instead of tapping the center of the element's frame. An `alert` step answers only system alerts shown by SpringBoard. Cleanup steps act on the app of the last `launch` step in setup and steps, even when the test failed before that launch ran.

### Tests and perf

| Command | What it does |
|---|---|
| `deviceloop test run --project <p> \| --workspace <w> --scheme <s> [--test-plan <t>] [--only-testing <id>] [--skip-testing <id>] [--configuration <c>] [--timeout <s>] [-- <xcodebuild args>]` | Runs a scheme or test plan with xcodebuild and summarizes the result bundle |
| `deviceloop test run --xctestrun <file> [--only-testing <id>] [--skip-testing <id>]` | Runs a prebuilt `.xctestrun` from `build-for-testing` |
| `deviceloop test results <bundle.xcresult>` | Summarizes any result bundle |
| `deviceloop perf launch <bundle-id> [--iterations <n>] [--launch-arg <arg>]` | Measures launch time with `XCTApplicationLaunchMetric` |
| `deviceloop perf run --app <id> [--setup <step>] --measure <step> [--metric <list>] [--iterations <n>]` | Measures UI steps with XCTest hitch, CPU, memory, clock and signpost metrics |
| `deviceloop perf compare <baseline> <candidate>` | Compares the metrics of two perf or test jobs |

- Each job gets a directory `$DEVICELOOP_HOME/artifacts/test-<time>-<id>/` with `result.xcresult`, `xcodebuild.log` and `summary.json`, and `perf.json` for perf jobs. These commands exit 0 when tests pass, 1 when tests or the build fail, 130 after Ctrl-C and 5 after `--timeout`.
- A job fails with `device_busy` while a flow runs on the target, and while the UI runner runs on it unless you pass `--stop-runner` to stop it first. While a job runs, UI commands on that target fail with `device_busy`.
- For a device, give the signing team after `--`, for example `-- DEVELOPMENT_TEAM=<team ID>`, or pass `--allow-provisioning-updates`. A build that needs a team fails with `signing_no_team`. `test_run` over MCP has no xcodebuild passthrough, so a device run there needs the team set in the project or a signed `.xctestrun`. Its relative paths resolve against the MCP server's directory.
- On a locked device a job fails with `device_locked` before it starts, and with `ui_automation_passcode` when nobody enters the passcode UI tests ask for. The passcode hint prints on every device UI test and perf run, also when no prompt appears.
- Test diagnostics are off unless you pass `--diagnostics`.
- `METRIC` lines do not name the device or test plan configuration, so a plan with several configurations prints one unlabeled line per configuration. The JSON carries both.
- Hitch metrics need iOS 26 or later. On the iOS 27.0 simulator XCTest recorded no hitch measurements for a navigation scenario. CPU and memory are totals for the app process, not for the measured steps, and simulator timings come from the Mac.
- `perf` refuses to start while the target is being recorded. A recording started during a perf job is not refused and changes the measurement.
- `perf run` does not check that a type step's text landed in the field. Check the step with `deviceloop ui type` before you measure it. Typed text is kept in the job's result bundle and log.
- `perf compare` calls a metric different only when both runs have at least 5 measurements and their min to max ranges do not overlap. It reads the app and steps from the `perf.json` in each job directory, so a `summary.json` or bundle copied out of that directory is compared without the scenario check. It sees type steps as `type <text>`, so two runs that differ only in typed text count as one scenario.
- [Examples/SuiteFixture](../Examples/SuiteFixture) is a small project to try `test run` on.

### Siri and system controls

| Command | What it does |
|---|---|
| `deviceloop lock [--verify-seconds <s>]` | Locks the screen through Siri and reports whether devicectl confirmed it |
| `deviceloop siri say <text> [--wait] [--expect <target>] [--app <id>] [--timeout <s>]` | Says anything to Siri |
| `deviceloop siri wifi\|bluetooth\|lowpower\|dnd\|airplane on\|off` | Toggles a system setting |
| `deviceloop siri brightness\|volume <0-100>` | Sets brightness or media volume |
| `deviceloop siri test <scenario.json> [--artifacts <dir>]` | Runs Siri phrases against an app and checks the entities they created |

Some system actions have no devicectl, simctl or XCTest API. The runner reaches them through Siri (`XCUISiriService`), so the device must be unlocked and Siri enabled. DeviceLoop cannot read most of these settings back, so take a screenshot to confirm. A Siri request can open Siri's own interface, so these are less deterministic than the devicectl commands.

- `lock` asks Siri once, then reads devicectl's lock state every second for `--verify-seconds` (default 8). It exits 0 also when it cannot confirm the lock, so scripts read `lockVerified` from `--json`. A device with no passcode does not report the lock, so DeviceLoop cannot confirm it. Only the owner's Face ID or passcode unlocks the device.
- Airplane Mode over Wi-Fi drops the connection to the device.
- `siri say` returns once the runner accepts the request. `--wait` polls the receipt until XCTest returns and prints its XCTest issues, and `--expect` then looks for an element and sets `verified`. Both exit 0 once the receipt finishes, also with XCTest failures or an unmet expectation, so read `verified` and `issues` from `--json`. After Siri the app in front can be Siri itself, so pass `--app` with `--expect`.
- Until XCTest's Siri call returns, `ui` commands return `device_busy`. [docs/siri.md](siri.md#how-a-request-runs) lists how long that took on each device. `deviceloop screenshot` works in the meantime, and `deviceloop runner operation <id> --epoch <epoch>` reads the receipt.
- Siri results report the device's preferred languages. Siri's own language and whether Siri is on are unknown to public tools.
- `deviceloop help siri test` shows the scenario format. Each phrase runs after the scenario's reset intent, and the outcome is `verified`, `missing`, `wrong_entity`, `duplicate`, `unverified` or `uncertain`. It exits 8 when a phrase is not verified or was not sent, and saves `report.json` and screenshots, one every 5 s while XCTest's Siri call runs.
- `siri test` reads entities through App Intents where AppIntentsTesting loads. Elsewhere it brings the app to the front and counts the elements whose label contains `matching`, without running the reset or seed intents. Then counts include items left by earlier phrases and runs, and a title shown in two elements counts twice.
- The first request for a fresh app's App Shortcut asks "Turn on '<app>' shortcuts with Siri?". Tap Turn On once before `siri test`, or the phrase reports `missing`. Siri effects outside the app are not observed or cleaned.

### Runner

| Command | What it does |
|---|---|
| `deviceloop runner start` | Builds the UI runner if needed and starts it |
| `deviceloop runner status` | Shows whether the runner is running, its uptime, host app and startup log |
| `deviceloop runner stop` | Stops the runner |
| `deviceloop runner operation <id> --epoch <epoch>` | Reads an operation receipt without sending input |

- The first UI command on a target starts the runner, and `runner start` does it ahead of time. A device runner start waits up to 90 s, or until 75 s after XCTest starts the runner's tests when that is later. Builds are cached per team under `$DEVICELOOP_HOME/runner`, and a cached device build whose provisioning profile expired is built again.
- After an upgrade, the next UI command replaces a runner started by another DeviceLoop version. [Upgrade](#upgrade) covers builds of the same version.
- The runner runs one request at a time and rejects the rest with `device_busy`. `devicectl` and `simctl` commands are outside that limit.
- An error with a `Receipt:` line names the operation. When the outcome is unknown (`action_outcome_unknown`), read the receipt with `runner operation` before sending the input again.
- `signing_profile_failed` means the device rejected the runner's provisioning profile, or the team's profile does not include the device. The fix line names what to remove or add.
- The runner session, its lock and the test job marker live under `DEVICELOOP_HOME`, so DeviceLoop processes with different `DEVICELOOP_HOME` values do not see each other's runner or test job on the same device.

## Animation debugging with video

DeviceLoop records the screen and turns the recording into numbers and one contact sheet image.

- Simulators record the visible display with `simctl io recordVideo`, the display `screenshot` captures.
- Devices record over USB with AVFoundation at native resolution, through a small helper app, `DeviceLoopCapture.app`. macOS asks for camera access for it on the first recording. Click Allow. A Homebrew install, once the tap is published, will ship the helper signed with Argmax's Developer ID. A source build, the way to install today, builds one under `DEVICELOOP_HOME` on its first device recording and signs it with the Apple Development identity of the team `deviceloop setup` stored, or ad hoc when there is none. Switching between the two, or rebuilding from source, can make macOS ask again. `doctor` shows which helper is used.
- On a device, `video` records over USB only and refuses a device on the network with `unsupported_on_target`. It refuses with `device_ambiguous` when another connected device has the same name, because the capture source is picked by name. Rename one in Settings > General > About > Name.
- Device recordings stop on their own after 10 minutes. DeviceLoop waits 5 s after one USB capture ends before it starts the next.
- Analysis runs on the Mac with AVFoundation. No ffmpeg is needed.

```bash
deviceloop video capture --do 'tap id=login' --device usb
deviceloop video start --device usb
deviceloop video stop <handle>
deviceloop video inspect ~/Desktop/recording.mov
```

The Motion tab of [Examples/Sample](../Examples/Sample) can block its main thread during a move. `deviceloop-sample://move?driver=frames&stall=150` moves its card from the main thread on every frame and blocks the main thread for 150 ms at 40 percent of the move, so `deviceloop video capture --do 'open deviceloop-sample://move?driver=frames&stall=150'` reports a jump of about 150 ms. Without `driver=frames` the same stall showed no jump on the iOS 27.2 simulator. [MotionLab.swift](../Examples/Sample/Sample/MotionLab.swift) lists the other links and the trial log.

`video capture` records `--pre-ms` (default 300) before one `ui do` step and `--wait-ms` (default 1500) after it, and times the screen's response. `video start` records in the background and prints a handle, so you or an agent can act on the device before `video stop <handle>` stops and analyzes it. `video inspect` analyzes any MP4 or MOV, including QuickTime and Device Hub recordings. A failed or interrupted capture keeps its video, and `--keep-video` keeps it after a successful one.

### What the report means

- **Response**, from `video capture` only: latency from sending the step to the first change, animation duration, and the time of the last change. Latency is measured from the send, not the touch, and XCTest's idle waits fall inside the action window. Runner steps connect the runner before recording starts, so runner startup is not in the timing. The report says whether the screen changed in the last 300 ms of the recording. That is an observation window, not a sign that the app is idle.
- **Feedback**: a short, small change before a larger one, such as a touch-down highlight before a push, is reported as `response.feedback`. `firstChangeAt`, `latencyMs` and `animationMs` then describe the change after it. Another change on screen between the action and the highlight leaves `feedback` unset.
- **Motion segments**, each with the changed screen region and a motion energy curve.
- **Cadence**: the frame rate and `detectionFloorMs`, the shortest gap the recording can show. USB recordings measure the rate from capture timestamps. Simulators report 60 fps as `assumed`, because simctl writes frames only when the screen changes. `video inspect` measures it from the file's frame intervals and falls back to 60. Analysis reads at most 60 fps, so a 120 fps file is analyzed in 16.7 ms slots and cannot show shorter gaps.
- **Visual gap candidates**: holes of repeated or missing frames during motion. A `jump` is a hole after which the content caught up, a `delay` one where the motion slowed. On USB, a hole with no delivered frames or a frame the recorder reported dropped is a recorder gap, listed under `recorderGaps` and left out of the counts.
- **Contact sheet** of the frames that changed, saved as a PNG and returned inline over MCP as a JPEG.

The JSON schema is `deviceloop.animation/2`. Candidates are under `candidates`, the end of motion is `response.lastChangeAt` with `response.unchangedAtEnd`, and there are no `hitches`, `settled` or `rating` fields.

### Visual gap candidates are not hitch metrics

Gap candidates come from the video, not from the device's render loop. `visualMsPerMotionSec` is a visual estimate, not Apple's hitch time ratio. Simulator frame timing comes from the Mac, so measure animation timing on a device when it matters.

- Candidates use the change over the whole analyzed area, so other motion on screen, such as a spinner, a clock or a playing video, can hide a stall. `--mask x,y,w,h` (repeatable) ignores an area and `--region x,y,w,h` analyzes only part of the screen. Both are in source pixels and widen to whole analysis tiles, each 1/20 of the frame width (about 64 px on a 1290 px wide recording), so a mask can hide motion up to one tile around it.
- Motion whose changes are 3 or more frames apart throughout, 20 fps or slower in a 60 fps recording, is a stepped animation. It gives no candidates unless a pause is longer than its usual step. A frame rate that drops that low for a whole segment looks the same. A 30 fps animation in a 60 fps recording still reports delay candidates.
- When `video capture` taps a Button, the pressed highlight at touch-down and an animation that starts at touch-up can show as a 67 to 83 ms candidate, a delay in one capture and a jump in the next.
- On an iPhone 15 Pro Max with iOS 27.0, injected 100 ms main-thread stalls in the animation test app that became the Motion tab of [Examples/Sample](../Examples/Sample) were reported as 100 ms jumps. Instruments' Animation Hitches listed no hitch for them, and its displayed-surfaces table showed a 116.7 ms gap at the same point.

### Check candidates with Instruments

On a device, `video capture --instruments --app <bundle-id>` records an Animation Hitches trace of the app around the capture. xctrace attaches to the app's pid first, and the USB capture starts once tracing has started. The report gets a `trace` block, and each candidate gets a `traceVerdict` from the trace's displayed-surface gaps:

- `confirmed`: a displayed-surface gap overlaps at least 0.8 of the candidate.
- `notConfirmed`: the display kept presenting frames through the hole. An app that presents identical frames while it stalls also reads `notConfirmed`, so this does not rule out a stall.
- `inconclusive`: the trace could not be placed on the video closely enough, the hole is outside the trace, or a gap overlaps it only in part.
- `unavailable`: the trace has no displayed-surface swaps.

`trace.gaps` lists displayed-surface gaps that start and end inside one motion segment, so a stall at the very start or end of a motion is not listed. With `trace.method` `clock`, the gaps are placed by the Mac's clocks alone and may not line up with the video. Tracing needs about 0.5 GB of free disk per second of `--pre-ms`, `--wait-ms` and a 10 s margin, plus 1 GB, about 7 GB with the default waits. The trace lasts at most 60 s, so `--pre-ms` and `--wait-ms` together can be at most 50000. The trace is deleted after export unless you pass `--keep-trace`. Simulators fail with `unsupported_on_target`.

`deviceloop trace record --app <bundle-id>` records a standalone trace with xctrace, attached to the app's pid. The template defaults to Time Profiler and must be a name from `xcrun xctrace list templates`. Animation Hitches is not supported on simulators. Recording stops after `--duration-ms` (default 10000, at most 60000) or on Ctrl-C, and writes the `.trace`, its table of contents as `.toc.xml` and a `deviceloop.trace/1` summary as `.summary.json`.

- The disk check counts free space without purgeable space, so it can refuse while Finder shows enough room. Free some space, or pass a shorter `--duration-ms` or `--wait-ms`.
- In a summary, `hangs` counts rows at the template's threshold (250 ms for Time Profiler, 33 ms for Animation Hitches), and `surfaces.longestMs` includes still-screen intervals, so it is not a hitch.
- Ctrl-C stops the recording and still writes the table of contents and summary. A second Ctrl-C during that export quits without a summary and keeps the trace.

## Limits on real devices

Measured on an iPhone 13 Pro with iOS 18.7.8, an iPhone 15 Pro Max with iOS 27.0 and later 27.2, and an iPad Air with iPadOS 26.6.2, with Xcode 27.1 on Oct 22nd, 2026 and Xcode 27.2 on Nov 8th, 2026.

- **Screen video**: with Xcode 27.2, none of the three devices offers devicectl's screen recording, which works on simulators only. Device video goes over USB.
- **Speed**: with Xcode 27.1, a devicectl screenshot took 1.2 to 1.9 s, a UI tree 270 to 520 ms, and a tap 0.7 to 2.9 s, because XCTest waits for the app to be idle and has no public API to skip that.
- **Runner start**: the first runner build for the iPhone 13 Pro took 14.6 s. Replacing a runner from another DeviceLoop version took about 5 s with no passcode on all three devices, and 17 s on the iPhone 13 Pro when it also rebuilt.
- **Passcode prompt**: the iPhone 15 Pro Max asked for the UI Automation passcode again hours after its first approval. A runner start 18 minutes after an approval took 4.4 s with no prompt.
- **Siri**: XCTest's Siri call held 130 to 142 s on the iPhone 15 Pro Max with iOS 27.0 and 27.2 and recorded "Timed out waiting for Siri to activate", although Siri answered on screen within about 7 s. It took under a second with iOS 18.7.8 and iPadOS 26.6.2, and under 5 s on an iOS 27.0 simulator.
- **App Intents**: AppIntentsTesting loads on the iPhone 15 Pro Max with iOS 27.2 and Xcode 27.2, and does not load on iOS 27.0.
- **Orientation**: `devicectl device orientation set` succeeds on the iPhone 13 Pro and the iPhone 15 Pro Max with iOS 27.2, but the screen stays portrait, so DeviceLoop reports `verified: false`. The iPad Air and simulators rotate.
- **Hardware buttons**: the iPhone 15 Pro Max has home, volumeUp, volumeDown and action, and no camera button. The volume buttons on its home screen change the ringer.
- **USB capture and the tunnel**: on the iPhone 13 Pro every USB recording moves the CoreDevice tunnel at start and at stop, and the runner stops answering. DeviceLoop starts a new runner (about 7 s, no passcode), so a `video capture` with a UI step takes 17 to 19 s there. The iPhone 15 Pro Max with iOS 27.2 kept its tunnel.
- **Back-to-back captures**: a capture started less than about 4 s after any USB capture ended, also of another device, found no capture source. DeviceLoop waits 5 s, and 15 of 15 back-to-back recordings across the three devices then succeeded.
- **Crash reports**: on the iPhone 13 Pro a report appeared about 1 s after the crash.
- **Instruments**: a 14 s Animation Hitches trace on the iPhone 15 Pro Max with iOS 27.0 wrote about 1.6 GB plus a 1.6 GB ktrace. On a full disk xctrace crashed and left its temporary files.
- **perf**: on the iPad Air, launch medians were 0.14 to 0.33 s against 2.2 to 2.6 s on a simulator, and `XCTHitchMetric` reported 0 hitches for 100 ms main-thread stalls in the same test app. `--diagnostics` on a device runs `devicectl diagnose`, which failed on the iPad Air.
- **Appearance settings** differ by OS version. [docs/parity.md](parity.md) has the details, and `deviceloop info` lists what is missing on a target.

## Troubleshooting with doctor

`deviceloop doctor` checks the Mac and every device and booted simulator. `deviceloop doctor --device <name>` checks one, and so does `doctor` with `DEVICELOOP_DEVICE` set. Each line is `ok`, `warn` or `fail`, and every problem has one fix line.

```text
This Mac (macOS 27.2.0)
ok   xcode: Xcode 27.2 (27B52) at /Applications/Xcode.app/Contents/Developer
ok   devicectl: 651.32
ok   license: accepted
ok   first launch: done
ok   teams: ABCDE12345 (Example, Inc., Company)
ok   identities: Apple Development for ABCDE12345 (2 valid identities)
ok   deviceloop team: ABCDE12345 in ~/Library/Caches/deviceloop/config.json
warn capture helper: not built yet. Screen video from USB devices needs it
     fix: Run `deviceloop video record` on a USB device once, then click Allow when macOS asks for camera access.
ok   runner project: /opt/homebrew/Cellar/deviceloop/0.1.0/share/deviceloop/Runner
ok   host ddi: iOS 27B52 at /Library/Developer/DeveloperDiskImages/iOS_DDI
iPhone 15 Pro Max (device, iOS 27.2)
ok   pairing: paired
ok   developer mode: enabled
ok   connection: connected over USB
ok   tunnel: fd12:3456:789a::1
warn lock: locked
     fix: Unlock iPhone 15 Pro Max.
ok   ddi services: usable (27B52)
warn ui automation: no live runner. Starting one may ask for the passcode on iPhone 15 Pro Max
     fix: Run `deviceloop prepare --device <udid>` while you can enter the passcode on iPhone 15 Pro Max.
ok   runner: no session
iPhone 17 Pro (simulator, iOS 27.2)
ok   boot: booted
ok   runner: no session
0 failed, 3 warnings
```

`doctor` exits 1 when a check fails. `doctor --json` prints the same checks with the error code each problem maps to.

| Check | Fix |
|---|---|
| `xcode`, `devicectl` | Install Xcode 27, then `sudo xcode-select -s /Applications/Xcode.app` |
| `license` | `sudo xcodebuild -license accept` |
| `first launch` | `sudo xcodebuild -runFirstLaunch` |
| `teams`, `identities`, `deviceloop team` | Add your Apple ID in Xcode > Settings > Accounts, then `deviceloop setup` |
| `capture helper` | Record once from a USB device and allow camera access. The line shows `bundled` or `built` and the helper path |
| `runner project` | Keep the source checkout the binary was built in, set `DEVICELOOP_RUNNER_PATH` to its `Runner` folder, or reinstall DeviceLoop |
| `host ddi` | `sudo xcodebuild -runFirstLaunch -checkForNewerComponents` or `xcrun devicectl manage ddis update` |
| `targets` | `deviceloop devices --all`, then boot a simulator with `xcrun simctl boot <udid>`, or connect and unlock a device |
| `boot` | `xcrun simctl boot <udid>` |
| `pairing` | Unlock the device, tap Trust and enter the passcode |
| `developer mode` | Settings > Privacy & Security > Developer Mode on the device, then restart it |
| `connection`, `tunnel` | Connect the cable, or join the same network, and unlock the device |
| `lock` | Unlock the device |
| `ddi services` | `deviceloop prepare --device <udid>` mounts the developer disk image |
| `ui automation` | `deviceloop prepare --device <udid>` while you can enter the passcode |
| `runner` | `deviceloop runner stop --device <udid>`, then run the UI command again |
| `state scope` | `deviceloop state restore --device <udid>` |

The `ui automation` line appears only for connected devices, and shows `warn` while a runner is still starting.

To report a bug, run `deviceloop doctor --export <folder>` and attach the folder. It writes `doctor.json`, `version.txt`, `runs.json` and `REDACTIONS.txt` to a new or empty folder, with device names, UDIDs, teams, tokens and the home path replaced by aliases. `doctor --json` is not redacted. Add `--include-runner-logs` when the runner does not start. The export replaces the names of devices listed at export time, so check the runner log tails for the names of devices that are no longer connected. Read the files before you share them.

## Privacy and data on disk

DeviceLoop keeps everything under `DEVICELOOP_HOME`, which defaults to `~/Library/Caches/deviceloop`. Clearing `~/Library/Caches` deletes the stored team, the runs and the journal an open state scope needs to set its changes back.

| Path | Holds |
|---|---|
| `config.json` | The signing team |
| `artifacts/` | Screenshots, videos, contact sheets, crash reports, pulled files, app logs, test jobs, flow runs and Siri scenario reports |
| `runs/` | Runs and comparisons |
| `state/<udid>/` | State captures, scope journals and `cleanup.json` |
| `sessions/<udid>/` | Runner sessions with their token, runner startup logs, `automation.json` and the flow and test job locks |
| `runner/` | Runner builds, per team |
| `recordings/` | Background recordings in progress |
| `logs/` | The MCP activity log `mcp.jsonl`, and the handles of `logs start` captures |
| `DeviceLoopCapture.app` | The capture helper of a source build |
| `tmp/` | xctrace's temporary files, removed after each trace |

DeviceLoop does not prune old files. `run prune` removes old runs, and you delete the rest.

Runs and the MCP activity log hide typed text, as described under [Runs and comparisons](#runs-and-comparisons) and [Activity log](#activity-log). [What DeviceLoop stores](../SECURITY.md#what-deviceloop-stores) lists the files that keep secrets or typed text, and [Runner token and network](../SECURITY.md#runner-token-and-network) describes the runner's token.

DeviceLoop sends no telemetry. [What leaves the Mac](../SECURITY.md#what-leaves-the-mac) lists the connections it makes and where command output goes.

## Upgrade and uninstall

### Upgrade

In the checkout:

```bash
git pull
xcrun swift build -c release --product deviceloop
deviceloop runner stop --device <udid>
```

- The link in `~/.local/bin` points at the build product, so it runs the new build.
- Run `runner stop` on each target that has a runner. With `DEVICELOOP_DEVICE` unset, `doctor` prints a `runner` line for each target. DeviceLoop keeps using a runner that another build of the same version started. After `runner stop`, the next UI command builds and starts the new runner.
- Restart your agent sessions so they start the new `deviceloop mcp`.
- Copy `skills/deviceloop/SKILL.md` to `~/.claude/skills/deviceloop/` again.
- Builds of older runner sources stay in `$DEVICELOOP_HOME/runner`. To free the space, run `runner stop` on every target, then delete that folder. The next UI command builds the runner again.

### Uninstall

1. Stop the runner on each target with `deviceloop runner stop --device <udid>`.
2. Remove the apps DeviceLoop installed. `deviceloop apps --name com.argmaxinc.deviceloop --device <udid>` lists them on a target: the host app and the runner, plus the Siri fixture if you installed it. On a device their bundle IDs include your team ID. Remove each with `deviceloop uninstall <bundle-id> --device <udid>`.
3. Remove the MCP server from each agent:
   - Claude Code: `claude mcp remove -s user deviceloop`
   - Codex: delete the `[mcp_servers.deviceloop]` table from `~/.codex/config.toml`
   - Cursor: delete `mcpServers.deviceloop` from `~/.cursor/mcp.json`
   - Gemini CLI: `gemini mcp remove -s user deviceloop`
4. Delete the `deviceloop` link in `~/.local/bin`, the skill copy in `~/.claude/skills/deviceloop`, the checkout and the `DEVICELOOP_HOME` folder that [Privacy and data on disk](#privacy-and-data-on-disk) describes.
5. Reset the capture helper's camera permission with `tccutil reset Camera com.argmaxinc.deviceloop.capture`.

Devices stay paired and registered with your signing team, and Developer Mode stays on.
