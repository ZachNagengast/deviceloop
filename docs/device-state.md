# Device state

DeviceLoop reads a target's identity and settings into a snapshot, compares snapshots, and journals the setting changes it makes so that `state restore` can set them back. It covers the settings DeviceLoop itself changes. It is not a backup, a file system snapshot or a rollback of app data, accounts or anything a person or another tool changed.

## Snapshots

`state inspect`, `state capture` and `state diff` read every field the target supports, in parallel. A capture is a `deviceloop.device-state/1` JSON file with mode 0600. `state capture -o` and the `device_state` `capture` action fail with `bad_arguments` when the file already exists. Each field records:

- `value`, set only when the field was observed
- `availability`: `observed`, `unknown` (no source, or the read failed), `unsupported` (the target lacks the capability) or `unavailable` (the target is offline or locked)
- `reason` when the value was not observed
- `source`, the command the value came from, and `observedAt`
- `scope` (`device` or `simulator`), `mutability` (`readOnly` or `settable`), `sensitivity` and `restorable`

A value DeviceLoop could not read stays unknown. It does not turn into false, zero or a default.

| Field | Source | Restore |
|---|---|---|
| `name`, `model`, `productType`, `osVersion`, `osBuild`, `ready`, `connection` | `devicectl list devices` | read-only |
| `lockState` | `devicectl device info lockState` | read-only |
| `ddiUsable` | `devicectl device info ddiServices --no-auto-mount-ddis` | read-only |
| `userInterfaceStyle` | `devicectl device info appearance` | restored |
| `textSize`, `largerAccessibilitySizesEnabled`, `increaseContrast`, `reduceMotion`, `reduceTransparency`, `showBorders`, `colorFilter` | `devicectl device info appearance` | no setter yet. `colorFilter` records only whether a filter is on, not its type |
| `orientation` | `devicectl device orientation get` | restored |
| `voiceOver` | `devicectl device info voiceover` | no setter yet |
| `volume` | `devicectl device info audio` | no setter yet. Devices do not list the `audiooutput` capability, so it reads as unsupported there |
| `statusBarOverrides` | `simctl status_bar list`, simulators only | read-only. Values are the lines simctl prints, so some are enum numbers such as `DataNetworkType: 1` |
| `location` | none, devicectl and simctl cannot read the simulated location | can be cleared, not restored |
| `pasteboard` | none, DeviceLoop does not capture the contents | not restored |
| `battery`, `thermalState`, `lowPowerMode` | none, devicectl and simctl do not report them | not restored |

An iPad Air on iPadOS 26.6.2 reported every appearance key. Whether iOS 18 reports the accessibility keys is an [open question](validation.md#open-questions).

## Scopes and the change journal

`state scope start` captures a baseline and opens a write-ahead journal, `state/<udid>/changes.jsonl`. The MCP tool is `state_scope`. While the journal exists, these commands journal every change they make:

- `appearance`, `orientation` and `location`, and the MCP tool `device_set`
- `pasteboard copy`, and the `pasteboard` tool
- `siri wifi`, `bluetooth`, `lowpower`, `dnd`, `airplane`, `brightness` and `volume`, and the `system_control` tool

For each change, under `state/<udid>/scope.lock`, the command reads the field, appends a `change` line with the original and requested values and syncs it to disk, runs the setter, re-reads the field and appends an `applied` line. A crash between the two lines leaves a change with no applied line, which restore still handles.

Location, the Siri controls and pasteboard copy have no getter or no inverse. They are journaled with the original and applied values unknown and a reason. Pasteboard copy records the character count, not the text. A scope started with `--strict` refuses these changes before any device or runner call, with `unsupported_on_target`. Appearance and orientation are journaled in a strict scope too.

A scope journals only DeviceLoop's setting commands. `siri say`, `lock`, UI input, installs and `container push` are not journaled, and a strict scope does not refuse them. A setting command that starts while another process is opening a scope can run without a journal entry.

## Restore

`state restore` walks the open scope newest first, re-reads each field and gives each change one outcome:

| Outcome | Meaning |
|---|---|
| `restored` | the inverse setter ran and a re-read returned the original |
| `unchanged` | the field holds its original and DeviceLoop's last journaled value for the change was the original too, so no setter ran |
| `conflict` | the field differs from what DeviceLoop last set, so it is left as it is. A change made outside DeviceLoop back to the original is a conflict too, and so is every older change of the same field |
| `unknown` | the original was not observed, or the current value could not be read |
| `unsupported` | DeviceLoop has no inverse for the field |
| `cleared` | `--clear-location` cleared the simulated location |
| `needsOwnerAction` | the target is offline or locked |
| `failed` | the setter failed, or the re-read returned something else |
| `wouldRestore` | `--dry-run` only: the setter would run |

Restore checks that the journal's baseline names the same UDID before it reads anything. Each inverse appends its own `applied` line, so a second restore reports a restored change as `unchanged`. Restore writes `state/<udid>/cleanup.json` with every outcome.

The scope closes when every change is restored, unchanged or cleared, or with `--accept-residual`. The journal then moves to `changes-<scope start time>.jsonl` in the same folder. Otherwise restore fails with `cleanup_incomplete` and exit 7, lists each change left in place and keeps the scope open. `--overwrite-conflicts` sets conflicting fields back anyway. Captures, `cleanup.json` and closed journals stay in `state/<udid>/` until you delete them.

`doctor` warns about an open scope with pending changes on any target devicectl still lists, including a shut-down simulator, and `state inspect` lists the pending changes.

## Limits

- Re-reading before restore catches most outside changes, but not a change away and back between the read and the setter. Restore is not atomic.
- DeviceLoop cannot put back a simulated location set before the scope. `location clear` also clears a location another tool set.
- A line torn by a crash in the middle of a write blocks `state scope status`, `state restore` and `doctor` for that target.
- A scope left on a deleted simulator stays in `state/<udid>/changes.jsonl`.
