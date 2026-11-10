---
name: deviceloop
description: Drive iPhones, iPads and simulators paired with this Mac through the DeviceLoop MCP tools or the DeviceLoop CLI. Use it to read and tap the screen, run flows and XCTest suites, install, launch and debug apps, change device settings and set them back, record and compare runs, and measure animations from screen recordings or Instruments traces.
---

# DeviceLoop

DeviceLoop drives devices and simulators with Apple's `devicectl` and `simctl`, an XCUITest runner on the target and USB screen capture. The same tools work on simulators and on developer devices. Use the MCP tools when the `deviceloop` server is connected (`mcp__deviceloop__ui_tree` in Claude Code). Otherwise run the CLI with `--json`.

Fix lines, result notes and `Receipt:` lines name CLI commands and flags such as `deviceloop ui tree`, `--max-rows` or `--clear`. Over MCP, call the matching tool from the table below and pass the argument of the same name in snake case, such as `max_rows` or `clear`. Pass absolute paths to MCP tools. Relative paths resolve against the directory the server runs in.

These differ: on `run`, `--out` is `output`, `--no-media` is `media: false` and `--mask` is `screenshot_masks`, in points. `--mask` is `masks` on `video_capture`, `video_record` and `video_inspect`, in source pixels. `video capture --do` is `step`. `ui audit --type` is `types`, and `ui audit --no-screenshot` is `screenshot`, which defaults to false over MCP. `apps --system` is `include_system`. `ui alert --button` is `answer`. `screenshot --native` is `scale: "native"`. `video stop --no-analyze` is `analyze: false` and `video inspect --no-sheet` is `sheet: false`.

Screenshots, videos, contact sheets, logs, crash reports and flow results stay on the Mac under `$DEVICELOOP_HOME/artifacts` (`~/Library/Caches/deviceloop/artifacts` by default), or in the run folder while a run records. Results list the paths of the files they wrote.

## Tools

| MCP tool | CLI | For |
|---|---|---|
| `device_list`, `device_info` | `deviceloop devices`, `info` | Targets, OS, lock state, capabilities |
| `device_doctor`, `device_prepare` | `deviceloop doctor`, `prepare` | Setup problems, getting a device ready for UI tools |
| `device_view` | `deviceloop view` | Live screen in Device Hub for the person |
| `screen_capture` | `deviceloop screenshot` | Screenshot |
| `ui_tree`, `ui_find`, `ui_wait` | `deviceloop ui tree`, `ui find`, `ui wait` | Elements, refs, waiting for a state |
| `ui_tap`, `ui_type`, `ui_swipe`, `ui_drag`, `ui_press` | `deviceloop ui tap`, `ui type`, `ui swipe`, `ui drag`, `ui press` | Input |
| `ui_alert`, `ui_audit` | `deviceloop ui alert`, `ui audit` | System alerts, accessibility audit |
| `runner_status`, `runner_stop`, `device_operation` | `deviceloop runner status`, `runner stop`, `runner operation <id> --epoch <epoch>` | UI runner and its receipts |
| `flow_validate`, `flow_run`, `flow_status`, `flow_cancel`, `flow_export` | `deviceloop flow validate`, `flow run` (Ctrl-C cancels), `flow export` | Saved UI sequences |
| `app_list`, `app_install`, `app_uninstall` | `deviceloop apps [--running]`, `install`, `uninstall` | Apps |
| `app_launch`, `app_terminate`, `url_open` | `deviceloop launch`, `terminate`, `open` | App lifecycle, deep links |
| `app_logs`, `crash_list`, `crash_pull` | `deviceloop logs start`, `logs read`, `logs stop`, `crashes`, `crashes pull <name>` | Console output, crash reports |
| `app_files` | `deviceloop container`, `container pull`, `container push` | Files in the app's data container |
| `device_set`, `pasteboard` | `deviceloop location`, `appearance`, `orientation`, `pasteboard` | Settings |
| `device_state`, `state_scope`, `state_restore` | `deviceloop state inspect`, `capture`, `diff`, `scope start`, `scope status`, `restore` | Reading settings and setting them back |
| `device_siri`, `system_control`, `device_lock` | `deviceloop siri say`, `siri wifi` and the other controls, `lock` | Siri |
| `video_capture`, `video_record`, `video_inspect` | `deviceloop video capture --do <step>`, `video start`, `video stop <handle>`, `video inspect` | Animation timing |
| `trace_record` | `deviceloop trace record --app <bundle>` | Instruments trace |
| `test_run`, `test_status`, `test_cancel` | `deviceloop test run` (Ctrl-C cancels) | XCTest and Swift Testing suites |
| `run` | `deviceloop run start`, `stop`, `status`, `show`, `report`, `list`, `compare`, `export` | Recording and comparing runs |

CLI only: `deviceloop ui do`, `siri test`, `perf launch`, `perf run`, `perf compare`, `test results`, `video record`, `launch --console`, `runner start`, `run prune`, `doctor --export`, `keep-awake` and `setup`.

## Pick a target

- `device_list` lists the ready iPhones, iPads and simulators. `all: true` adds shut-down simulators, unavailable devices and other platforms, ready ones first. `ready` means connected or booted, nothing more. A device with Developer Mode off lists as `ready: true` with `developerModeEnabled: false`, and `device_doctor` names the blocker.
- `device` (CLI `--device` or `DEVICELOOP_DEVICE`) takes a UDID, a name or a unique part of it, `booted` for the booted simulator, `usb` for the cable-connected device, or `device` for any connected device. `booted`, `usb` and `device` work only when exactly one target matches.
- Leave `device` out only when exactly one target is ready. With several the call fails with `device_ambiguous` and lists the candidates, and with none it fails with `device_not_found`. `DEVICELOOP_DEVICE` in the server's environment is the default, and `device_list` gives the UDID it picks as `defaultDevice`. Nothing else carries over between calls, so pass the same `device` on every call.
- When a call acts on one target, the first line of its result names the target. Check that it is the one you meant.
- Prefer a simulator. A physical device may be someone's personal phone, so ask before installing or uninstalling apps, pushing files, reading the pasteboard or talking to Siri.
- Before UI tools on a device, call `device_prepare`. It runs the steps `device_doctor` finds missing. Relay each `needsOwner` step to the person and call again with `wait` (seconds, up to 120). Its `uiAutomation` step is not bounded by `wait`. It may build the runner and wait about 75 s for the passcode prompt, so the call can take minutes. It makes one runner start attempt. On `ui_automation_passcode`, ask the person to unlock the device and stand by for the prompt, then call it again.

## Observe, act, verify

1. Observe. `ui_tree` lists the elements on screen, system alerts first, one per line with a ref. An `other` element with no label, id, value or placeholder gets no line. It returns up to `max_rows` lines (default 200), and `screenshot: true` attaches an image. `screen_capture` returns an image at point size, so a pixel position in it is a screen point. The result has the path of the full-resolution PNG.
2. Act on one target with `ui_tap`, `ui_type`, `ui_swipe`, `ui_drag`, `ui_press` or `ui_alert`, or with `app_launch`, `app_terminate`, `url_open`, `device_set` or `pasteboard`.
3. Verify. Observe again, or call `ui_wait` until an element exists, is gone, hittable or enabled, or with `until: "stable"` until the screen stops changing. A successful call means the input was sent, not that the app reached the state you wanted.

The first `ui_*` call on a target starts the UI runner, which can take a minute. On a device it may ask for the passcode to enable UI Automation. `runner_stop` stops it. Tools that take `app` act on the app in front unless `app` names another.

Targets for `element` (`ui_tap`), `into` (`ui_type`) and `on` (`ui_swipe`):

| Form | Example | Use |
|---|---|---|
| `@<ref>` | `@e5457f2fb.1.42` | The ref that starts a line of the last `ui_tree`. |
| `id=<identifier>` | `id=login` | Accessibility identifier. Survives layout changes. |
| `label~=<text>` | `label~=Wi` | Label contains the text, ignoring case. |
| exact label | `Wi-Fi` | Any other text. |
| point | `120,640` | Screen points from a screenshot or a frame. `ui_drag` takes points only. |

- A query that matches nested elements, such as a button and the text inside it, acts on the outer one. Matches that are not nested fail with `element_ambiguous` and list up to 8 of them with their ids and frames. A query waits up to 2 s to match. Use `ui_wait` for longer waits.
- A ref goes stale after the next `ui_*` input, `ui_tree`, `ui_audit`, Siri request, rotation or change of the app in front, and then fails with `stale_ref`. Take a new tree before each ref-based input.
- `ui_tap` takes `count: 2` for a double tap and `hold_ms` for a long press.
- `ui_type` with `into` taps the field first and reports `textVerified`. A secure field is not verified and the text is not echoed, so pass `into` for passwords. `clear` empties the field first and stops with `text_mismatch` before typing when text is left.
- `ui_alert` without `answer` reads the alert. `accept` taps the one button labeled Allow, OK, Allow While Using App, Allow Full Access, Continue or Open, and `dismiss` the one labeled Don't Allow, Cancel, Not Now or Dismiss. These are English labels. Otherwise pass the exact button label as `answer`. On a location alert `accept` taps Allow While Using App.
- `ui_press` takes `home`, `volumeUp`, `volumeDown`, `action` or `camera`. A button the target lacks fails with `unsupported_on_target` and lists the ones it has. Volume buttons work on devices only.
- `device_set` with `orientation` returns `verified`. Physical iPhones report `verified: false` and stay portrait. iPads and simulators rotate.

## Flows

Use the `ui_*` tools to explore a screen. Write a flow (schema `deviceloop.flow/1`) when a sequence should run again the same way, with asserts, screenshots and cleanup, or become an XCTest UI test.

```json
{
  "schema": "deviceloop.flow/1",
  "name": "login",
  "app": {"bundleID": "com.example.app"},
  "reset": "relaunch",
  "steps": [
    {"tap": {"id": "login"}},
    {"type": {"text": "user@example.com", "into": {"id": "email"}}},
    {"assert": {"element": {"id": "welcome"}, "is": "exists"}},
    {"screenshot": {"name": "welcome"}}
  ],
  "cleanup": [{"press": {"button": "home"}}]
}
```

- Step kinds are `tap`, `doubletap`, `hold`, `swipe`, `drag`, `type`, `press`, `launch`, `open`, `sleep`, `assert`, `settle`, `screenshot` and `alert`. `press` takes `home` or `action`. A target is `id`, `label` or `labelContains` with an optional `type`, or `x` and `y`. Refs do not replay, so flows reject them.
- Flows have no Siri, location, appearance, orientation or audit steps. Call those tools before or after the flow.
- Check the flow with `flow_validate`, then run it with `flow_run` and a `path` or an inline `flow`. A run stops at the first step that does not pass, runs cleanup and saves result.json and screenshots.
- `flow_run` returns the result within 45 s, or a `run_id`. Call `flow_status` with it until the flow finishes, or `flow_cancel` to stop before the next step. Cleanup still runs.
- A failed flow is an error result. Read the failing step in `steps`, look at `failureScreenshot`, fix the flow and run it again. A step that reports `unknown`, or fails with `xctest_issue`, may have acted, so take a screenshot before the next run.
- While a flow runs, other flows and tools that use the UI runner on that device fail with `device_busy`.
- `flow_export` writes the flow as one XCTestCase class in a new .swift file at `output`. It does not replace a file or edit an Xcode project, so add the file to a UI test target. It rejects `settle`, `type` with `clear` and `reset: "reinstall"`.

## Animations and transitions

Use video, not screenshots, for questions such as "is this transition janky", "how long until the screen settles" or "does the sheet bounce".

- `video_capture` records `pre_ms` (default 300) before one `step`, runs it and keeps recording `wait_ms` (default 1500). Raise `wait_ms` for long animations.
- `video_record` with `action: "start"` returns a `handle`. Trigger the change with any tool, then `action: "stop"` with the `handle` saves and analyzes the video.
- `video_inspect` analyzes an MP4 or MOV the person recorded, for example with QuickTime.
- `trace_record` records an Instruments trace of one running `app` for `duration_ms` (default 10000, at most 60000) and summarizes hitches and potential hangs.
- `step` uses the `deviceloop ui do` grammar: `tap id=login`, `doubletap 120,640`, `hold 120,640 800`, `swipe up`, `drag 200,700 200,200`, `type "hello"`, `press home`, `launch com.example.app`, `open myapp://route` or `sleep 500`. Steps other than `launch`, `open` and `sleep` start the UI runner before recording, so its start stays out of the timing.
- A device records over USB. A device on the network fails with `unsupported_on_target`.
- `region` (`x,y,w,h` in source pixels) narrows the analyzed area and `masks` leave areas out. Mask a spinner, clock or playing video. Motion elsewhere on screen can hide a stall.

| Result | Meaning |
|---|---|
| `response.latencyMs` | From `action.sentAt` to the first change. The input lands inside `action.windowMs`, so the latency from the touch is at most this. |
| `response.feedback` | A touch-down highlight or similar small change before the transition. `latencyMs` and `animationMs` describe the transition after it. |
| `response.animationMs`, `response.lastChangeAt` | Length of the transition, and the time of the last change. |
| `response.unchangedAtEnd` | `true`, printed as `no change in the last N ms of the recording`, means the screen did not change in the last `response.observationWindowMs`, not that the app is idle. |
| `candidates.items` | Visual gap candidates from repeated or missing video frames, not from the app's frame pipeline, so they are not hitches. |
| `traceVerdict` | `confirmed` means the display showed no new surface during the gap. `notConfirmed` means it kept swapping, which can still be identical frames. Treat `inconclusive` and `unavailable` as no answer. |

- Simulator timing is not device timing. Confirm a stall on a device before reporting it.
- `video_capture` with `instruments: true` and `app` traces the app with Animation Hitches during the capture, on devices only, and fills `trace` and each candidate's `traceVerdict`. `trace.gaps` lists displayed-surface gaps inside motion, which can show a stall the video missed. `keep_trace` keeps the trace for Instruments. `pre_ms` plus `wait_ms` can be at most 50000. The call takes longer by the trace start, save and export, and needs about 7 GB of free disk with the default waits.
- `trace_record` defaults to Time Profiler, which reports potential hangs of 250 ms or more. Animation Hitches gives hitch rows and hangs over 33 ms, on devices only. It needs about 0.5 GB of free disk per second plus 1 GB. On a simulator it took 10 to 15 s longer than `duration_ms`, so keep `duration_ms` at or under 45000 when the MCP client stops tool calls after 60 s.

## Set settings back

1. Before the first setting change, open a scope with `state_scope` and `action: "start"`. `strict: true` refuses the changes DeviceLoop cannot set back.
2. Change settings. `device_set`, `system_control` and `pasteboard` `copy` journal each change, with its original value when DeviceLoop can read it.
3. `state_scope` with `action: "status"` lists the changes.
4. `state_restore` with `dry_run: true` previews the restore.
5. `state_restore` sets the changes back, newest first, and closes the scope.

| Field | What `state_restore` does |
|---|---|
| appearance, orientation | `restored` or `unchanged`, or `conflict` when something else changed the field since. `overwrite_conflicts` sets it back anyway. `needsOwnerAction` means the target was offline or locked. |
| location | The original cannot be read. `clear_location` clears the simulated location and reports `cleared`. A location set before the scope is lost. |
| `system_control` settings, pasteboard | `unsupported`. `accept_residual` closes the scope and leaves them. |

- `device_siri`, `device_lock`, `ui_*` input, `app_files` push and app installs are not journaled.
- `cleanup_incomplete` means changes are left and the scope stays open. The Detail line lists each one, and the cleanup.json named in the message holds the full report.
- `device_state` reads settings without changing them: `inspect`, `capture` to a new file, and `diff` of a capture with another one or with the live state.

## Runs and comparisons

- Call `run` with `action: "start"` (`name`, and `app` and `source` to record the app version and git commit), then the tools, then `action: "stop"`. Calls on that device in between are journaled in a run folder with their result and files, except `app_logs` `read` and `stop`, `device_prepare`, `device_state`, `device_doctor`, `flow_status`, `flow_cancel`, `test_status` and `test_cancel`. `stop` returns the report, the outcome and the path of report.html. Typed text is journaled as `[hidden]`, and a flow run saves its flow.json and result.json with it hidden.
- Stop every run you start. A run started over MCP reads `incomplete` once that server exits, and commands on the device keep recording into it until `deviceloop run stop`.
- `action: "compare"` with `baseline` and `candidate` run IDs writes comparison.json and comparison.html. Read `verdict`: `same`, `different` or `inconclusive`. It is `inconclusive` when the product type, OS build, screen, orientation, app or command sequence differ, or two compared screenshots differ in size, so record both runs on the same target with the same calls in the same order.
- Screenshots are compared only for `screen_capture` steps, not the image `ui_tree` attaches. Pass `screenshot_masks` over the status bar, for example `0,0,430,54` on a 430 pt wide screen, or the clock alone marks a screenshot changed.
- Tree differences match elements by type and id, else by type and label. Give the elements you check an accessibility id, and `ignore` the ones that change on their own.
- Timings from video steps are visual estimates from one capture each. They are reported as changed or within the floor, not as regressions.
- `action: "export"` with `id` or `comparison` copies them into the new folder `output` for a bug report, with device names, UDIDs, teams, tokens and the home path replaced and typed text and pasteboard contents hidden. Screenshots, videos and UI text are copied as recorded, so review them before sharing.

## Test jobs

- `test_run` takes one of `project` or `workspace` with `scheme`, or an `xctestrun` from `xcodebuild build-for-testing`. Narrow it with `only_testing` and `skip_testing`, which take identifiers such as `Target/Class/test()`, or with `test_plan`, which a project or workspace takes.
- It waits up to `wait_seconds` (default 45) and returns the summary, or `status: "running"` with a `job`. Call `test_status` with the `job` until it returns the result. `test_cancel` stops a job this server started, and `test_status` then reports `cancelled`. A failed or cancelled job is an error result. Cancelling the `test_run` call cancels its job.
- It fails with `device_busy` while a flow runs on the target, and while the UI runner runs unless you pass `stop_runner: true`. While a job runs, `ui_*` tools on that target fail with `device_busy`.
- On a device the tests need a signing team set in the project, or a signed `.xctestrun`, since MCP passes no build settings to xcodebuild. The CLI takes them after `--`, for example `deviceloop test run ... -- DEVELOPMENT_TEAM=<team ID>`. UI tests ask for the device passcode to enable UI Automation.
- `deviceloop perf launch` and `perf run` measure launch time and UI steps with XCTest metrics, and `perf compare` compares two jobs.

## Siri

`device_siri`, `system_control` and `device_lock` go through Siri on the UI runner and need an unlocked target. Siri can place calls, send messages and change settings, so confirm the text with the person before `device_siri`.

- `device_siri` and `system_control` return at once with a pending `operation` (`id`, `sessionEpoch`). While XCTest's Siri call holds, other runner tools fail with `device_busy`. `screen_capture` still works.
- On a device the Siri call can hold the runner for over two minutes, long after Siri answered on screen. On a simulator it takes seconds.
- Take a `screen_capture` a few seconds later to see what Siri did. Before other runner tools, poll `device_operation` with the `id` and the `sessionEpoch` as `epoch` until `phase` is `finished`.
- A finished receipt reports execution, not the effect. On iOS 27 it can carry the XCTest issue "Timed out waiting for Siri to activate" even when Siri acted. The runner keeps receipts for up to 10 minutes, so a missing receipt leaves the outcome unknown.
- `system_control` settings cannot be read back, so confirm them with a screenshot. Airplane mode over Wi-Fi drops the connection to the device.
- `device_lock` cuts off UI control until the person unlocks the device. When it returns `lockVerified: false`, do not send it again.
- The first request for an app's App Shortcut asks "Turn on '<app>' shortcuts with Siri?". Nothing runs until someone taps Turn On.
- `deviceloop siri test <scenario.json>` checks phrases against the app's App Intents entities.

## Errors

A failed call returns text that starts with `ERROR <code>`, then a `Fix:` line, and sometimes `Try:` alternatives, a `Detail:` line and a `Receipt:` line with an operation ID and epoch for `device_operation`. `(needs user)` after the code means only the person at the device or Mac can fix it. With `--json` the CLI prints `{"ok": false, "error": {...}}`, and MCP returns the same object as structured content. It has `code`, `message`, `fix`, `alternatives`, `detail`, `operationID` and `sessionEpoch` when there is a receipt, `actor` (`user` or `agent`) and `retryable`.

Some CLI commands exit nonzero without an error: `ui audit` exits 7 when issues remain, `siri test` 8 when a phrase is not verified, `flow run` and `ui do` 1 when a step fails, `test run` and `perf` 1 when tests or the build fail, and `doctor` and `prepare` 1 when a check fails or a target is not ready. `run compare` exits 0 for every verdict. Read the JSON.

`device_set` with several fields can return an error result that starts `ERROR partial: <names> failed, the rest applied`, followed by the `ERROR <code>` line of each failed field. Send only the failed fields again.

| Code | What to do |
|---|---|
| `bad_arguments` | Correct the argument the message or Fix line names. From the CLI it also means a mistyped command or option, a missing argument or a bad value. The Fix line names the closest command or option for a typo, and `Detail:` has the usage. |
| `device_not_found` | Call `device_list` with `all: true` and pass a name or UDID from it. |
| `device_ambiguous` | Pass `device` with one of the listed candidates. From a device recording it means two USB capture sources share the device name. Ask the person to rename or disconnect one. |
| `unsupported_on_target` | The target lacks the feature. Use a `Try:` alternative or another target. |
| `app_not_installed` | Check the bundle ID with `app_list`, or install the app. |
| `app_not_running` | Launch the app first. From `app_logs` `start` it means the app exited at once, and the Detail line has the crash report query to run later. |
| `app_running` | `app_files` push needs the app stopped. Call `app_terminate`, then retry. |
| `app_crashed` | `crash_pull` the report the message names. The Detail line names the saved output. |
| `element_not_found` | Take a new `ui_tree` and pick the target again, or `ui_wait` for it. |
| `stale_ref` | Take a new `ui_tree` and use a new ref. |
| `element_ambiguous` | From `ui_alert`, pass one of the listed button labels as `answer`. From an element target, pass the id of one listed match or a ref from `ui_tree`. From a flow assert, make the query match one element. |
| `element_not_hittable` | Scroll the element into view with `ui_swipe`, or dismiss what covers it. |
| `text_mismatch` | `clear` left text in the field and nothing was typed, or a `type` step with `into` in a flow or `ui do` did not read back its text. Take a new tree and empty the field another way. |
| `assertion_failed` | A flow assert found its element, but the label, value, enabled state or absence did not match by the deadline. Look at `failureScreenshot`. |
| `snapshot_failed` | Take a new `ui_tree`. |
| `audit_failed` | Bring the app to the foreground, wait for its screen, then call `ui_audit` again. |
| `intent_failed` | An App Intent or entity query failed in the app. Check the intent, entity and parameter names. |
| `device_busy` | The message names what holds the target. A flow: `flow_status` or `flow_cancel`. A test job: `test_status` or `test_cancel`. The UI runner, for `test_run`: pass `stop_runner`. Siri: poll `device_operation`. Otherwise wait a few seconds and retry once. |
| `recorder_busy` | Another recording is running, from Device Hub, QuickTime or another agent. Stop it or ask the person to. On a simulator with no other recorder, the Fix line gives a reboot command that may clear it. Ask before rebooting. |
| `runner_unreachable` | Retry once. If it fails again, call `runner_stop` and retry, then `device_doctor`. |
| `ddi_unavailable` | Call `device_prepare`, which mounts the developer disk image. |
| `dispatch_expired` | No input was sent. Retry once. |
| `timeout` | The command may have run. Observe again before retrying an action. Retry a read-only call once. |
| `action_outcome_unknown` | The input may have run. Read the `Receipt:` with `device_operation` and take a screenshot before sending it again. |
| `session_mismatch` | The runner restarted. Observe again before new input. |
| `xctest_issue` | XCTest recorded a failure, and the action may have run. Observe again before retrying. |
| `cleanup_incomplete` | `state_restore` left changes. Run it again with `clear_location`, `overwrite_conflicts` or `accept_residual`, as the Fix line says. |
| `device_error`, `runner_build_failed`, `runner_install_failed`, `internal_error` | Retrying does not help. Run `device_doctor` and report the message and Detail line. |

These need the person. Tell them the Fix line, wait until they say it is done, then retry the same call once. For pairing, Developer Mode and unlocking, `device_prepare` with `wait` waits for them. `trust_required` and `developer_mode_off` come only as `device_doctor` check codes, not as command errors.

| Code | Ask the person to |
|---|---|
| `device_offline` | Connect the cable or join the same network, and unlock the device. For a shut-down simulator the Fix line gives the boot command. |
| `device_locked` | Unlock the device. |
| `trust_required` | Unlock the device and tap Trust. |
| `developer_mode_off` | Turn on Settings > Privacy & Security > Developer Mode, restart the device and confirm. |
| `xcode_missing` | Run the command in the Fix line on the Mac. |
| `signing_no_team` | For the UI runner, sign in under Xcode > Settings > Accounts, then run `deviceloop setup --team <ID>`. For `test_run`, set the team in the project. |
| `signing_profile_failed` | Follow the Fix line: add the device to the signing team, or remove the runner builds folder it names so the runner is signed again. |
| `ui_automation_passcode` | Unlock the device and enter the passcode when it asks to enable UI Automation. The prompt waits 60 s. iPhones can ask again hours later. |
| `screen_capture_denied` | Allow DeviceLoopCapture in System Settings > Privacy and Security > Camera on the Mac. |
