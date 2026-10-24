"""Core smoke test for offline-share cleanup safety using a home-volume fixture.

The fixture directory is renamed while its containing physical volume remains
mounted. This is deliberately not treated as an unplug simulation: Core must
reject cleanup before and after restart because the saved VolumeUUID is still
present. No external volume or disk utility mutation is used.
"""
import base64
import hashlib
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


def file_hash(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def start_core(data: pathlib.Path):
    proc = subprocess.Popen(
        [str(CORE), "-port", "0", "-web-root", str(WEB), "-data-dir", str(data)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=False,
    )
    assert proc.stdin and proc.stdout
    received = bytearray()
    watcher = selectors.DefaultSelector()
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

    return proc, received, watcher, until, send


def wait_for_mounted_rejection(received, until, send, root: pathlib.Path) -> None:
    expected = b"LIGHTISLE_SHARE_FORGET_ERROR shared_directory_confirmation_required"
    for _ in range(30):
        if expected in received:
            break
        send("share forget " + encode(str(root)))
        try:
            until(expected, timeout=1.0)
        except AssertionError:
            pass
    assert expected in received, f"Core did not reject a still-mounted bound volume: {received[-1600:]!r}"
    assert b"LIGHTISLE_SHARE_FORGOT " not in received, "Core forgot a root whose volume is still mounted"


def stop_core(proc, watcher) -> None:
    assert proc.stdin
    proc.stdin.close()
    proc.wait(timeout=10)
    watcher.close()
    assert proc.returncode == 0, proc.stderr.read(4096) if proc.stderr else ""


with tempfile.TemporaryDirectory(prefix=".lightisle-offline-forget-", dir=pathlib.Path.home()) as temp:
    workspace = pathlib.Path(temp)
    data = workspace / "private"
    data.mkdir(mode=0o700)
    old = workspace / "external-fixture"
    old.mkdir(mode=0o700)
    source = old / "keep.txt"
    source.write_text("preserve-old-drive", encoding="utf-8")
    original_hash = file_hash(source)
    detached = workspace / "renamed-fixture"

    proc, received, watcher, until, send = start_core(data)
    try:
        until(b"LIGHTISLE_READY http://127.0.0.1:")
        until(b"LIGHTISLE_SHARE_PATH ")
        send("share set " + encode(str(old)))
        until(b"LIGHTISLE_SHARE_PATH " + encode(str(old)).encode())

        # The active root cannot be forgotten.
        send("share forget " + encode(str(old)))
        until(b"LIGHTISLE_SHARE_FORGET_ERROR ")

        # A missing saved directory is not proof that its physical volume was
        # unplugged. The backing home volume is still mounted at another path.
        old.rename(detached)
        old.mkdir(mode=0o700)
        send("share status")
        until(b"LIGHTISLE_SHARE_STATUS 0")
        until(b"LIGHTISLE_SHARE_OFFLINE_PATH " + encode(str(old)).encode())
        send("share forget " + encode(str(workspace / "wrong")))
        until(b"LIGHTISLE_SHARE_FORGET_ERROR ")
        wait_for_mounted_rejection(received, until, send, old)
        assert file_hash(detached / "keep.txt") == original_hash

        stop_core(proc, watcher)
        proc = None

        # Restart proves the offline identity remains durable and cleanup still
        # refuses while that VolumeUUID is mounted.
        proc, received, watcher, until, send = start_core(data)
        until(b"LIGHTISLE_READY http://127.0.0.1:")
        until(b"LIGHTISLE_SHARE_OFFLINE_PATH " + encode(str(old)).encode())
        wait_for_mounted_rejection(received, until, send, old)
        assert file_hash(detached / "keep.txt") == original_hash
        assert (detached / "keep.txt").read_text(encoding="utf-8") == "preserve-old-drive"
        stop_core(proc, watcher)
        proc = None
        print("PASS: Core preserves the bound offline root and refuses cleanup while its volume remains mounted")
    finally:
        if proc is not None:
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
            watcher.close()
