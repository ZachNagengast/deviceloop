# Parity with simctl and Xcode

This page maps `xcrun simctl` commands and Xcode's device features to DeviceLoop, on simulators and on devices. Backends were measured with Xcode 27.1 on Oct 22nd, 2026 and Xcode 27.2 on Nov 8th, 2026, on the [test devices](validation.md#device-checks) and on simulators with iOS 26.5, 27.0 and 27.1.

## How DeviceLoop routes a command

- `devicectl` lists and drives simulators as well as devices, so most commands use one devicectl path for both.
- Each target reports CoreDevice capabilities, for example `com.apple.coredevice.feature.capturescreenshot`. A call the target does not support fails in about 0.2 s with CoreDevice error 1001. DeviceLoop turns that into `unsupported_on_target` with the missing capability in `detail`.
- `simctl` covers simulator-only paths. The UI runner covers the screen, input, audits and Siri. Host tools cover the rest: AVFoundation for device screen video, xcodebuild and xctrace for tests and traces, and the Mac's crash report folder for simulators.

Some capabilities differ by OS version. The iPhone on iOS 18.7.8 lacks `customizeappearancesettings`, so devicectl cannot set text size, contrast or reduce motion there, while light and dark mode work. `deviceloop info` lists each capability of a target with its status and a reason.

MCP tools call the same commands. [`skills/deviceloop/SKILL.md`](../skills/deviceloop/SKILL.md) maps each tool to its command. `runner operation` and the `device_operation` tool, which read [receipts](architecture.md#operations) from the UI runner, have no simctl equivalent.

## Parity table

The Now column says whether this build has the feature. Planned means a later release, listed in the [roadmap](roadmap.md). Not possible means Apple's developer tools have no device path.

| simctl or Xcode | deviceloop | Simulator | Device | Now |
|---|---|---|---|---|
| `list` | `devices` | `devicectl list devices` | same | yes |
| `io enumerate`, `io poll` | `info` | `devicectl device info displays` | same | yes |
| Device readiness in Xcode | `doctor`, `prepare` | boot state | pairing, Developer Mode, connection, tunnel, lock, disk image, UI Automation | yes |
| Pairing in Xcode | `prepare --pair` | not applicable | `devicectl manage pair`, then Trust on the device | yes |
| `boot` | none | `simctl boot` | no boot command. `prepare` waits for the owner steps and mounts the disk image | planned on simulators |
| `shutdown` | none | `simctl shutdown` | not possible | planned on simulators |
| `erase` | none | `simctl erase` | not possible. `resetContentAndSettings` is simulator-only | planned on simulators |
| `create`, `clone`, `delete`, `upgrade` | none | simctl | not possible | planned on simulators |
| `rename` | none | `devicectl device rename` | same | planned |
| `reboot` | none | `simctl reboot` | `devicectl device reboot` | planned |
| Live screen in Device Hub | `view` | Device Hub | Device Hub | yes |
| `listapps` | `apps` | `devicectl device info apps` | same | yes |
| `appinfo` | `apps` | `devicectl device info apps` | same | partial, no full Info.plist |
| Running and foreground apps | `apps --running` | `simctl spawn <udid> launchctl list`, foreground from the UI runner | `devicectl device info processes`, foreground from the UI runner | yes |
| `install` | `install` | `devicectl device install app`, then reads the installed version and build back | same | yes |
| `uninstall` | `uninstall` | `devicectl device uninstall app` | same | yes |
| `launch` | `launch` | `devicectl device process launch` | same | yes |
| `launch --console-pty` | `launch --console`, `logs start` | `devicectl device process launch --console` | same | yes |
| `terminate` | `terminate` | `simctl terminate` | pid from `info processes`, then `devicectl device process terminate` | yes |
| `openurl` | `open` | `devicectl device process openURL` | same | yes |
| `get_app_container` | `container`, `container pull` | `simctl get_app_container` and the Mac file system | `devicectl device info files` and `copy from` with `appDataContainer`, for development-signed apps | yes |
| `install_app_data` | `container push` | file copy into the container | `devicectl device copy to` with `appDataContainer` | single files |
| `addmedia` | none | `simctl addmedia` | import from the runner host app | planned |
| `io screenshot` | `screenshot` | `devicectl device capture screenshot`, or `simctl io screenshot` when it fails | `devicectl device capture screenshot` | yes |
| `io recordVideo` | `video record`, `video start`, `video stop` | `simctl io recordVideo` of the display `screenshot` captures | AVFoundation over USB, as [screen video](architecture.md#screen-video) describes. `devicectl device capture screen-record` is simulator-only | yes |
| `io screenConfig` | none | simctl | not possible | not planned |
| Animation analysis | `video capture`, `video inspect` | AVFoundation on the Mac | same | yes, `--instruments` on devices only |
| Instruments traces | `trace record` | `xctrace record --device <udid> --attach <pid>`, then `xctrace export`. No Animation Hitches | same | yes |
| UI tree, tap, swipe, drag, type, hardware buttons | `ui` | UI runner | UI runner. Volume buttons work only on devices | yes |
| System and app alerts | `ui alert` | UI runner | UI runner | yes, `accept` and `dismiss` know English labels only |
| Accessibility audit | `ui audit` | XCTest `performAccessibilityAudit` through the runner | same | yes, the screen in front only |
| Saved UI flows | `flow validate`, `flow run`, `ui do` | UI runner | UI runner | yes |
| XCTest export | `flow export` | a generated XCTestCase for the app's UI test target | same | yes, for a subset of flow steps |
| `ui appearance` | `appearance` | `devicectl device settings appearance --mode` | same | yes |
| `ui increase_contrast`, `ui content_size` | `state inspect` reads them | `devicectl device settings appearance` | same, needs `customizeappearancesettings` | read yes, set planned |
| Rotate | `orientation` | `devicectl device orientation set`, read back | same. Physical iPhones stay portrait and report `verified: false`, iPads rotate | yes |
| `location set`, `location clear` | `location <lat,lon>`, `location clear` | `devicectl device simulate location` | same | yes, with the [limits](device-state.md#limits) of device state |
| `location run`, `location start` | none | `devicectl device simulate location route` | same | planned |
| `pbcopy`, `pbpaste` | `pasteboard copy`, `pasteboard paste` | `devicectl device pasteboard copy` and `paste` | same | yes. Copy replaces the contents without saving them, and the Mac pasteboard is not read or written |
| `pbsync` | none | `devicectl device pasteboard sync-with-host` | same | planned |
| `status_bar` | `state inspect` reads overrides | `simctl status_bar list`, set with `devicectl device simulate statusBar` | not possible | read yes, set planned on simulators |
| `privacy` | none | `simctl privacy` | reset from the UI runner, grant by accepting the system prompt | planned |
| `push` | none | `simctl push` | APNs sandbox with your key and the app's device token | planned |
| `keychain add-root-cert`, `keychain add-cert` | none | `simctl keychain` | `devicectl device profile install`, then trust in Settings | planned |
| `keychain reset` | none | `simctl keychain reset` | not possible | planned on simulators |
| Face ID and Touch ID | none | `devicectl device simulate biometrics` | not possible | planned on simulators |
| VoiceOver | `state inspect` reads it | `devicectl device settings voiceover` | same | read yes, set planned |
| Settings snapshot and restore | `state inspect`, `capture`, `diff`, `scope`, `restore` | devicectl and simctl reads | devicectl reads, without volume | yes, restores appearance and orientation. See [device state](device-state.md) |
| Wi-Fi, Bluetooth, Low Power Mode, Do Not Disturb, Airplane Mode, brightness, volume | `siri wifi`, `bluetooth`, `lowpower`, `dnd`, `airplane`, `brightness`, `volume` | Siri through the UI runner | same | yes, not read back. See [Siri](siri.md) |
| Lock the screen | `lock` | not applicable | Siri, then `devicectl device info lockState` | devices |
| Siri requests and App Intents | `siri say`, `siri test` | XCTest `XCUISiriService`, AppIntentsTesting where it loads | same | yes. See [Siri](siri.md) |
| Crash reports | `crashes`, `crashes pull` | `~/Library/Logs/DiagnosticReports` on the Mac | `devicectl` `systemCrashLogs` domain | yes |
| `spawn <udid> log stream` | `logs start --system` | `simctl spawn <udid> log stream --style ndjson` | `xctrace record --template Logging`, no sudo | simulator yes, device planned |
| `spawn` | none | `simctl spawn` | launch by path only. System tools such as `log` do not run on devices | planned |
| `diagnose` | none | `simctl diagnose` | `devicectl device sysdiagnose` | planned |
| Run tests in Xcode | `test run`, `test results` | `xcodebuild test` or `test-without-building`, read with `xcresulttool` | same | yes |
| Performance tests | `perf launch`, `perf run`, `perf compare` | XCTest metrics in a finite run of the UI runner | same | yes. CPU and memory metrics report the app process, not the measured steps |
| Test reports in Xcode | `run`, `run compare`, `run export` | run journal on the Mac | same | yes |
| Fold posture | none | no documented control | not applicable | planned once a documented control exists |
| Remote devices | none | | | planned |
| Thermal and network conditions | none | | | planned after a documented control is found |
| `logverbose` | none | `simctl logverbose` | logging profiles through `devicectl device profile install` | not planned |
| `getenv` | none | `simctl getenv` | not possible | not planned |
| `icloud_sync` | none | `simctl icloud_sync` | not possible | not planned |
| `pair`, `pair_activate`, `unpair` | none | simctl | `devicectl device pairings` manages watch pairings | not planned |
| `personalization`, `runtime` | none | simctl | not applicable | not planned |
