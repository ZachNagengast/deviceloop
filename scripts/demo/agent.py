#!/usr/bin/env python3
# For licensing see accompanying LICENSE file.
# Copyright 2026 Argmax, Inc. All rights reserved.

"""Runs Claude Code headless with only DeviceLoop's MCP tools and prints each DeviceLoop call as it happens.

Usage: python3 scripts/demo/agent.py --binary .build/debug/deviceloop "<task>"
DEVICELOOP_HOME and DEVICELOOP_DEVICE pass through to the MCP server.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

TOOL_PREFIX = "mcp__deviceloop__"
MAX_COLUMNS = 78
NOISY_KEYS = {
    "eventTime", "operationID", "sessionEpoch", "deviceOrientation", "display", "arguments", "environmentKeys", "issues",
    "previousPids", "path", "pixelWidth", "pixelHeight", "pointWidth", "pointHeight", "pointScale", "scale", "scaleSource", "sha256",
}


def shorten(text):
    text = text.replace(str(Path.cwd()) + "/", "").replace(str(Path.home()), "~")
    return text if len(text) <= MAX_COLUMNS else text[: MAX_COLUMNS - 3] + "..."


def compact(arguments):
    return ", ".join(f"{key}={json.dumps(value)}" for key, value in arguments.items() if key != "device")


def result_line(content):
    """The error message of a result, or its fields and list sizes, on one line."""
    if isinstance(content, list):
        content = next((part.get("text", "") for part in content if part.get("type") == "text"), "")
    text = str(content).strip()
    try:
        payload = json.loads(text)
    except ValueError:
        # Drops the target line, such as "iPhone 17 Pro (simulator, iOS 27.2)".
        lines = [line for line in text.splitlines() if line.strip() and not re.search(r"\((simulator|device), ", line)]
        return shorten(lines[0] if lines else "")
    if not isinstance(payload, dict):
        return shorten(text)
    if payload.get("ok") is False:
        return shorten(str((payload.get("error") or {}).get("message", "error")))
    fields = []
    if isinstance(payload.get("path"), str):
        fields.append(f"saved {Path(payload['path']).stem.split('-')[0]}")
    if "pixelWidth" in payload and "pixelHeight" in payload:
        fields.append(f"{payload['pixelWidth']}x{payload['pixelHeight']} px")
    for key, field_value in payload.items():
        if key in NOISY_KEYS or key.endswith("At"):
            continue
        if isinstance(field_value, (str, int, float, bool)):
            fields.append(f"{key}={field_value}")
        elif isinstance(field_value, list):
            fields.append(f"{key}: {len(field_value)}")
        elif isinstance(field_value, dict) and {"x", "y"} <= field_value.keys():
            fields.append(f"{key}={field_value['x']:g},{field_value['y']:g}")
    return shorten(", ".join(fields))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", required=True, type=Path, help="deviceloop executable the MCP server runs")
    parser.add_argument("task", help="What to ask the agent")
    options = parser.parse_args()
    environment = {key: os.environ[key] for key in ("DEVICELOOP_HOME", "DEVICELOOP_DEVICE") if key in os.environ}
    config = {"mcpServers": {"deviceloop": {"command": str(options.binary.resolve()), "args": ["mcp"], "env": environment}}}
    command = [
        "claude", "-p", options.task, "--mcp-config", json.dumps(config), "--strict-mcp-config", "--tools", "",
        "--setting-sources", "", "--allowedTools", "mcp__deviceloop", "--output-format", "stream-json", "--verbose",
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
    deviceloop_call_ids = set()
    try:
        for line in process.stdout:
            event = json.loads(line)
            message = event.get("message")
            content = message.get("content") if isinstance(message, dict) else None
            for part in content if isinstance(content, list) else []:
                if part.get("type") == "tool_use" and part.get("name", "").startswith(TOOL_PREFIX):
                    deviceloop_call_ids.add(part.get("id"))
                    print(f"> {part['name'].removeprefix(TOOL_PREFIX)}({compact(part.get('input') or {})})", flush=True)
                elif part.get("type") == "tool_result" and part.get("tool_use_id") in deviceloop_call_ids:
                    print(f"  {result_line(part.get('content'))}", flush=True)
            if event.get("type") == "result":
                print(re.sub(r"\*\*|`", "", event.get("result", "")).strip(), flush=True)
    finally:
        process.wait()
    return process.returncode


if __name__ == "__main__":
    sys.exit(main())
