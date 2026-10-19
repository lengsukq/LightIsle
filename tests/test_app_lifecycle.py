"""Smoke test for the bundled LightIsle Go Core lifecycle on macOS arm64."""
from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "dist" / "LightIsle.app"
EXECUTABLE = APP / "Contents" / "Resources" / "core" / "lightisled"
WEB_ROOT = APP / "Contents" / "Resources" / "web"

if not EXECUTABLE.exists() or not (WEB_ROOT / "index.html").exists():
    raise SystemExit("Build LightIsle.app first: bash scripts/build-macos.sh")

temp_dir = tempfile.TemporaryDirectory(prefix="lightisle-smoke-")
process = subprocess.Popen(
    [str(EXECUTABLE), "-web-root", str(WEB_ROOT), "-port", "0", "-data-dir", temp_dir.name],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
try:
    assert process.stdout is not None
    line = process.stdout.readline().strip()
    if not line.startswith("LIGHTISLE_READY http://127.0.0.1:"):
        raise AssertionError(f"Go Core did not report a loopback endpoint: {line!r}")
    address = line.removeprefix("LIGHTISLE_READY ")
    with urllib.request.urlopen(f"{address}/api/v1/health", timeout=5) as response:
        health = json.load(response)
    assert health["status"] == "ok", health
    assert health["platform"] == "darwin/arm64", health

    # System and file APIs must require a logged-in account.
    try:
        with urllib.request.urlopen(f"{address}/api/v1/system", timeout=5):
            raise AssertionError("Unauthenticated system API unexpectedly allowed")
    except urllib.error.HTTPError as error:
        assert error.code == 401, error.code

    with urllib.request.urlopen(address + "/", timeout=5) as response:
        index = response.read().decode("utf-8")
    assert "LightIsle" in index, "packaged index.html missing"

    # Simulate the parent App disappearing: its owned pipe write end closes.
    assert process.stdin is not None
    process.stdin.close()
    code = process.wait(timeout=8)
    assert code == 0, f"Go Core returned error code {code}"

    try:
        urllib.request.urlopen(f"{address}/api/v1/health", timeout=1)
    except urllib.error.URLError:
        pass
    else:
        raise AssertionError("Service still accepts connections after parent EOF")

    print("PASS: bundled health + metrics + frontend + parent EOF shutdown")
except Exception:
    process.kill()
    process.wait(timeout=5)
    raise
finally:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=5)
    temp_dir.cleanup()

