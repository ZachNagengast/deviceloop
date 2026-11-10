#!/usr/bin/env python3
# For licensing see accompanying LICENSE file.
# Copyright 2026 Argmax, Inc. All rights reserved.

"""Runs the exported fixture flows in Tests/ExportCheck on a booted simulator and checks their results."""

import argparse
import contextlib
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Tests/ExportCheck/ExportCheck.xcodeproj"
FAIL_SOURCE = ROOT / "Tests/ExportCheck/UITests/FixtureFailFlowTests.swift"
FAIL_ASSERTION = 'XCTAssertEqual(element.label, "Count: 2")'
FAIL_MESSAGE = 'XCTAssertEqual failed: ("Count: 1") is not equal to ("Count: 2")'
STOP_SECONDS = 60


class Refusal(Exception):
    pass


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def stop(process):
    """Sends SIGINT to the process group, then SIGKILL after STOP_SECONDS or a second interrupt. Returns whether it killed."""
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGINT)
    try:
        process.wait(timeout=STOP_SECONDS)
        return False
    except (KeyboardInterrupt, subprocess.TimeoutExpired):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        return True


def test_cases(nodes):
    for node in nodes:
        if node.get("nodeType") == "Test Case":
            yield node
        yield from test_cases(node.get("children", []))


class ExportCheck:
    def __init__(self, options):
        self.options = options
        self.directory = Path(options.artifacts).expanduser().resolve()
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
        self.report = {
            "schema": "deviceloop-export-check/1",
            "device": options.device,
            "binary": str(Path(options.binary).expanduser().resolve()),
            "startedAt": now(),
            "outcome": "running",
            "steps": [],
            "checks": [],
        }
        self.save()

    def save(self):
        temporary = self.directory / "report.tmp"
        temporary.write_text(json.dumps(self.report, indent=2, ensure_ascii=True) + "\n")
        temporary.replace(self.directory / "report.json")

    def command(self, argv, timeout, log=None):
        entry = {"arguments": argv, "startedAt": now()}
        self.report["steps"].append(entry)
        self.save()
        started = time.monotonic()
        with contextlib.ExitStack() as stack:
            if log:
                entry["log"] = log
                log_file = stack.enter_context(open(self.directory / log, "w"))
                streams = {"stdout": log_file, "stderr": subprocess.STDOUT}
            else:
                streams = {"stdout": subprocess.PIPE, "stderr": subprocess.PIPE}
            process = stack.enter_context(subprocess.Popen(argv, text=True, start_new_session=True, **streams))
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except (KeyboardInterrupt, subprocess.TimeoutExpired) as error:
                outcome = "interrupted" if isinstance(error, KeyboardInterrupt) else "timeout"
                killed = stop(process)
                entry.update(outcome=outcome, killed=killed, exitCode=process.returncode, elapsedSeconds=time.monotonic() - started)
                self.save()
                raise
        entry.update(exitCode=process.returncode, elapsedSeconds=time.monotonic() - started)
        if not log:
            entry.update(stdout=stdout, stderr=stderr)
        self.save()
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)

    def check(self, name, expected, observed):
        self.report["checks"].append({"name": name, "expected": expected, "observed": observed, "passed": expected == observed})
        self.save()

    def require_idle_booted_simulator(self):
        devices = json.loads(self.command(["xcrun", "simctl", "list", "devices", "--json"], 60).stdout)["devices"]
        states = [device["state"] for runtime in devices.values() for device in runtime if device["udid"] == self.options.device]
        if states != ["Booted"]:
            raise Refusal(f"{self.options.device} is not a booted simulator. Boot it first, this script does not.")
        status = self.command([self.report["binary"], "runner", "status", "--device", self.options.device, "--json"], 60)
        try:
            payload = json.loads(status.stdout)
        except json.JSONDecodeError:
            payload = None
        if status.returncode != 0 or payload != {"running": False}:
            raise Refusal(
                f"A DeviceLoop runner may be live on {self.options.device}. Run deviceloop runner stop --device {self.options.device} first."
            )

    def exercise(self):
        self.require_idle_booted_simulator()
        result_bundle = self.directory / "export.xcresult"
        self.command(
            [
                "xcodebuild", "test",
                "-project", str(PROJECT),
                "-scheme", "ExportCheck",
                "-destination", f"platform=iOS Simulator,id={self.options.device}",
                "-derivedDataPath", str(ROOT / ".build/export-check"),
                "-resultBundlePath", str(result_bundle),
                "CODE_SIGNING_ALLOWED=NO",
            ],
            1200,
            log="xcodebuild.log",
        )
        tests = self.command(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result_bundle), "--compact"], 120)
        if tests.returncode != 0:
            raise RuntimeError(f"xcresulttool could not read {result_bundle}")
        results = {case["name"]: case for case in test_cases(json.loads(tests.stdout).get("testNodes", []))}
        line = [text.strip() for text in FAIL_SOURCE.read_text().splitlines()].index(FAIL_ASSERTION) + 1
        passing = results.get("testFixture()", {})
        failing = results.get("testFixtureFail()", {})
        self.check("testFixture() result", "Passed", passing.get("result"))
        self.check("testFixtureFail() result", "Failed", failing.get("result"))
        self.check(
            "testFixtureFail() failure",
            [{"file": FAIL_SOURCE.name, "line": line, "message": FAIL_MESSAGE}],
            [
                {
                    "file": Path(node.get("sourceLocation", {}).get("filePath", "")).name,
                    "line": node.get("sourceLocation", {}).get("lineNumber"),
                    "message": node.get("name"),
                }
                for node in failing.get("children", [])
                if node.get("nodeType") == "Failure Message"
            ],
        )

    def run(self):
        try:
            self.exercise()
            passed = all(check["passed"] for check in self.report["checks"])
            self.report["outcome"] = "passed" if passed else "failed"
            exit_code = 0 if passed else 1
        except Refusal as error:
            self.report.update(outcome="refused", error=str(error))
            exit_code = 2
        except KeyboardInterrupt:
            self.report.update(outcome="interrupted", error="Interrupted by operator")
            exit_code = 130
        except Exception as error:
            self.report.update(outcome="failed", error=f"{type(error).__name__}: {error}")
            exit_code = 1
        finally:
            self.report["finishedAt"] = now()
            self.save()
        print(
            json.dumps(
                {
                    "outcome": self.report["outcome"],
                    "error": self.report.get("error"),
                    "report": str(self.directory / "report.json"),
                }
            )
        )
        return exit_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, help="Path to the deviceloop executable, used for runner status")
    parser.add_argument("--device", required=True, help="Exact UDID of a booted simulator")
    parser.add_argument("--artifacts", required=True, help="New directory for report.json, xcodebuild.log and export.xcresult")
    options = parser.parse_args()
    if not re.fullmatch(r"[A-Fa-f0-9-]{36}", options.device):
        parser.error("--device must be an exact simulator UDID, not a name or booted")
    try:
        return ExportCheck(options).run()
    except OSError as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
