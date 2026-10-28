"""Exercise full/summary native metrics on an isolated, locally built Core.

Pass a Core executable as argv[1]; no installed App, user NAS, downloads or
external services are involved. stdin EOF must also stop the owned process.
"""
from __future__ import annotations

import base64
import json
import pathlib
import os
import selectors
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "dist/LightIsle.app/Contents/Resources/core/lightisled"
if not CORE.is_file():
    raise SystemExit("Pass the path to a locally built lightisled executable")

with tempfile.TemporaryDirectory(prefix="lightisle-metrics-ipc-") as directory:
    process = subprocess.Popen(
        [str(CORE), "-port", "0", "-web-root", "", "-data-dir", directory],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    messages: list[dict] = []
    try:
        assert process.stdin and process.stdout
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            pending = bytearray()

            def await_line(prefix: bytes) -> bytes:
                deadline = time.monotonic() + 15
                while True:
                    while b"\n" in pending:
                        line, _, rest = pending.partition(b"\n")
                        pending[:] = rest
                        if line.startswith(prefix):
                            return bytes(line)
                    remaining = deadline - time.monotonic()
                    assert remaining > 0, f"Timed out waiting for {prefix!r}"
                    assert process.poll() is None, "Core exited before replying"
                    if selector.select(remaining):
                        chunk = os.read(process.stdout.fileno(), 65536)
                        assert chunk, "Core stdout closed before replying"
                        pending.extend(chunk)

            await_line(b"LIGHTISLE_READY ")
            for command in (b"stats summary\n", b"stats\n"):
                process.stdin.write(command)
                process.stdin.flush()
                encoded = await_line(b"LIGHTISLE_STATS ").removeprefix(b"LIGHTISLE_STATS ")
                messages.append(json.loads(base64.urlsafe_b64decode(encoded + b"=" * (-len(encoded) % 4))))
        process.stdin.close()
        assert process.wait(timeout=8) == 0, "Core did not stop after parent EOF"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    assert len(messages) == 2, messages
    summary, full = messages
    assert "processes" not in summary and "processesAvailable" not in summary, summary.keys()
    for metrics in messages:
        assert metrics["hostname"] and metrics["architecture"] == "darwin/arm64", metrics
        assert metrics["memoryTotal"] > 0 and metrics["coreRssBytes"] > 0, metrics
        assert isinstance(metrics["volumes"], list), metrics
    assert full["processesAvailable"] is True and 0 < len(full["processes"]) <= 256, full
    print("PASS: background summary retains host/volume health, full metrics retains processes, parent EOF exits")
