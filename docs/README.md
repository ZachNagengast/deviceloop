# DeviceLoop design docs

These pages describe how DeviceLoop works, what it covers and how it is tested. The [reference](reference.md) lists every command.

- [Architecture](architecture.md): the command layer, the XCUITest runner over the CoreDevice tunnel, USB screen capture, the MCP server, the run journal and the measured limits behind them.
- [Parity](parity.md): `simctl` and Xcode features mapped to DeviceLoop on simulators and devices.
- [Device state](device-state.md): snapshots of a target's settings, the change journal and `state restore`.
- [Siri and App Intents](siri.md): Siri requests, system controls through Siri, phrase scenarios and the App Intents routes.
- [Validation](validation.md): host tests, simulator smoke tests, device checks, measured results and open questions.
- [Roadmap](roadmap.md): remote devices and other planned work.
- [Evidence](evidence/): sanitized summaries of the simulator and device runs that [validation](validation.md) cites.
