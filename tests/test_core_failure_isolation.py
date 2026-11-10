"""Exercise Core failures against a temporary data directory and loopback only."""
from __future__ import annotations

import base64
import http.cookiejar
import json
import os
import signal
import time
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
CORE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "dist/LightIsle.app/Contents/Resources/core/lightisled"
ACCOUNT = {"username": "resident-qa", "password": "local-fixture-passphrase-2026"}


def encode(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")


def read_json(line):
    text = line.split(" ", 1)[1]
    return json.loads(base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)))


with tempfile.TemporaryDirectory(prefix=".lightisle-core-isolation-", dir=ROOT) as temporary:
    base = Path(temporary)
    data = base / "data"
    data.mkdir()
    (data / "tasks.sqlite").write_text("deliberately invalid SQLite fixture")
    (data / "config-backup-schedule.json").write_text("deliberately invalid JSON fixture")
    share = base / "files"
    share.mkdir()
    (share / "retained.txt").write_text("files remain available")

    core = subprocess.Popen(
        [str(CORE), "-port", "0", "-data-dir", str(data)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, bufsize=1,
    )
    lines = queue.Queue()

    def pump():
        for item in core.stdout:
            lines.put(item.rstrip())
        lines.put(None)

    threading.Thread(target=pump, daemon=True).start()

    def wait_line(prefix):
        while (line := lines.get(timeout=20)) is not None:
            if line.startswith(prefix):
                return line
        raise AssertionError(f"Core stopped before reporting {prefix}")

    def send(command):
        core.stdin.write(command + "\n")
        core.stdin.flush()

    try:
        address = wait_line("LIGHTISLE_READY ").split(" ", 1)[1]
        assert wait_line("LIGHTISLE_SERVICE_WARNING ") == "LIGHTISLE_SERVICE_WARNING task_history"
        assert wait_line("LIGHTISLE_SERVICE_WARNING ") == "LIGHTISLE_SERVICE_WARNING backup_schedule"
        send("backup schedule status")
        assert read_json(wait_line("LIGHTISLE_BACKUP_SCHEDULE "))["lastError"] == "backup_schedule_unavailable"
        send("admin init " + encode(ACCOUNT))
        wait_line("LIGHTISLE_INITIALIZED")
        send("roots add " + encode({"requestID": uuid.uuid4().hex, "name": "Test disk", "path": str(share)}))
        root = read_json(wait_line("LIGHTISLE_ROOTS "))["result"]
        (data / f"gallery-root-{root['rootID']}.sqlite").write_text("deliberately invalid gallery index")

        client = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        )

        def request(path, status=200, body=None):
            headers = {"X-LightIsle-Request": "1", "Content-Type": "application/json"}
            req = urllib.request.Request(address + path, headers=headers,
                                         data=json.dumps(body).encode() if body is not None else None)
            try:
                response = client.open(req, timeout=10)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                result = response.read()
                assert response.status == status, (path, response.status, result[:300])
                return result

        request("/api/v2/auth/login", body=ACCOUNT)
        route = f"/api/v2/roots/{root['rootID']}"
        assert json.loads(request(route + "/photos/status", 503))["error"] == "gallery_unavailable"
        request(route + "/cinema/status")
        assert request(route + "/files/content?path=retained.txt") == b"files remain available"
        assert json.loads(request("/api/v2/health"))["status"] == "ok"

        other = base / "port-conflict"
        port = urllib.parse.urlsplit(address).port
        blocked = subprocess.run([str(CORE), "-port", str(port), "-data-dir", str(other)],
                                 stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
        assert blocked.returncode == 73, blocked.stderr.decode()
        assert (data / "tasks.sqlite").read_text() == "deliberately invalid SQLite fixture"
        assert (data / "config-backup-schedule.json").read_text() == "deliberately invalid JSON fixture"
        print("PASS: corrupt task history, backup schedule and gallery are isolated; files and cinema remain available; port conflict is classified")
    finally:
        if core.poll() is None:
            core.stdin.close()
            try:
                core.wait(timeout=10)
            except subprocess.TimeoutExpired:
                core.kill()
                core.wait(timeout=5)


# Keep the stdin write end alive in this test runner after Core's real parent
# exits. This distinguishes the parent PID guard from ordinary pipe EOF.
with tempfile.TemporaryDirectory(prefix="lightisle-orphan-") as data_dir:
    read_fd, write_fd = os.pipe()
    pid = None
    try:
        parent = subprocess.run([
            sys.executable, "-c",
            """
import json, pathlib, subprocess, sys, time
stdout = pathlib.Path(sys.argv[2]) / "core-stdout.log"
with stdout.open("w") as output:
    core = subprocess.Popen([sys.argv[1], "-port", "0", "-data-dir", sys.argv[2]],
                            stdin=int(sys.argv[3]), stdout=output, stderr=subprocess.DEVNULL)
deadline = time.monotonic() + 8
while time.monotonic() < deadline:
    for line in stdout.read_text().splitlines():
        if line.startswith("LIGHTISLE_READY "):
            print(json.dumps([core.pid, line.split(" ", 1)[1]]), flush=True)
            sys.exit(0)
    time.sleep(0.05)
core.kill()
core.wait()
raise RuntimeError("test child did not report READY")
""", str(CORE), data_dir, str(read_fd),
        ], pass_fds=(read_fd,), capture_output=True, text=True, check=True, timeout=20)
        pid, address = json.loads(parent.stdout)
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with client.open(address + "/api/v2/health", timeout=2) as response:
            assert response.status == 200
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            try:
                with client.open(address + "/api/v2/health", timeout=1) as response:
                    assert response.status == 200
            except urllib.error.URLError:
                break
            time.sleep(0.2)
        else:
            raise AssertionError("orphaned Core retained its listener with inherited stdin")
        print("PASS: Core detects its lost parent even when another process retains the stdin writer")
        pid = None
    finally:
        os.close(read_fd)
        os.close(write_fd)
        if pid is not None:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
