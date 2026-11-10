#!/usr/bin/env python3
# For licensing see accompanying LICENSE file.
# Copyright 2026 Argmax, Inc. All rights reserved.

"""Opt-in Siri scenario smoke test against the installed DeviceLoop Siri fixture. Needs App Intents testing.

Example:
  python3 scripts/smoke-siri.py --binary /path/to/deviceloop --device <udid> --artifacts <new dir> \\
      --phrase "<phrase that adds a fixture task>" --title "<title of the task it adds>"

Runs `deviceloop siri test` three times with the same phrase: expecting its title, after seeding a task with that
title, and expecting another title. Each run resets the fixture before the phrase and in cleanup. Then checks
that the fixture shows no tasks. It never installs the fixture or changes device settings.
"""

import argparse
import importlib.util
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("smoke_runner", Path(__file__).with_name("smoke-runner.py"))
smoke_runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke_runner)
SmokeFailure = smoke_runner.SmokeFailure


class SiriSmokeRun(smoke_runner.SmokeRun):
    def __init__(self, options):
        super().__init__(options)
        self.report["limits"] = "Fixture task entities read through App Intents. Siri effects outside the fixture are not observed."
        self.save()

    def scenario(self, name, expect, seed=None, expected_exit=0):
        scenario = {
            "app": self.options.app,
            "reset": {"intent": "ResetFixtureTasksIntent"},
            "phrases": [self.options.phrase],
            "expect": expect,
        }
        if seed:
            scenario["seed"] = seed
        path = self.directory / f"{name}.json"
        path.write_text(json.dumps(scenario, indent=2) + "\n")
        arguments = ["siri", "test", str(path), "--artifacts", str(self.directory / name)]
        report = self.command(arguments, timeout=self.options.scenario_timeout, expected_exit=expected_exit)
        self.verify(f"{name} reads entities through App Intents", report.get("backend"), "entity", name)
        self.verify(f"{name} cleanup runs the reset intent", report.get("cleanup"), "ran", name)
        return report["phrases"][0]["outcome"]

    def fixture_app(self, host_app):
        if "deviceloop.host" not in host_app:
            raise SmokeFailure("runner start reported no host app. Pass --app.")
        return host_app.replace("deviceloop.host", "deviceloop.siri-fixture", 1)

    def exercise(self):
        self.start_runner()
        title = self.options.title
        expect = {"entity": "FixtureTaskEntity", "matching": title, "property": "title", "equals": title, "count": 1}
        self.verify("correct phrase is verified", self.scenario("correct", expect), "verified", "correct")
        seed = [{"intent": "AddFixtureTaskIntent", "params": {"title": title}}]
        outcome = self.scenario("duplicate", expect, seed=seed, expected_exit=8)
        self.verify("pre-seeded duplicate is detected", outcome, "duplicate", "duplicate")
        outcome = self.scenario("wrong-title", dict(expect, equals=title + " (other)"), expected_exit=8)
        self.verify("wrong title is detected", outcome, "wrong_entity", "wrong-title")
        self.command(["launch", self.options.app, "--restart"])
        self.command(["ui", "wait", "--label", "Fixture Tasks", "--app", self.options.app])
        found = self.command(["ui", "find", "--id", "siri.fixture.task.1", "--app", self.options.app])
        self.verify("cleanup leaves the fixture store empty", found.get("matches"), [], "siri.fixture.task.1")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", required=True, help="Path to the deviceloop executable to test")
    parser.add_argument("--device", required=True, help="Exact UDID of an explicitly authorized test target")
    parser.add_argument("--artifacts", required=True, help="New directory for scenarios, reports and screenshots")
    parser.add_argument("--phrase", required=True, help="What to say to Siri. It should add one fixture task titled --title")
    parser.add_argument("--title", required=True, help="Title of the task the phrase adds")
    parser.add_argument("--app", help="Fixture bundle ID. Defaults to the runner's host app with siri-fixture in place of host")
    parser.add_argument("--timeout", type=smoke_runner.positive_seconds, default=120, help="Per-command timeout in seconds")
    parser.add_argument("--scenario-timeout", type=smoke_runner.positive_seconds, default=600, help="Per-scenario timeout in seconds")
    parser.add_argument("--startup-timeout", type=smoke_runner.positive_seconds, default=720, help="Runner build/start timeout in seconds")
    return smoke_runner.run_smoke(parser, SiriSmokeRun)


if __name__ == "__main__":
    sys.exit(main())
