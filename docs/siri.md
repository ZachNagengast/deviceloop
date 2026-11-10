# Siri and App Intents

The UI runner reaches Siri through XCTest's `XCUISiriService.activate(voiceRecognitionText:)`, which hands Siri text as if it were recognized speech. It tests what Siri and an app do with a request. It does not test the microphone, the wake word or speech recognition.

Some system actions have no devicectl, simctl or XCTest API, such as locking the screen or turning on Low Power Mode. DeviceLoop reaches them through Siri. The device must be unlocked with Siri enabled.

## Commands

- `siri say "<text>"` sends any request. It returns once the runner accepts it. `--wait` waits for XCTest's call to return and prints its receipt and XCTest issues. `--expect` then looks for an element in the app in front, or in `--app`, and sets `verified`. It takes `id=<id>`, `label~=<text>` or an exact label, as `ui tap` does.
- `lock` asks Siri to lock the screen, then polls `devicectl device info lockState` for up to `--verify-seconds` and sets `lockVerified` when it reports `passcodeRequired`. A device with no passcode does not report it. Only the person at the device can unlock it. A simulator has no lock screen, so `lock` fails there with `unsupported_on_target`.
- `siri wifi`, `bluetooth`, `lowpower`, `dnd` and `airplane` take `on` or `off`, and `siri brightness` and `volume` take 0 to 100. They do not read the setting back, and a [state scope](device-state.md#scopes-and-the-change-journal) journals them with unknown values. Airplane Mode over Wi-Fi drops the connection to the device.
- `siri test <scenario.json>` sends phrases to an app and checks what each one did, described below.

The MCP tools are `device_siri`, `device_lock` and `system_control`. `siri test` has no tool yet, because one scenario can hold a tool call for minutes per phrase on an iOS 27 iPhone.

## How a request runs

The runner accepts a Siri request with HTTP 202 and a receipt, and holds its one admission slot until XCTest's call returns. Until then UI commands get `device_busy`, and screenshots and other devicectl or simctl commands still work. The call can return long after Siri acted:

| Target | Xcode | XCTest call | XCTest issues |
|---|---|---|---|
| iPhone 15 Pro Max, iOS 27.0 | 27.1 | 130 to 134 s | "Timed out waiting for Siri to activate", "Application 'com.apple.siri' has not loaded accessibility" |
| iPhone 15 Pro Max, iOS 27.2 | 27.2 | 130 to 142 s | the same two |
| iPhone 13 Pro, iOS 18.7.8 | 27.1 | 0.5 s | none |
| iPad Air, iPadOS 26.6.2 | 27.1 | 0.4 s | none |
| iPhone 15 Pro Max simulator, iOS 27.0 | 27.2 | 4.8 s for the first request, 4 to 91 ms after | none |

On the iOS 27 iPhone, Siri's answer was on screen within about 7 s of the request. The simulator does not reproduce the long hold.

`siri say --wait` waits up to 180 s by default. When the wait runs out, DeviceLoop reports `action_outcome_unknown` with the receipt, which `deviceloop runner operation` reads later. A finished receipt means XCTest returned, not that the request did what was asked. `siri say --wait` and `--expect` exit 0 once the receipt finishes, even with XCTest failures or an unmet expectation, and report the result in `verified` and `issues`. `lock` exits 0 when it cannot confirm the lock and reports it in `lockVerified`.

A Siri request invalidates refs from an earlier `ui tree`. After Siri dismisses, the app in front can be Siri itself (`com.apple.siri` on the simulator).

## Phrase scenarios

A `siri test` scenario names an app, its phrases and the entity each phrase should create:

```json
{
  "app": "com.example.MyApp",
  "reset": {"intent": "ResetTasksIntent"},
  "phrases": ["Add milk in MyApp"],
  "expect": {"entity": "TaskEntity", "matching": "milk", "property": "title", "equals": "Milk", "count": 1}
}
```

`seed` runs intents after each reset. `timeoutS` is the receipt wait per phrase (default 180 s, at most 3600), `settleS` the shortest time from Siri accepting a phrase to the after screenshot and read-back (default 10 s, at most 600), and `requiredLanguage` is checked against the device's first language before any phrase is sent. Unknown fields are rejected.

For each phrase, `siri test` runs the reset intent and the seeds where AppIntentsTesting loads, takes a screenshot, sends the phrase, takes a screenshot every 5 s while XCTest's call runs and one after the settle time, then reads the result one of two ways:

- Entity: where AppIntentsTesting loads, it runs the entity's string query for `matching` and compares the property and count. It loaded on an iPhone 15 Pro Max with iOS 27.2 and Xcode 27.2, and not on iOS 27.0.
- UI: elsewhere it brings the app to the front and counts labels that contain `matching`. The reset intent does not run, so counts include items left by earlier phrases and runs, and a title shown in two elements counts twice. A scenario with `seed` fails there with `unsupported_on_target`.

Each phrase is `verified`, `missing`, `wrong_entity`, `duplicate`, `unverified` or `uncertain`. The command saves `report.json` and the screenshots, and exits 8 when a phrase is not verified or was not sent. A lost connection stops the scenario without sending anything again. Another error after a phrase stops the scenario, saves `report.json` and exits with that error. Cleanup runs the reset intent only, and only where AppIntentsTesting loads.

Measured on an iPhone 15 Pro Max with iOS 27.2:

- The first request for a freshly installed app's App Shortcut asks "Turn on '<app>' shortcuts with Siri?". Nothing runs until someone taps Turn On, and `siri test` reports the phrase `missing` without naming the dialog.
- `allEntities()` fails for an `EntityStringQuery` with "Type does not support EnumerableEntityQuery", so scenarios need `matching`.
- An unknown intent name fails with `intent_failed`, and the runner stays up.

## App Intents routes

The runner has two routes that use AppIntentsTesting on iOS 27.0 and later. No CLI command or MCP tool calls them directly yet. `siri test` uses them for reset, seed and read-back.

- `POST /v1/intents/run` with `{"app", "intent", "params"}` runs an intent. A parameter is a JSON string, number or Boolean, or `{"entity": "<type>", "id": "<identifier>"}` for an entity. A whole number is passed as an `Int` and any other number as a `Double`.
- `POST /v1/intents/entities` with `{"app", "entity", "matching", "properties"}` runs the entity's string query for `matching`, or `allEntities()` without it, and returns each entity's `id` and the requested `String` properties.

Both fail with `unsupported` below iOS 27.0 or when AppIntentsTesting does not load, which DeviceLoop reports as `unsupported_on_target`, and with `intent_failed` when the intent or query throws. A lost connection during a run is `action_outcome_unknown` and the intent is not sent again. Running an intent invalidates refs from the last tree, and an entity query does not.

The Siri fixture app in `Runner/SiriFixture` has `AddFixtureTaskIntent`, `ResetFixtureTasksIntent`, the entity `FixtureTaskEntity` and two App Shortcut phrases. [scripts/README.md](../scripts/README.md) describes how to build it and run `smoke-siri.py`.

## Language

The runner's `/v1/info` reports `preferredLanguages` and `locale` from the global preferences of the device. On an iOS 27.0 simulator they matched `AppleLanguages` and `AppleLocale`, and followed a change to French after a runner restart. Whether they match Settings on a device is an [open question](validation.md#open-questions).
