"""Validate native-only first-run initialization using the bundled Go process.

The test simulates the SwiftUI owner via stdin. It does not open a GUI or LAN port.
"""
from __future__ import annotations

import base64
import http.cookiejar
import json
import pathlib
import subprocess
import tempfile
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXECUTABLE = ROOT / "dist/LightIsle.app/Contents/Resources/core/lightisled"
WEB_ROOT = ROOT / "dist/LightIsle.app/Contents/Resources/web"
assert EXECUTABLE.exists(), "Build LightIsle.app before running test"


def native_command(proc: subprocess.Popen[str], command: str, expected: str) -> str:
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(command + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline().strip()
    if not line.startswith(expected):
        raise AssertionError(f"Expected {expected}, received {line}")
    return line


with tempfile.TemporaryDirectory(prefix="lightisle-native-init-") as data_dir:
    proc = subprocess.Popen(
        [str(EXECUTABLE), "-port", "0", "-data-dir", data_dir, "-web-root", str(WEB_ROOT)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1
    )
    try:
        assert proc.stdout is not None
        ready = proc.stdout.readline().strip()
        assert ready.startswith("LIGHTISLE_READY http://127.0.0.1:"), ready
        base_url = ready.removeprefix("LIGHTISLE_READY ")
        assert proc.stdout.readline().strip() == "LIGHTISLE_CONFIGURED 0"
        assert proc.stdout.readline().startswith("LIGHTISLE_SHARE_ON ")

        def request(path: str, method: str = "GET", payload: dict | None = None, opener=None):
            headers = {}
            data = None
            if payload is not None:
                data = json.dumps(payload).encode("utf-8")
                headers = {"Content-Type": "application/json", "X-LightIsle-Request": "1"}
            req = urllib.request.Request(base_url + path, data=data, method=method, headers=headers)
            return opener.open(req, timeout=5) if opener else urllib.request.urlopen(req, timeout=5)

        credentials = {"username": "first_owner", "password": "a-long-test-password-2026"}
        for path in ("/api/v1/auth/setup", "/api/v1/auth/reset", "/api/v1/admin/reset"):
            try:
                with request(path, "POST", credentials):
                    raise AssertionError("HTTP unexpectedly allowed first-run initialization")
            except urllib.error.HTTPError as exc:
                assert exc.code in (404, 405), exc.code

        encoded = base64.urlsafe_b64encode(json.dumps(credentials).encode()).rstrip(b"=").decode()
        native_command(proc, "admin init " + encoded, "LIGHTISLE_INITIALIZED")
        with request("/api/v1/auth/status") as response:
            assert json.load(response)["configured"] is True

        native_command(proc, "stats", "LIGHTISLE_STATS ")
        jar = http.cookiejar.CookieJar()
        client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        with request("/api/v1/auth/login", "POST", credentials, opener=client) as response:
            assert json.load(response)["role"] == "admin"
        with request("/api/v1/auth/me", opener=client) as response:
            assert json.load(response)["username"] == "first_owner"
        native_command(proc, "admin init " + encoded, "LIGHTISLE_INIT_ERROR already_configured")
        assert proc.stdin is not None
        proc.stdin.close()
        assert proc.wait(timeout=10) == 0, "Go Core remained after parent pipe was closed"
        print("PASS: native-only initialization, HTTP blocked, metrics IPC, Web login, and parent EOF")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)

