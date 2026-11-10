# DeviceLoop

DeviceLoop is a command line tool and MCP server that drives iPhones, iPads and simulators with the same commands, the way `simctl` drives a simulator. It runs Apple's developer tools on your Mac: `xcrun devicectl`, `xcrun simctl`, an XCUITest runner signed with your team, and AVFoundation for screen video over USB. Commands print compact text, or JSON with `--json`, and agents get the same commands as MCP tools.

https://github.com/user-attachments/assets/0a291a4e-6d95-4175-895f-91ce700f9796

## Install

DeviceLoop needs a Mac with Apple silicon, macOS 26.6 or later, and Xcode 27 or later.

```bash
git clone https://github.com/ZachNagengast/deviceloop.git
cd deviceloop
xcrun swift build -c release --product deviceloop
mkdir -p ~/.local/bin
ln -s "$(xcrun swift build -c release --show-bin-path)/deviceloop" ~/.local/bin/deviceloop
~/.local/bin/deviceloop setup
```

Put `~/.local/bin` on `PATH`, or link into another folder on it. Keep the checkout, since DeviceLoop builds its UI runner from `Runner/`. A simulator needs no setup. A device needs iOS 17 or later, pairing, Developer Mode and an Apple developer team in Xcode, and `deviceloop prepare --device <udid>` walks through them.

## Quick start

Pick a simulator from `deviceloop devices --all`, boot it and make it the default target:

```bash
deviceloop devices --all
xcrun simctl bootstatus <udid> -b
export DEVICELOOP_DEVICE=<udid>
deviceloop screenshot
deviceloop launch com.apple.Preferences
deviceloop ui tree
deviceloop ui tap General
```

`bootstatus -b` boots the simulator if it is shut down and waits until it is ready. Without `DEVICELOOP_DEVICE` or `--device`, a command fails with `device_ambiguous` when more than one target is ready, such as two booted simulators or a simulator and a connected phone. The first `ui` command builds and starts the UI runner, which can take a minute.

[Examples/Sample](Examples/Sample) is a small app to try the commands on.

## Use with agents

```bash
claude mcp add -s user deviceloop -- ~/.local/bin/deviceloop mcp
```

`deviceloop setup` prints this command for Claude Code, Codex, Cursor and Gemini CLI. [skills/deviceloop](skills/deviceloop/SKILL.md) is the agent skill.

## Docs

- [Reference](docs/reference.md): device setup, every command and MCP tool, animation analysis, limits on real devices, the files DeviceLoop writes, upgrading and uninstalling.
- [docs](docs/README.md): architecture, `simctl` parity, Siri, device state and how DeviceLoop is tested.
- [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
