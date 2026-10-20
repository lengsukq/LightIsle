#!/usr/bin/env python3
"""Bundled Go Core: Mac-only export IPC, verified tree and no public export API."""
from __future__ import annotations

import base64
import hashlib
import json
import pathlib
import subprocess
import tempfile
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "dist/LightIsle.app/Contents/Resources/core/lightisled"
WEB = ROOT / "dist/LightIsle.app/Contents/Resources/web"


def encoded(value: object) -> str:
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")


def decode(value: str) -> str:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)).decode()


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="lightisle-export-core-") as data:
        with tempfile.TemporaryDirectory(prefix="lightisle-export-target-", dir=str(pathlib.Path.home())) as dst:
            share = pathlib.Path(data) / "SharedFiles"
            source = share / "media"
            source.mkdir(parents=True)
            payload = b"copy-verified-NAS-test" * 1024
            (source / "a.bin").write_bytes(payload)
            (source / "sub").mkdir()
            (source / "sub" / "b.bin").write_bytes(payload * 2)
            proc = subprocess.Popen(
                [str(CORE), "-port", "0", "-web-root", str(WEB), "-data-dir", data],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, bufsize=1,
            )
            try:
                assert proc.stdin and proc.stdout
                ready = proc.stdout.readline().strip()
                assert ready.startswith("LIGHTISLE_READY http://127.0.0.1:"), ready
                assert proc.stdout.readline().strip() == "LIGHTISLE_CONFIGURED 0"
                assert proc.stdout.readline().strip() == "LIGHTISLE_SHARE_ON SharedFiles"
                assert proc.stdout.readline().startswith("LIGHTISLE_SHARE_PATH ")

                request = urllib.request.Request(
                    ready.removeprefix("LIGHTISLE_READY ") + "/api/v1/export",
                    method="POST", headers={"X-LightIsle-Request": "1"},
                )
                try:
                    urllib.request.urlopen(request, timeout=3)
                    raise AssertionError("Cross-volume export accidentally available over HTTP")
                except urllib.error.HTTPError as error:
                    assert error.code in (404, 405), error.code

                def cmd(command: str) -> str:
                    proc.stdin.write(command + "\n")
                    proc.stdin.flush()
                    return proc.stdout.readline().strip()

                start = "export start " + encoded({"source": "media", "destination": dst})
                assert cmd(start) == "LIGHTISLE_EXPORT_STARTED"
                result = proc.stdout.readline().strip()
                assert result.startswith("LIGHTISLE_EXPORT_OK "), result
                target = pathlib.Path(decode(result.removeprefix("LIGHTISLE_EXPORT_OK ")))
                assert target == pathlib.Path(dst) / "media"
                for rel, expected in (("a.bin", payload), ("sub/b.bin", payload * 2)):
                    actual = (target / rel).read_bytes()
                    assert hashlib.sha256(actual).digest() == hashlib.sha256(expected).digest()
                assert (source / "a.bin").read_bytes() == payload
                assert cmd(start) == "LIGHTISLE_EXPORT_STARTED"
                duplicate = proc.stdout.readline().strip()
                assert duplicate.startswith("LIGHTISLE_EXPORT_ERROR "), duplicate
                assert decode(duplicate.removeprefix("LIGHTISLE_EXPORT_ERROR ")) == "file_already_exists"
                proc.stdin.close()
                assert proc.wait(timeout=15) == 0
                print("PASS: Mac-only cross-volume export, verified tree, no overwrite, original preserved, IPC teardown")
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=5)


if __name__ == "__main__":
    main()
