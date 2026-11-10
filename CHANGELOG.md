# Changelog

## 0.1.0 - Unreleased

First release.

### CLI and MCP server

- The `deviceloop` CLI and an MCP server over stdio, `deviceloop mcp`, with the same commands for iPhones, iPads and simulators. Commands print compact text, or JSON with `--json`, and every error has a code, and a one-line fix where one applies.
- A mistyped command or option, a missing argument or a bad value fails with `bad_arguments` and exit 2, and prints the JSON error with `--json`. The fix names the closest command or option for a typo, and `help` with an unknown command fails the same way.
- `devices` names the target `DEVICELOOP_DEVICE` picks, and the MCP server names `DEVICELOOP_DEVICE` in its instructions. The MCP UI tools decode HTML entities in element targets, labels and alert answers.
- `--generate-completion-script` prints a completion script for zsh, bash or fish.
- `setup` stores the signing team and prints or runs the MCP registration for Claude Code, Codex, Cursor and Gemini CLI.
- `doctor` checks Xcode, signing, pairing, Developer Mode, connection, lock state, the developer disk image, UI Automation and the runner, with one fix per problem. `doctor --export` writes a redacted support folder for bug reports.
- `prepare` gets a device ready for UI commands: owner steps, disk image, signing team and runner, then `doctor`.
- The MCP server logs each tool call to `$DEVICELOOP_HOME/logs/mcp.jsonl`, with typed text reduced to its length.
- The agent skill in `skills/deviceloop`.
- `deviceloop --help` groups the commands by task and lists the first commands to run and the environment variables. The common commands show examples in their help.

### Devices and apps

- Commands backed by `devicectl` and `simctl`: `devices`, `info`, `view`, `screenshot`, `apps`, `install`, `uninstall`, `launch`, `terminate`, `open`, `location`, `appearance`, `orientation`, `pasteboard` and `crashes`.
- `apps --name` and the `app_list` `name` argument list only the apps whose name or bundle ID contains a text.
- `launch --console` streams an app's output. `logs start`, `read` and `stop` capture an app's stdout, stderr and os_log, or a simulator's unified log, in the background.
- `container list`, `pull` and `push` list the files in an app's data container, copy one to the Mac, or copy one in.

### UI automation

- An XCUITest runner that DeviceLoop builds, signs and starts on the target. `runner start`, `stop`, `status` and `operation` manage it and read its operation receipts.
- DeviceLoop reuses a running runner only when it answers with the session epoch recorded at its start. Any other reply at that address fails with `runner_unreachable` while the recorded process runs, and the session is discarded once that process has exited.
- The runner checks the token and the `Origin` header as soon as a request's headers arrive, before it reads the body, and closes a connection that has not sent its headers within 5 s.
- `ui tree`, `tap`, `swipe`, `drag`, `type`, `press`, `find`, `wait`, `alert` and multi-step `ui do`, on points, refs from `ui tree` with or without `@`, identifiers or labels.
- A label or query that matches nested elements, such as a button and its text, acts on the outer one, and element actions wait up to 2 s for a query to match. Matches that are not nested fail with `element_ambiguous` and are listed.
- A tap on a switch row, such as a SwiftUI `Toggle`, taps the switch inside it. A tap on an element with an empty frame, or whose center is outside the app's frame, fails with `element_not_hittable` before any input. A query that also matches copies with an empty frame, such as an icon on a Home Screen page that is not showing, acts on the one on screen.
- An unknown `ui swipe` direction or `ui press` button fails with `bad_arguments` before the runner starts.
- `ui find` lines show each element's value.
- `ui tree`, `find`, `alert` and `type` text print newlines, tabs, backslashes, other control characters and bidi controls in labels, ids, values and alert text as `\n`, `\r`, `\t`, `\\` or `\u{1B}`, so each element stays on one line and reads in order. A label copied from that text matches its element in `ui` commands and flows. `--json` results keep the strings as the app reports them.
- `ui tree` text leaves out `other` elements with no label, id, value or placeholder. `--json` keeps every node.
- A `ui do` type step into a field fails with `text_mismatch` when the field does not read back the typed text, as in a flow.
- `ui audit` runs XCTest's accessibility audit on the screen in front, with a suppression file for accepted issues.
- `keep-awake` sends periodic taps to an inert app point you choose.

### Siri

- `lock`, `siri say` and the system controls `siri wifi`, `bluetooth`, `lowpower`, `dnd`, `airplane`, `brightness` and `volume`, through Siri.
- `siri test` runs a scenario of Siri phrases against an app and checks the entities they change.
- `siri say --expect` takes `id=`, `label~=` or an exact label, as `ui tap` does.

### Flows

- `flow validate`, `flow run` and `flow export` check, run and export saved `deviceloop.flow/1` files. Export writes an XCTest UI test.

### Runs

- `run start`, `stop`, `status`, `show`, `report`, `list`, `prune`, `compare` and `export` record the commands sent to a device into a run folder with a `report.html`.
- `run compare` compares two runs step by step: outcomes, UI trees, screenshots, and the latency, animation, last change and visual gap times of video captures.
- `run export` copies a run or a comparison for a bug report, with device names, UDIDs, teams, tokens and the home path replaced by aliases.
- Runs hide typed text as `[hidden]` in the journal, `perf run` steps included, and in the `flow.json` and `result.json` of a flow run.
- A failed or cancelled `ui do`, `flow run` or `flow_run`, and a command that exits non-zero or an MCP tool that returns an error result, fails the run that records it.

### Device state

- `state inspect`, `capture`, `diff`, `scope` and `restore` read, save and compare identity and settings, and journal the setting changes DeviceLoop makes so `restore` can set them back. `capture` does not replace an existing file.

### Tests and performance

- `test run` and `test results` run XCTest and Swift Testing suites with xcodebuild and summarize the result bundle.
- `perf launch`, `perf run` and `perf compare` measure launch time and UI steps with XCTest metrics, and compare two jobs.
- `trace record` records an Instruments trace of one running app with xctrace.

### Video

- `video record`, `start`, `stop`, `capture` and `inspect` record the screen of a simulator, or of a device over USB, and report motion, the last change, visual gap candidates and a contact sheet.
- `video capture --instruments` checks each gap candidate against an Animation Hitches trace on a device.
- `video record -o` does not replace an existing file or folder.

### MCP tools

- Devices and apps: `device_list`, `device_info`, `device_doctor`, `device_view`, `device_prepare`, `screen_capture`, `app_list`, `app_install`, `app_uninstall`, `app_launch`, `app_terminate`, `url_open`, `device_set`, `pasteboard`, `crash_list`, `crash_pull`, `app_logs` and `app_files`.
- UI automation: `ui_tree`, `ui_tap`, `ui_type`, `ui_swipe`, `ui_drag`, `ui_press`, `ui_find`, `ui_wait`, `ui_alert`, `ui_audit`, `runner_status`, `runner_stop` and `device_operation`.
- Siri: `device_lock`, `system_control` and `device_siri`.
- Video and traces: `video_record`, `video_capture`, `video_inspect` and `trace_record`.
- Device state: `device_state`, `state_scope` and `state_restore`.
- Flows: `flow_validate`, `flow_run`, `flow_status`, `flow_cancel` and `flow_export`.
- Tests: `test_run`, `test_status` and `test_cancel`, as background jobs.
- Runs: `run`.
- Tools that delete data or change settings DeviceLoop cannot set back, such as `app_uninstall`, `pasteboard`, `device_set` and `state_restore`, have `destructiveHint` set.
- Tool arguments are snake case. A failed flow, a failed or cancelled test job, and a `device_set` call with a failed setting return an error result.

### Distribution

- `make dist` and the release workflow build a signed and notarized arm64 tarball with the capture helper, the runner project and the agent skill.
- A Homebrew formula for `argmaxinc/homebrew-tap` is staged in `Packaging/Formula`. The tap is not published yet, so install DeviceLoop by building from source.
