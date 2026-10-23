"""Owner-only offline-share cleanup smoke test with disposable home folders.

No real external volumes, existing user directories, or disk erase tools are
accessed. The old folder is renamed to emulate an unplugged volume.
"""
import base64
import os
import pathlib
import selectors
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "dist/LightIsle.app/Contents/Resources/core/lightisled"
WEB = ROOT / "dist/LightIsle.app/Contents/Resources/web"
if not CORE.is_file():
    raise SystemExit("Build LightIsle.app before offline-share cleanup smoke test")

def encode(value: str) -> str:
    return base64.urlsafe_b64encode(value.encode()).rstrip(b"=").decode()

with tempfile.TemporaryDirectory(prefix=".lightisle-offline-forget-", dir=pathlib.Path.home()) as temp:
    workspace = pathlib.Path(temp)
    data = workspace / "private"
    data.mkdir(mode=0o700)
    old = workspace / "external-fixture"
    old.mkdir(mode=0o700)
    (old / "keep.txt").write_text("preserve-old-drive", encoding="utf-8")
    detached = workspace / "unmounted-fixture"

    proc = subprocess.Popen(
        [str(CORE), "-port", "0", "-web-root", str(WEB), "-data-dir", str(data)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=False,
    )
    try:
        assert proc.stdin and proc.stdout
        received = bytearray()
        with selectors.DefaultSelector() as watcher:
            watcher.register(proc.stdout, selectors.EVENT_READ)
            def until(expected: bytes, timeout: float = 15.0) -> None:
                deadline = time.monotonic() + timeout
                while expected not in received:
                    assert proc.poll() is None, f"Core ended: {received[-1000:]!r}"
                    remaining = deadline - time.monotonic()
                    assert remaining > 0, f"missing {expected!r}: {received[-1400:]!r}"
                    if watcher.select(remaining):
                        chunk = os.read(proc.stdout.fileno(), 4096)
                        assert chunk, "Core output ended"
                        received.extend(chunk)
            def send(line: str) -> None:
                proc.stdin.write((line + "\n").encode())
                proc.stdin.flush()

            until(b"LIGHTISLE_READY http://127.0.0.1:")
            until(b"LIGHTISLE_SHARE_PATH ")
            send("share set " + encode(str(old)))
            until(b"LIGHTISLE_SHARE_PATH " + encode(str(old)).encode())
            # The active root is always protected, even with a matching path.
            send("share forget " + encode(str(old)))
            until(b"LIGHTISLE_SHARE_FORGET_ERROR ")
            old.rename(detached)
            old.mkdir(mode=0o700)  # A replacement under the identical path.
            send("share status")
            until(b"LIGHTISLE_SHARE_STATUS 0")
            until(b"LIGHTISLE_SHARE_OFFLINE_PATH " + encode(str(old)).encode())
            send("share forget " + encode(str(workspace / "wrong")))
            # The stale/incorrect request cannot change the original binding.
            deadline = time.monotonic() + 10
            while received.count(b"LIGHTISLE_SHARE_FORGET_ERROR") < 2:
                assert time.monotonic() < deadline
                assert watcher.select(1)
                received.extend(os.read(proc.stdout.fileno(), 4096))

            # A scan started by the preceding share selection may still be
            # draining. The Core must refuse unsafe cleanup until idle.
            expected = b"LIGHTISLE_SHARE_FORGOT " + encode(str(old)).encode()
            for _ in range(30):
                send("share forget " + encode(str(old)))
                timeout_at = time.monotonic() + 0.7
                while time.monotonic() < timeout_at and expected not in received:
                    if watcher.select(max(0.01, timeout_at - time.monotonic())):
                        received.extend(os.read(proc.stdout.fileno(), 4096))
                if expected in received:
                    break
            assert expected in received, f"offline cleanup still refused when idle: {received[-1600:]!r}"
            until(b"LIGHTISLE_SHARE_PATH " + encode(str((data / "SharedFiles").resolve())).encode())
            assert (detached / "keep.txt").read_text(encoding="utf-8") == "preserve-old-drive"
            assert proc.poll() is None
        proc.stdin.close()
        proc.wait(timeout=10)
        assert proc.returncode == 0, proc.stderr.read(4096) if proc.stderr else ""
        print("PASS: offline share cleanup is owner-only, rejects active/stale paths, preserves detached files")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
