#!/usr/bin/env python3
# For licensing see accompanying LICENSE file.
# Copyright 2026 Argmax, Inc. All rights reserved.

"""Opt-in UI runner smoke test. Mutates only the disposable DeviceLoop host fixture."""

import argparse
import datetime
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path


LOCATION = (37.3349, -122.0090)
COORDINATES = r"Location: (-?\d+\.\d+),(-?\d+\.\d+)"
# Audit types with a seeded fault on fixture.a11y.<type>. elementDetection has none.
SEEDED_AUDIT_TYPES = ["contrast", "dynamicType", "hitRegion", "sufficientElementDescription", "textClipped", "trait"]


class SmokeFailure(Exception):
    pass


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def positive_seconds(value):
    number = float(value)
    if not 0 < number <= 1200:
        raise argparse.ArgumentTypeError("timeouts must be between 0 and 1200 seconds")
    return number


def flatten(node):
    yield node
    for child in node.get("children", []):
        yield from flatten(child)


def near_location(label):
    match = re.fullmatch(COORDINATES, label)
    return match is not None and all(abs(float(observed) - expected) <= 0.001 for observed, expected in zip(match.groups(), LOCATION))


def away_from_location(label):
    return label == "Location: unavailable" or (re.fullmatch(COORDINATES, label) is not None and not near_location(label))


def element(tree, identifier):
    if not isinstance(tree, dict) or not isinstance(tree.get("root"), dict):
        raise SmokeFailure("Expected a tree payload with a root element")
    if tree.get("partial") or tree.get("errors"):
        raise SmokeFailure("Cannot verify a partial or failed observation")
    matches = [node for node in flatten(tree["root"]) if node.get("id") == identifier]
    if len(matches) != 1:
        raise SmokeFailure(f"Expected exactly one {identifier}, observed {len(matches)}")
    node = matches[0]
    frame = node.get("frame", [])
    viewport = tree["root"].get("frame", [])
    if len(frame) != 4 or len(viewport) != 4:
        raise SmokeFailure(f"Missing geometry for {identifier}")
    x, y, width, height = frame
    left, top, viewport_width, viewport_height = viewport
    if width <= 0 or height <= 0 or x + width <= left or y + height <= top or x >= left + viewport_width or y >= top + viewport_height:
        raise SmokeFailure(f"{identifier} is outside the observed app viewport")
    return node


class SmokeRun:
    def __init__(self, options):
        self.options = options
        self.directory = Path(options.artifacts).expanduser().resolve()
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
        binary = Path(options.binary).expanduser().resolve()
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise SmokeFailure(f"Executable not found: {binary}")
        self.binary = str(binary)
        self.runner_started = False
        self.host_app = None
        self.original_orientation = None
        self.report = {
            "schema": "deviceloop-smoke/1",
            "device": options.device,
            "fixtureApp": options.app,
            "binary": self.binary,
            "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "startedAt": now(),
            "testOutcome": "running",
            "cleanupOutcome": "not_attempted",
            "steps": [],
            "checks": [],
            "limits": "Visible accessibility state and geometry, not screenshot pixel verification or a reliability benchmark.",
        }
        self.save()

    def save(self):
        temporary = self.directory / "report.tmp"
        temporary.write_text(json.dumps(self.report, indent=2, ensure_ascii=True) + "\n")
        temporary.replace(self.directory / "report.json")

    def command(self, arguments, *, timeout=None, expected_error=None, expected_exit=0, app_arguments=None):
        argv = [self.binary, *arguments, "--device", self.options.device, "--json"]
        if app_arguments:
            argv += ["--", *app_arguments]
        entry = {"arguments": argv[1:], "startedAt": now()}
        self.report["steps"].append(entry)
        self.save()
        started = time.monotonic()
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=timeout or self.options.timeout)
        except BaseException as error:
            # SIGTERM first lets DeviceLoop stop a runner it is still starting.
            try:
                os.killpg(process.pid, signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=15)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                stdout, stderr = process.communicate()
            entry.update(
                outcome="unknown", error=type(error).__name__, stdout=stdout, stderr=stderr, elapsedSeconds=time.monotonic() - started
            )
            self.save()
            raise
        entry.update(exitCode=process.returncode, stdout=stdout, stderr=stderr, elapsedSeconds=time.monotonic() - started)
        try:
            payload = json.loads(stdout)
        except json.JSONDecodeError as error:
            entry["outcome"] = "invalid_json"
            self.save()
            raise SmokeFailure(f"Command produced invalid JSON: {arguments}") from error
        entry["result"] = payload
        observed_error = payload.get("error", {}).get("code") if isinstance(payload, dict) else None
        if expected_error:
            matched = process.returncode != 0 and observed_error == expected_error
        else:
            matched = process.returncode == expected_exit and observed_error is None
        entry["outcome"] = "expected" if matched else "failed"
        self.save()
        if not matched:
            raise SmokeFailure(f"Unexpected command result for {arguments}: exit={process.returncode}, error={observed_error}")
        return payload

    def ui(self, *arguments, **kwargs):
        return self.command(["ui", *arguments, "--app", self.options.app], **kwargs)

    def tree(self):
        tree = self.ui("tree")
        if tree.get("app") != self.options.app:
            raise SmokeFailure("Observation belongs to a different app")
        return tree

    def verify(self, name, observed, expected, identifier=None):
        passed = observed == expected
        self.report["checks"].append({"name": name, "id": identifier, "expected": expected, "observed": observed, "passed": passed})
        self.save()
        if not passed:
            raise SmokeFailure(f"{name}: expected {expected!r}, observed {observed!r}")

    def check(self, name, identifier, expected, tree=None):
        tree = tree if tree is not None else self.tree()
        self.verify(name, element(tree, identifier).get("label"), expected, identifier)
        return tree

    def type_into(self, name, text, identifier, expected, clear=False):
        typed = self.ui("type", text, "--into", "id=" + identifier, *(["--clear"] if clear else []))
        self.verify(name, [typed.get("readBack"), typed.get("textVerified")], [expected, True], identifier)

    def exercise_text_fields(self):
        secret = "s3cret-Fixture"
        typed = self.ui("type", secret, "--into", "id=fixture.secure.input")
        output = self.report["steps"][-1]["stdout"] + self.report["steps"][-1]["stderr"]
        self.verify("secure field is unverified without read-back", [typed.get("textVerified"), "readBack" in typed], [False, False])
        self.verify("secure text is absent from output", secret in output, False)
        self.check("secure text reached the field", "fixture.secure.length", f"Secret length: {len(secret)}")
        self.type_into("append verifies previous text plus typed text", "def", "fixture.prefilled.input", "abcdef")
        self.type_into("clear verifies exact text", "xyz", "fixture.prefilled.input", "xyz", clear=True)
        sentence = "the quick brown fox jumps"
        self.type_into("clear verifies a long text", sentence, "fixture.prefilled.input", sentence, clear=True)
        # The keyboard can still be moving the layout when typing returns.
        self.ui("wait", "--until", "stable")
        x, y, width, height = element(self.tree(), "fixture.prefilled.input")["frame"]
        self.ui("tap", f"{x + width / 4:.0f},{y + height / 2:.0f}")
        self.ui("type", "|")
        marked = element(self.tree(), "fixture.prefilled.input").get("value", "")
        self.verify("caret placed mid-text", 0 < marked.find("|") < len(marked) - 1, True, "fixture.prefilled.input")
        self.type_into("clear from a mid-text caret empties the field", "done", "fixture.prefilled.input", "done", clear=True)
        self.ui("type", "\b", "--into", "id=fixture.placeholder.input")
        self.check("delete on an empty field is counted", "fixture.placeholder.deletes", "Deletes: 1")
        self.type_into("placeholder field verifies typed text", "abc", "fixture.placeholder.input", "abc", clear=True)
        self.check("clear on a placeholder field sends no deletes", "fixture.placeholder.deletes", "Deletes: 1")

    def exercise_alert(self):
        self.ui("tap", "id=fixture.alert.open")
        labels = ["Keep Draft", "Delete Draft", "Ask Later"]
        for action in ("accept", "dismiss"):
            failed = self.command(["ui", "alert", action], expected_error="element_ambiguous")
            message = failed["error"]["message"]
            self.verify(f"alert {action} without a known label lists every button", all(f'"{label}"' in message for label in labels), True)
        self.command(["ui", "alert", "--button", "Delete Draft"])
        self.check("alert button tapped by exact label", "fixture.alert.result", "Alert: Delete Draft")

    def exercise_switch(self):
        self.ui("tap", "id=fixture.switch")
        tree = self.tree()
        self.verify("tap on a switch flips it", element(tree, "fixture.switch").get("value"), "1", "fixture.switch")
        self.ui("tap", "@" + element(tree, "fixture.switch")["ref"])
        self.verify("tap on a switch ref flips it back", element(self.tree(), "fixture.switch").get("value"), "0", "fixture.switch")
        failed = self.ui("tap", "id=fixture.offscreen", expected_error="element_not_hittable")
        self.verify("off-screen element tap is rejected", failed["error"]["code"], "element_not_hittable", "fixture.offscreen")
        # element() rejects nodes outside the viewport, so this reads the off-screen node directly.
        offscreen = next(node for node in flatten(self.tree()["root"]) if node.get("id") == "fixture.offscreen")
        failed = self.ui("tap", "@" + offscreen["ref"], expected_error="element_not_hittable")
        self.verify("off-screen ref tap is rejected", failed["error"]["code"], "element_not_hittable", "fixture.offscreen")

    def exercise_gestures(self):
        pad = "id=fixture.gesture.pad"
        self.ui("tap", pad)
        tree = self.check("tap adds one single tap", "fixture.gesture.taps", "Taps: 1")
        self.check("tap adds no double tap", "fixture.gesture.doubletaps", "Double taps: 0", tree)
        self.ui("tap", pad, "--count", "2")
        tree = self.check("double tap adds one double tap", "fixture.gesture.doubletaps", "Double taps: 1")
        self.check("double tap adds no single tap", "fixture.gesture.taps", "Taps: 1", tree)
        self.ui("tap", pad, "--hold-ms", "800")
        tree = self.check("hold adds one long press", "fixture.gesture.longpresses", "Long presses: 1")
        self.check("hold adds no single tap", "fixture.gesture.taps", "Taps: 1", tree)
        self.ui("swipe", "left", "--on", pad)
        tree = self.check("swipe left is recorded", "fixture.gesture.swipe", "Swipe: left")
        x, y, width, height = element(tree, "fixture.gesture.pad")["frame"]
        start = (round(x + width * 0.8), round(y + height * 0.7))
        end = (round(x + width * 0.2), round(y + height * 0.3))
        self.ui("drag", f"{start[0]},{start[1]}", f"{end[0]},{end[1]}")
        expected = (end[0] - start[0], end[1] - start[1])
        drag = re.fullmatch(r"Drag: (-?\d+),(-?\d+)", element(self.tree(), "fixture.gesture.drag").get("label", ""))
        within = drag is not None and all(abs(int(observed) - offset) <= 10 for observed, offset in zip(drag.groups(), expected))
        self.verify(f"drag translation within 10 points of {expected[0]},{expected[1]}", within, True, "fixture.gesture.drag")
        # ArgumentParser reads -5,10 as an option, so the step grammar sends the negative point.
        # ui do stops at the failing step, exits 1 and reports the step's error in its flow-result.
        result = self.ui("do", "tap -5,10", expected_exit=1)
        failed = [step for step in result.get("steps", []) if step.get("status") == "failed"]
        self.verify("out-of-frame tap is rejected", [(step.get("error") or {}).get("code") for step in failed], ["bad_arguments"])
        self.check("out-of-frame tap adds no tap", "fixture.gesture.taps", "Taps: 1")

    def exercise_rotation(self, tree):
        previous = self.command(["orientation"]).get("orientation")
        turned = "portrait" if previous == "landscapeLeft" else "landscapeLeft"
        rotated = self.command(["orientation", turned])
        try:
            if not rotated.get("verified"):
                # Physical iPhones accept the request and stay in portrait.
                self.report["rotationSkipped"] = f"the device reports {rotated.get('observed')} after {turned}"
                self.save()
                return
            failed = self.ui("tap", "@" + element(tree, "fixture.counter.increment")["ref"], expected_error="stale_ref")
            self.verify("stale_ref names the rotation", f"to {turned} after ref" in failed["error"]["message"], True)
            self.check("rotation rejects an earlier ref", "fixture.counter.value", "Count: 0")
        finally:
            settable = ("portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight")
            self.command(["orientation", previous if previous in settable else "portrait"])
        self.ui("wait", "--until", "stable")

    def location_reading(self):
        return element(self.tree(), "fixture.location.value").get("label") or ""

    def wait_for_location(self, name, expected, accept, timeout=15):
        deadline = time.monotonic() + timeout
        while True:
            label = self.location_reading()
            passed = accept(label)
            if passed or time.monotonic() > deadline:
                break
            time.sleep(1)
        check = {"name": name, "id": "fixture.location.value", "expected": expected, "observed": label, "passed": passed}
        self.report["checks"].append(check)
        self.save()
        if not passed:
            raise SmokeFailure(f"{name}: expected {expected}, observed {label!r}")

    def exercise_location(self):
        self.ui("tap", "id=fixture.navigation.open")
        deadline = time.monotonic() + 5
        label = self.location_reading()
        while label == "Location: waiting" and time.monotonic() < deadline:
            time.sleep(1)
            label = self.location_reading()
        self.report["locationBefore"] = label
        self.save()
        if label in ("Location: not requested", "Location: not authorized"):
            raise SmokeFailure(f"{self.options.app} has no location access ({label!r}). Grant it before passing --location.")
        target = f"{LOCATION[0]},{LOCATION[1]}"
        try:
            self.command(["location", target])
            self.wait_for_location("fixture reads the set location", f"within 0.001 degrees of {target}", near_location)
        finally:
            self.command(["location", "clear"])
        # A running app keeps its last fix after clear.
        self.launch_fixture()
        self.ui("tap", "id=fixture.navigation.open")
        expected = f"Location: unavailable or coordinates not within 0.001 degrees of {target}"
        self.wait_for_location("clear moves the reading away", expected, away_from_location)

    def audit_screen(self, screen, title, expected_exit):
        self.command(["launch", self.options.app, "--restart"], app_arguments=["--deviceloop-fixture-a11y", screen])
        self.check(f"{screen} screen shown", "fixture.a11y.screen", title)
        return self.ui("audit", "--no-screenshot", expected_exit=expected_exit)["issues"]

    def launch_fixture(self):
        return self.command(["launch", self.options.app, "--restart"], app_arguments=["--deviceloop-fixture"])

    def start_runner(self):
        """Starts the runner and, without --app, takes the fixture app from the host app it reports."""
        started = self.command(["runner", "start"], timeout=self.options.startup_timeout)
        self.runner_started = True
        self.host_app = started.get("hostApp")
        if self.options.app is None:
            self.options.app = self.fixture_app(self.host_app or "")
            self.report["fixtureApp"] = self.options.app

    def fixture_app(self, host_app):
        """The fixture bundle ID for the host app that runner start reports."""
        if not host_app:
            raise SmokeFailure("runner start reported no host app. Pass --app.")
        return host_app

    def exercise(self):
        self.start_runner()
        # The fixture's main screen fits above the keyboard in portrait. In landscape the keyboard can push Submit
        # under the navigation bar.
        self.original_orientation = self.command(["orientation"]).get("orientation")
        if self.original_orientation not in (None, "portrait"):
            self.command(["orientation", "portrait"])
        # XCTest may install its target app only when XCUIApplication first launches it.
        # This setup launch is distinct from the restart that enables the fixture.
        self.ui("do", "launch " + self.options.app)
        self.launch_fixture()
        tree = self.check("initial counter", "fixture.counter.value", "Count: 0")
        self.check("initial text", "fixture.text.echo", "No text submitted", tree)
        self.check("initial choice", "fixture.duplicate.result", "Choice: none", tree)
        self.exercise_rotation(tree)
        old_ref = element(self.tree(), "fixture.counter.increment")["ref"]
        self.ui("tap", "@" + old_ref)
        self.ui("tap", "@" + old_ref, expected_error="stale_ref")
        tree = self.check("one increment, no stale replay", "fixture.counter.value", "Count: 1")
        refreshed_ref = element(tree, "fixture.counter.increment")["ref"]
        self.tree()
        self.ui("tap", "@" + refreshed_ref, expected_error="stale_ref")
        self.check("observation replacement rejects old refs", "fixture.counter.value", "Count: 1")
        self.type_into("placeholder text is not previous text", "deviceloop fixture 42", "fixture.text.input", "deviceloop fixture 42")
        self.ui("tap", "id=fixture.text.submit")
        self.check("exact submitted text", "fixture.text.echo", "deviceloop fixture 42")
        self.ui("tap", "id=fixture.duplicate.second")
        self.check("second duplicate by identifier", "fixture.duplicate.result", "Choice: second")
        self.ui("tap", "id=fixture.duplicate.first")
        self.check("first duplicate by identifier", "fixture.duplicate.result", "Choice: first")
        self.ui("tap", "id=fixture.navigation.open")
        self.check("navigation arrived", "fixture.navigation.detail", "Detail screen")
        self.ui("tap", "id=fixture.navigation.back")
        self.check("navigation returned with state intact", "fixture.counter.value", "Count: 1")
        self.launch_fixture()
        tree = self.check("restart resets counter", "fixture.counter.value", "Count: 0")
        self.check("restart resets text", "fixture.text.echo", "No text submitted", tree)
        self.check("restart resets choice", "fixture.duplicate.result", "Choice: none", tree)
        self.ui("tap", "id=fixture.navigation.open")
        self.exercise_alert()
        self.exercise_gestures()
        self.exercise_switch()
        self.ui("tap", "id=fixture.navigation.back")
        self.exercise_text_fields()
        if self.options.location:
            self.exercise_location()
        issues = self.audit_screen("faults", "Accessibility faults", expected_exit=7)
        os_version = (self.command(["info"]).get("target") or {}).get("osVersion") or "0"
        expected_types = SEEDED_AUDIT_TYPES
        if int(os_version.split(".")[0]) < 26:
            # XCTest's audit below iOS 26 can miss the repeated button trait.
            expected_types = [audit_type for audit_type in SEEDED_AUDIT_TYPES if audit_type != "trait"]
            self.report["auditSkipped"] = f"trait is not checked on iOS {os_version}"
        for audit_type in expected_types:
            identifier = "fixture.a11y." + audit_type
            flagged = any(issue["type"] == audit_type and (issue.get("element") or {}).get("id") == identifier for issue in issues)
            self.verify(f"audit flags {audit_type}", flagged, True, identifier)
        issues = self.audit_screen("clean", "Accessible screen", expected_exit=0)
        self.verify("clean screen has no audit issues", issues, [], "fixture.a11y.screen")
        self.command(["screenshot", "--output", str(self.directory / "fixture-final.png")])

    def run(self):
        exit_code = 0
        try:
            self.exercise()
            self.report["testOutcome"] = "passed"
        except KeyboardInterrupt:
            self.report.update(testOutcome="interrupted", error="Interrupted by operator")
            exit_code = 130
        except Exception as error:
            self.report.update(testOutcome="failed", error=f"{type(error).__name__}: {error}")
            exit_code = 1
        finally:
            try:
                if self.runner_started:
                    if self.original_orientation in ("portraitUpsideDown", "landscapeLeft", "landscapeRight"):
                        self.command(["orientation", self.original_orientation], timeout=30)
                    if self.host_app:
                        try:
                            # With no launch arguments the host app shows its idle screen.
                            self.command(["launch", self.host_app, "--restart"], timeout=60)
                        except Exception as error:
                            self.report["cleanupRelaunchError"] = f"{type(error).__name__}: {error}"
                    self.command(["ui", "press", "home"], timeout=30)
                    self.report["cleanupOutcome"] = "home_request_completed"
                else:
                    self.report["cleanupOutcome"] = "skipped_runner_not_started"
            except BaseException as error:
                self.report.update(cleanupOutcome="failed", cleanupError=f"{type(error).__name__}: {error}")
                if exit_code == 0:
                    exit_code = 1
            self.report["finishedAt"] = now()
            self.save()
        print(
            json.dumps(
                {
                    "testOutcome": self.report["testOutcome"],
                    "cleanupOutcome": self.report["cleanupOutcome"],
                    "report": str(self.directory / "report.json"),
                }
            )
        )
        return exit_code


def run_smoke(parser, smoke_class):
    """Parses the options and runs `smoke_class` on the device. Returns the exit status."""
    options = parser.parse_args()
    if not re.fullmatch(r"[A-Fa-f0-9-]{20,64}", options.device):
        parser.error("--device must be an exact UDID, not a device name, booted, or usb")
    try:
        return smoke_class(options).run()
    except (SmokeFailure, OSError) as error:
        print(str(error), file=sys.stderr)
        return 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, help="Path to the deviceloop executable to test")
    parser.add_argument("--device", required=True, help="Exact UDID of an explicitly authorized test target")
    parser.add_argument("--artifacts", required=True, help="New directory for report and screenshot")
    parser.add_argument("--app", help="Fixture host bundle ID. Defaults to the host app that runner start reports")
    parser.add_argument("--timeout", type=positive_seconds, default=120, help="Per-command timeout in seconds")
    parser.add_argument(
        "--location", action="store_true", help="Also set and clear the simulated location. The host app needs location access"
    )
    parser.add_argument("--startup-timeout", type=positive_seconds, default=720, help="Runner build/start timeout in seconds")
    return run_smoke(parser, SmokeRun)


if __name__ == "__main__":
    sys.exit(main())
