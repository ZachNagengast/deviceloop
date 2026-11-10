# Security

## Reporting a vulnerability

Report vulnerabilities privately through [GitHub private vulnerability reporting](https://github.com/ZachNagengast/deviceloop/security/advisories/new), not in a public issue. Include the DeviceLoop version (`deviceloop --version`), the macOS, Xcode and iOS versions, and the steps to reproduce.

## Threat model

DeviceLoop runs as your macOS user and drives your own devices and simulators through Xcode's tools. Any process that runs as your user can read what DeviceLoop stores.

Other accounts on the Mac can read the command line of your processes with `ps`. Launch environment variables from `launch --env`, `logs start --env` and the `env` argument of the MCP `app_launch` and `app_logs` tools go on the `devicectl` command line, so they can be read while devicectl runs: a few seconds for `launch`, and until the app exits for `launch --console` and `logs start`. Pass secrets to the app another way, for example in a file you copy into its container with `container push`.

Some commands leave work running after they return: the UI runner until `deviceloop runner stop`, a `video start` recording until `video stop`, and a `logs start` capture until `logs stop`. The runner's host app disables the idle timer, so the device does not auto-lock while that app is in front.

## What DeviceLoop stores

DeviceLoop creates its folders under `DEVICELOOP_HOME` readable only by you (0700) and writes session, state and log files as 0600. [Privacy and data on disk](docs/reference.md#privacy-and-data-on-disk) lists what each folder holds and how long it stays.

These files hold secrets or text you typed:

- `sessions/<udid>/session.json` holds the runner's address, port and token.
- Each runner start writes a `run-<UUID>.xctestrun` file next to the runner build in `runner/`. It passes the token to the runner. `deviceloop runner stop` deletes it and `session.json`.
- `sessions/<udid>/startup-*/xcodebuild.log` keeps the Siri phrases and typed text that XCTest logs. `doctor --export --include-runner-logs` hides them in the log tail it adds to the export.
- A `perf run` job keeps the text of its type steps in `result.xcresult` and `xcodebuild.log`. While a run records, the job is in that run's `artifacts/`, and `run export` does not hide the text there.
- A flow run keeps its flow, typed text included, in `flow.json`, unless a run records on the device.
- A run in `runs/` journals typed, Siri and pasteboard text as `[hidden]` and saves no pasteboard results.
- Screenshots, videos and UI trees keep whatever the screen showed.

## Runner token and network

UI commands start an XCUITest runner on the target. The runner serves plain HTTP on the CoreDevice tunnel address of a device, or on `::1` for a simulator, at a port the system picks. It does not listen on the device's other addresses.

The runner answers only requests that carry its bearer token, rejects requests with a browser `Origin` header, and takes only JSON POST bodies. Each runner start makes a new token from 32 random bytes. Any process running as your user can read the token and drive the target through the runner. For a simulator, CoreSimulator also logs the runner's launch environment, token included, to `~/Library/Logs/CoreSimulator/CoreSimulator.log`. That file is 0644 inside your 0700 `~/Library` folder. `deviceloop runner stop` ends the runner, and the token with it.

## What leaves the Mac

DeviceLoop sends no telemetry. It connects to its runner and, through Xcode's tools, to your devices. To sign the runner for a device, xcodebuild contacts Apple and registers the device with your signing team when it is not registered yet. Command output, such as screenshots, UI trees and pasteboard text, goes to the agent that called DeviceLoop, and that agent may send it to its model provider. Nothing else leaves the Mac.

## MCP activity log

[Activity log](docs/reference.md#activity-log) lists what each MCP tool call writes to `$DEVICELOOP_HOME/logs/mcp.jsonl` and which text it logs only as a length. Other arguments are logged as passed, including launch arguments, URLs and file paths.
