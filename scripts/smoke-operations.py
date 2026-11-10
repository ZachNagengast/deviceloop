#!/usr/bin/env python3
# For licensing see accompanying LICENSE file.
# Copyright 2026 Argmax, Inc. All rights reserved.

"""Exercise operation admission against an already launched disposable fixture.

Example:
  python3 scripts/smoke-operations.py --session-file /path/to/session.json \
      --artifacts .build/operation-smoke-unique

This sends fixture input and one Siri request ("what time is it"). It never
launches an app, changes device settings, retries uncertain input, or
resubmits an operation whose receipt is unknown.
"""

import argparse
import concurrent.futures
import datetime
import json
import plistlib
import re
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path


def identifier():
    return str(uuid.uuid4())


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def nodes_with_id(tree, element_id):
    pending = [tree.get("root", {})]
    matches = []
    while pending:
        node = pending.pop()
        if node.get("id") == element_id:
            matches.append(node)
        pending.extend(node.get("children") or [])
    return matches


class SmokeFailure(Exception):
    pass


class Response:
    def __init__(self, status, content_type, body, elapsed):
        self.status = status
        self.body = body
        self.elapsed = elapsed
        self.json = None
        if content_type == "application/json":
            try:
                self.json = json.loads(body)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise SmokeFailure("Runner returned malformed JSON") from error


class Harness:
    def __init__(self, session, artifacts, app):
        host = session["host"].strip("[]")
        address = f"[{host}]" if ":" in host else host
        self.base = f"http://{address}:{int(session['port'])}"
        self.token = session["token"]
        if not isinstance(self.token, str) or not self.token:
            raise SmokeFailure("Session file has no authentication token")
        self.epoch = None
        self.app = app
        self.artifacts = artifacts
        self.lock = threading.Lock()
        self.assertions = []
        self.request_count = 0
        self.started = time.monotonic()
        artifacts.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.write_report("running")

    def redact(self, value):
        if isinstance(value, str):
            return value.replace(self.token, "[REDACTED]")
        if isinstance(value, dict):
            return {self.redact(key): self.redact(item) for key, item in value.items()}
        if isinstance(value, list):
            return [self.redact(item) for item in value]
        return value

    def request(self, name, method, path, body=None, operation_id=None, epoch="current", timeout=12, dispatch_budget=5000):
        operation_id = operation_id or identifier()
        headers = {
            "Authorization": f"Bearer {self.token}",
            "X-DeviceLoop-Operation-ID": operation_id,
            "X-DeviceLoop-Dispatch-Budget-Ms": str(dispatch_budget),
        }
        chosen_epoch = self.epoch if epoch == "current" else epoch
        if chosen_epoch is not None:
            headers["X-DeviceLoop-Epoch"] = chosen_epoch
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base + path, data=body, headers=headers, method=method)
        start = time.monotonic()
        record = {
            "name": name,
            "method": method,
            "path": path,
            "operationID": operation_id,
            "sessionEpoch": chosen_epoch,
            "dispatchBudgetMs": dispatch_budget,
            "startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        if body is not None:
            record["requestJSON"] = json.loads(body)
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            try:
                response = opener.open(request, timeout=timeout)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                response_body = response.read()
            result = Response(response.status, response.headers.get("Content-Type"), response_body, time.monotonic() - start)
            record.update(status=response.status, elapsedSeconds=result.elapsed, responseJSON=result.json)
            return result
        except Exception as error:
            record.update(elapsedSeconds=time.monotonic() - start, failure=str(error), outcome="unknown")
            raise SmokeFailure(f"{name} failed: {error}. No input was retried.") from error
        finally:
            with self.lock:
                self.request_count += 1
                with (self.artifacts / "requests.jsonl").open("a", encoding="utf-8") as output:
                    output.write(json.dumps(self.redact(record), sort_keys=True) + "\n")

    def check(self, condition, name, **evidence):
        assertion = dict(name=name, passed=bool(condition), **evidence)
        self.assertions.append(assertion)
        print(f"{'PASS' if condition else 'FAIL'} {name}", flush=True)
        if not condition:
            raise SmokeFailure(name)

    def success(self, response, name):
        payload = response.json or {}
        self.check(response.status == 200 and payload.get("ok") is True, name, status=response.status, response=response.json)
        return payload.get("result", {})

    def error(self, response, code, name, status):
        payload = response.json or {}
        actual = payload.get("error", {}).get("code")
        self.check(
            response.status == status and payload.get("ok") is False and actual == code,
            name,
            expectedCode=code,
            actualCode=actual,
            status=response.status,
        )

    def counter(self, name):
        response = self.request(name, "POST", "/v1/tree", encoded({"app": self.app, "includeSystem": False}))
        tree = self.success(response, f"{name} tree succeeds")
        matches = nodes_with_id(tree, "fixture.counter.value")
        self.check(len(matches) == 1, f"{name} has one fixture counter", matches=len(matches))
        label = matches[0].get("label", "")
        match = re.fullmatch(r"Count:\s*(\d+)", label)
        self.check(match is not None, f"{name} counter is readable", label=label)
        return int(match.group(1))

    def write_report(self, status, failure=None):
        report = {
            "status": status,
            "app": self.app,
            "sessionEpoch": self.epoch,
            "elapsedSeconds": time.monotonic() - self.started,
            "requests": self.request_count,
            "assertions": self.assertions,
            "failure": failure,
            "scope": "Explicit fixture input. No device setup or input retries.",
        }
        (self.artifacts / "report.json").write_text(json.dumps(self.redact(report), indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def run(self):
        health = self.success(self.request("health", "GET", "/v1/health"), "health succeeds")
        self.epoch = health.get("sessionEpoch")
        try:
            epoch_valid = str(uuid.UUID(self.epoch)) == self.epoch
        except (ValueError, TypeError, AttributeError):
            epoch_valid = False
        self.check(epoch_valid, "health advertises a UUID epoch")
        self.check(health.get("busy") is False, "runner starts idle")
        baseline = self.counter("baseline")
        tap_body = encoded({"app": self.app, "target": {"query": {"id": "fixture.counter.increment"}}, "count": 1})
        tap_id = identifier()
        original = self.request("original increment", "POST", "/v1/tap", tap_body, tap_id)
        self.success(original, "first increment acknowledged")
        duplicate = self.request("duplicate increment", "POST", "/v1/tap", tap_body, tap_id)
        self.check(
            duplicate.status == original.status and duplicate.body == original.body,
            "duplicate completed request returns exact cached response",
        )
        self.check(self.counter("after duplicate") == baseline + 1, "same UUID increments counter exactly once", baseline=baseline)

        conflicting = encoded({"app": self.app, "target": {"query": {"id": "fixture.counter.increment"}}, "count": 2})
        self.error(
            self.request("conflicting body", "POST", "/v1/tap", conflicting, tap_id),
            "operation_conflict",
            "same ID with different bytes conflicts",
            409,
        )
        self.error(
            self.request("missing epoch", "POST", "/v1/tap", tap_body, epoch=None), "session_mismatch", "missing epoch rejects input", 409
        )
        self.error(
            self.request("wrong epoch", "POST", "/v1/tap", tap_body, epoch=identifier()),
            "session_mismatch",
            "wrong epoch rejects input",
            409,
        )
        self.error(
            self.request("invalid dispatch budget", "POST", "/v1/tap", tap_body, dispatch_budget=0),
            "bad_request",
            "zero dispatch budget rejects input",
            400,
        )
        self.check(self.counter("after rejected input") == baseline + 1, "conflict, epoch and budget rejection leave counter unchanged")

        wait_id = identifier()
        wait_body = encoded({"app": self.app, "query": {"id": f"fixture.missing.{identifier()}"}, "until": "exists", "timeoutMs": 2500})
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            waiting = pool.submit(self.request, "blocking wait", "POST", "/v1/wait", wait_body, wait_id)
            poll_deadline = time.monotonic() + 3
            active = False
            while time.monotonic() < poll_deadline and not waiting.done():
                polled = self.request("poll wait admission", "GET", "/v1/health", timeout=1.5)
                polled_health = self.success(polled, "admission health stays responsive")
                if polled_health.get("busy") is True and polled_health.get("currentOp") == wait_id:
                    active = True
                    break
                time.sleep(0.025)
            self.check(active, "wait occupies admission before competing requests")
            competing = pool.submit(self.request, "competing increment", "POST", "/v1/tap", tap_body)
            duplicate_running = pool.submit(self.request, "duplicate running wait", "POST", "/v1/wait", wait_body, wait_id)
            receipt = pool.submit(self.request, "running receipt", "GET", f"/v1/operations/{wait_id}", timeout=1.5)
            live_health = pool.submit(self.request, "busy health", "GET", "/v1/health", timeout=1.5)
            self.error(competing.result(timeout=5), "busy", "competing increment is rejected without queuing", 409)
            self.error(duplicate_running.result(timeout=5), "operation_in_progress", "duplicate active ID does not rerun", 409)
            receipt_response = receipt.result(timeout=5)
            running_receipt = self.success(receipt_response, "receipt lookup responds during wait")
            self.check(
                running_receipt.get("operation", {}).get("phase") == "running",
                "receipt reports running operation",
                elapsedSeconds=receipt_response.elapsed,
            )
            health_response = live_health.result(timeout=5)
            busy_health = self.success(health_response, "health responds during wait")
            self.check(
                busy_health.get("busy") is True and busy_health.get("currentOp") == wait_id and busy_health.get("queue") == 0,
                "health reports active operation and zero queue",
                elapsedSeconds=health_response.elapsed,
            )
            completed = waiting.result(timeout=12)

        self.error(completed, "timeout", "missing-selector wait completes with timeout", 504)
        terminal = self.success(self.request("terminal receipt", "GET", f"/v1/operations/{wait_id}"), "terminal receipt is available")
        saved_response = json.loads(terminal.get("responseJSON") or "null")
        self.check(
            terminal.get("operation", {}).get("phase") == "finished"
            and terminal.get("responseStatus") == 504
            and saved_response == completed.json,
            "terminal receipt preserves the failed wait response",
        )
        replay = self.request("replay completed wait", "POST", "/v1/wait", wait_body, wait_id, timeout=1.5)
        self.check(
            replay.status == completed.status and replay.body == completed.body and replay.elapsed < 1.5,
            "completed wait replays exact response without waiting again",
            elapsedSeconds=replay.elapsed,
        )
        self.check(self.counter("final") == baseline + 1, "busy rejection did not increment the counter")
        self.error(
            self.request("unknown receipt", "GET", f"/v1/operations/{identifier()}"),
            "receipt_unknown",
            "unknown receipt remains unknown and is never replayed",
            404,
        )

        self.error(
            self.request("malformed Siri request", "POST", "/v1/siri", encoded({})),
            "bad_request",
            "malformed Siri request is rejected before acceptance",
            400,
        )
        screenshot_id = identifier()
        screenshot = self.request("screenshot", "GET", "/v1/screenshot", operation_id=screenshot_id, timeout=30)
        self.check(
            screenshot.status == 200 and len(screenshot.body) > 65536, "screenshot exceeds receipt storage", bytes=len(screenshot.body)
        )
        self.error(
            self.request("replay screenshot", "GET", "/v1/screenshot", operation_id=screenshot_id),
            "result_not_retained",
            "oversized result replays as not retained",
            410,
        )

        tree = self.success(
            self.request("tree before Siri", "POST", "/v1/tree", encoded({"app": self.app, "includeSystem": False})),
            "tree before Siri succeeds",
        )
        refs = [node.get("ref") for node in nodes_with_id(tree, "fixture.counter.increment")]
        self.check(len(refs) == 1, "tree before Siri has the increment ref", refs=refs)
        siri_id = identifier()
        accepted = self.request("Siri request", "POST", "/v1/siri", encoded({"text": "what time is it"}), siri_id)
        operation = ((accepted.json or {}).get("result") or {}).get("operation") or {}
        self.check(
            accepted.status == 202 and operation.get("id") == siri_id and operation.get("phase") == "accepted",
            "Siri request is accepted with its receipt",
            status=accepted.status,
            response=accepted.json,
        )
        deadline = time.monotonic() + 180
        phase = "accepted"
        polls = 0
        readable = True
        while readable and phase != "finished" and time.monotonic() < deadline:
            time.sleep(1)
            polled = self.request("poll Siri receipt", "GET", f"/v1/operations/{siri_id}", timeout=5)
            polls += 1
            payload = polled.json or {}
            readable = polled.status == 200 and payload.get("ok") is True
            receipt = payload.get("result") or {}
            phase = receipt.get("operation", {}).get("phase")
        self.check(readable, "Siri receipt is readable", polls=polls, status=polled.status, response=polled.json)
        self.check(phase == "finished", "Siri receipt finishes within 180 seconds", responseStatus=receipt.get("responseStatus"))
        self.error(
            self.request("tap with pre-Siri ref", "POST", "/v1/tap", encoded({"app": self.app, "target": {"ref": refs[0]}})),
            "stale_ref",
            "ref from before Siri is rejected after Siri",
            404,
        )


def host_app(session):
    """Bundle ID of the host app that the session's xctestrun names."""
    xctestrun = Path(session.get("xctestrunPath") or "")
    if not xctestrun.is_file():
        return None
    for key, config in plistlib.loads(xctestrun.read_bytes()).items():
        if key != "__xctestrun_metadata__" and "UITargetAppPath" in config:
            app = Path(config["UITargetAppPath"].replace("__TESTROOT__", str(xctestrun.parent)))
            return plistlib.loads((app / "Info.plist").read_bytes()).get("CFBundleIdentifier")
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--session-file", type=Path, required=True, help="Existing runner session JSON. Its token is never printed.")
    parser.add_argument("--artifacts", type=Path, required=True, help="New directory for redacted request evidence and report.json.")
    parser.add_argument("--app", help="Already launched fixture bundle ID. Defaults to the session's host app.")
    args = parser.parse_args()
    harness = None
    try:
        session = json.loads(args.session_file.read_text(encoding="utf-8"))
        app = args.app or host_app(session)
        if not app:
            raise SmokeFailure("Could not read the host app from the session. Pass --app.")
        harness = Harness(session, args.artifacts, app)
        harness.run()
        harness.write_report("passed")
        print(f"Passed. Evidence: {args.artifacts / 'report.json'}")
        return 0
    except (Exception, KeyboardInterrupt) as error:
        interrupted = isinstance(error, KeyboardInterrupt)
        message = "Interrupted. Admitted operations may still execute. Do not replay input." if interrupted else str(error)
        if harness is not None:
            message = harness.redact(message)
            harness.write_report("interrupted" if interrupted else "failed", message)
        print(f"FAILED: {message}", file=sys.stderr)
        return 130 if interrupted else 1


if __name__ == "__main__":
    sys.exit(main())
