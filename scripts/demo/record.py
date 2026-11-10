#!/usr/bin/env python3
# For licensing see accompanying LICENSE file.
# Copyright 2026 Argmax, Inc. All rights reserved.

"""Runs a demo script against one device while recording its screen, and writes a timeline for render.swift.

Usage:
  python3 scripts/demo/record.py --binary .build/release/deviceloop --device <UDID> \\
      --script scripts/demo/demo.json --out .build/demo

The script is JSON: {"steps": [...]} where each step is one of
  {"chapter": "What you can do"}   title shown above the terminal
  {"caption": "Taps by label"}     line shown under the terminal
  {"run": "deviceloop ui tap Wi-Fi"} command typed, run and shown with its output, line by line as it arrives
  {"run": "claude -p ...", "exec": ["python3", "scripts/demo/agent.py", "--binary", "{binary}", "..."]}
                                   shows `run` and runs `exec` instead, with {binary} replaced
  {"pause": 1.5}                   seconds of idle screen
{team} in a command runs as the --team value and shows as <team>.
Device names in output are replaced with the model name, UDIDs with <udid>, the --team value with <team>, other
UUIDs with their first 8 characters, the clock time in local and UTC timestamps with <time>, and the home directory
with ~.
"""
import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

TYPING_CHARS_PER_SECOND = 40
LOCAL_TIME = re.compile(r"\b(\d{8})-\d{6}(-\d{3})?\b")
UTC_TIME = re.compile(r"\b(\d{4}-\d{2}-\d{2})T\d{2}:?\d{2}:?\d{2}(\.\d+)?Z\b")
UUID = re.compile(r"\b([0-9A-Fa-f]{8})-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b")


def redact(text, devices, team):
    for device in devices:
        text = text.replace(device["name"], device.get("model") or "iPhone").replace(device["udid"], "<udid>")
    if team:
        text = text.replace(team, "<team>")
    text = UUID.sub(r"\1", text)
    text = LOCAL_TIME.sub(r"\1-<time>", text)
    text = UTC_TIME.sub(r"\1T<time>Z", text)
    return text.replace(str(Path.cwd()) + "/", "").replace(str(Path.home()), "~")


def run_json(argv):
    return json.loads(subprocess.run(argv, capture_output=True, text=True, check=True).stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", required=True, help="deviceloop executable used for the commands")
    parser.add_argument("--device", required=True, help="UDID of the device to record")
    parser.add_argument("--script", required=True, type=Path, help="Demo steps JSON")
    parser.add_argument("--out", required=True, type=Path, help="Directory for timeline.json and the recording")
    parser.add_argument("--team", default="", help="Signing team ID that device bundle IDs end with")
    options = parser.parse_args()
    options.out.mkdir(parents=True, exist_ok=True)
    steps = json.loads(options.script.read_text())["steps"]

    environment = dict(os.environ, DEVICELOOP_DEVICE=options.device)
    devices = run_json([options.binary, "devices", "--all", "--json"])["devices"]

    started = run_json([options.binary, "video", "start", "--device", options.device, "--json"])
    origin = time.monotonic()
    events = []

    def add_event(kind, text):
        events.append({"t": round(time.monotonic() - origin, 3), "kind": kind, "text": text})

    try:
        for step in steps:
            if "chapter" in step or "caption" in step:
                kind = "chapter" if "chapter" in step else "caption"
                add_event(kind, step[kind])
            elif "pause" in step:
                time.sleep(step["pause"])
            elif "run" in step:
                command = step["run"].replace("{team}", "<team>")
                time.sleep(len(command) / TYPING_CHARS_PER_SECOND + 0.4)
                add_event("command", command)
                argv = [word.replace("{binary}", options.binary) for word in step["exec"]] if "exec" in step else shlex.split(step["run"])
                argv = [word.replace("{team}", options.team) for word in argv]
                if argv[0] == "deviceloop":
                    argv[0] = options.binary
                process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=environment)
                for line in process.stdout:
                    if line.strip():
                        add_event("output", redact(line.rstrip(), devices, options.team))
                process.wait()
        time.sleep(1.5)
    finally:
        stop_at = time.monotonic() - origin
        stopped = subprocess.run(
            [options.binary, "video", "stop", started["handle"], "--no-analyze", "--json"], capture_output=True, text=True
        )
    result = json.loads(stopped.stdout)
    timeline = {"video": result["video"], "duration": round(stop_at, 3), "events": events}
    (options.out / "timeline.json").write_text(json.dumps(timeline, indent=1) + "\n")
    print(f"timeline: {options.out / 'timeline.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
