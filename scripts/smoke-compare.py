#!/usr/bin/env python3
# For licensing see accompanying LICENSE file.
# Copyright 2026 Argmax, Inc. All rights reserved.

"""Opt-in run comparison smoke test. Records the host fixture as runs A, A again and B, then compares A with each."""

import argparse
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("smoke_runner", Path(__file__).with_name("smoke-runner.py"))
smoke_runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke_runner)
SmokeFailure = smoke_runner.SmokeFailure

VARIANT_B = "--deviceloop-fixture-variant=b"
TRANSITION_STEP = "tap id=fixture.transition.toggle"
MOVED_ID = "fixture.text.submit"
RELABELED_ID = "fixture.navigation.open"


def status_bar_mask(tree, screenshot):
    """The screen above the fixture's navigation bar, as x,y,w,h in points."""
    tops = [node["frame"][1] for node in smoke_runner.flatten(tree["root"]) if node.get("type") == "navigationBar"]
    if not tops or min(tops) <= 0:
        raise SmokeFailure("Could not find the status bar height: the fixture tree has no navigation bar below it")
    return f"0,0,{screenshot['pointWidth']:g},{min(tops):g}"


def moved(finding):
    delta = finding.get("delta") or []
    return (
        finding.get("property") == "frame"
        and finding["element"].get("id") == MOVED_ID
        and len(delta) == 4
        and abs(delta[0] - 40) < 1
        and all(abs(value) < 1 for value in delta[1:])
    )


def relabeled(finding):
    return (
        finding.get("property") == "label"
        and finding["element"].get("id") == RELABELED_ID
        and (finding["baseline"], finding["candidate"]) == ("Open detail", "Show detail")
    )


def slower(finding):
    baseline, candidate = finding.get("baselineMs"), finding.get("candidateMs")
    return (
        finding.get("metric") == "animation"
        and finding["status"] == "changed"
        and baseline is not None
        and candidate is not None
        and candidate > baseline
    )


class CompareRun(smoke_runner.SmokeRun):
    def __init__(self, options):
        super().__init__(options)
        self.report.update(
            schema="deviceloop-smoke-compare/1",
            runs={},
            comparisons={},
            limits="One recording per variant on one target. Timings are uncalibrated single-trial visual estimates.",
        )
        self.save()

    def command(self, arguments, *, device=True, **kwargs):
        if device:
            return super().command(arguments, **kwargs)
        # run compare reads run folders on this Mac and takes no --device.
        argv = [self.binary, *arguments, "--json"]
        entry = {"arguments": argv[1:], "startedAt": smoke_runner.now(), "outcome": "unknown"}
        self.report["steps"].append(entry)
        self.save()
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=self.options.timeout, check=False)
        entry.update(exitCode=completed.returncode, stdout=completed.stdout, stderr=completed.stderr, outcome="failed")
        self.save()
        if completed.returncode != 0:
            raise SmokeFailure(f"Unexpected command result for {arguments}: exit={completed.returncode}")
        entry.update(result=json.loads(completed.stdout), outcome="expected")
        self.save()
        return entry["result"]

    def record_run(self, label, variant_arguments):
        run = self.command(["run", "start", "--name", f"smoke-compare-{label}", "--app", self.options.app])
        self.report["runs"][label] = run["id"]
        try:
            self.command(["launch", self.options.app, "--restart"], app_arguments=["--deviceloop-fixture", *variant_arguments])
            tree = self.tree()
            screenshot = self.command(["screenshot"])
            self.ui("tap", "id=fixture.navigation.open")
            self.command(["video", "capture", "--do", TRANSITION_STEP, "--app", self.options.app, "--keep-video"])
        finally:
            self.command(["run", "stop"])
        return run["id"], tree, screenshot

    def compare(self, name, baseline, candidate, mask):
        comparison = self.command(["run", "compare", baseline, candidate, "--mask", mask], device=False)
        self.report["comparisons"][name] = {key: comparison[key] for key in ("id", "verdict", "path", "report")}
        self.save()
        return comparison

    def check_finding(self, name, comparison, accepts):
        """Passes when a tree change or timing of a step is accepted and both runs kept that step's files."""
        runs = Path(comparison["path"]).parent.parent
        for step in comparison["steps"]:
            for finding in (step.get("tree") or {}).get("changed", []) + (step.get("timing") or []):
                if not accepts(finding):
                    continue
                entry = {"name": name, "observed": finding, "step": {"index": step["index"], "command": step["command"]}}
                passed = True
                for side in ("baseline", "candidate"):
                    run = comparison[side]["id"]
                    files = step[side]["files"]
                    missing = [path for path in files if not (runs / run / path).is_file()]
                    entry["step"][side] = {"run": run, "seq": step[side]["seq"], "files": files, "missing": missing}
                    passed = passed and bool(files) and not missing
                entry["passed"] = passed
                self.report["checks"].append(entry)
                self.save()
                if not passed:
                    raise SmokeFailure(f"{name}: step {step['index']} files missing")
                return
        self.verify(name, "no matching change", "a matching change", comparison["id"])

    def exercise(self):
        self.start_runner()
        # XCTest may install its target app only when XCUIApplication first launches it.
        self.ui("do", "launch " + self.options.app)
        run_a, tree, screenshot = self.record_run("a", [])
        mask = status_bar_mask(tree, screenshot)
        self.report["statusBarMask"] = mask
        run_a_again, _, _ = self.record_run("a-again", [])
        run_b, _, _ = self.record_run("b", [VARIANT_B])

        control = self.compare("control", run_a, run_a_again, mask)
        self.verify("A vs A is same", control["verdict"], "same")

        seeded = self.compare("seeded", run_a, run_b, mask)
        self.verify("A vs B is different", seeded["verdict"], "different")
        self.check_finding("moved element", seeded, moved)
        self.check_finding("changed label", seeded, relabeled)
        self.check_finding("changed transition", seeded, slower)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, help="Path to the deviceloop executable to test")
    parser.add_argument("--device", required=True, help="Exact UDID of an explicitly authorized test target")
    parser.add_argument("--artifacts", required=True, help="New directory for the report")
    parser.add_argument("--app", help="Fixture host bundle ID. Defaults to the host app that runner start reports")
    parser.add_argument("--timeout", type=smoke_runner.positive_seconds, default=120, help="Per-command timeout in seconds")
    parser.add_argument("--startup-timeout", type=smoke_runner.positive_seconds, default=720, help="Runner build/start timeout in seconds")
    return smoke_runner.run_smoke(parser, CompareRun)


if __name__ == "__main__":
    sys.exit(main())
