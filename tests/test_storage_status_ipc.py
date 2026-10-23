"""Beta 2: Core owner-only storage-state IPC, simulated same-name disk swap.

No real storage device or user data is accessed; everything lives in a
throwaway private root. Core must fail closed on a replacement directory.
"""
import pathlib
import os
import selectors
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
CORE = ROOT / "dist/LightIsle.app/Contents/Resources/core/lightisled"
WEB = ROOT / "dist/LightIsle.app/Contents/Resources/web"

if not CORE.is_file():
    raise SystemExit("Build LightIsle.app before storage IPC smoke test")

# Create only throwaway test data on the Mac home volume.
with tempfile.TemporaryDirectory(prefix=".lightisle-beta2-identity-", dir=pathlib.Path.home()) as temp:
    data = pathlib.Path(temp)
    original = data / "SharedFiles"
    replacement = data / "detached-original"
    proc = subprocess.Popen(
        [str(CORE), "-port", "0", "-web-root", str(WEB), "-data-dir", str(data)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        assert proc.stdin and proc.stdout
        received = bytearray()
        with selectors.DefaultSelector() as watcher:
            watcher.register(proc.stdout, selectors.EVENT_READ)

            def await_message(value: bytes, timeout: float = 12.0) -> None:
                deadline = time.monotonic() + timeout
                while value not in received:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0, f"timed out waiting for {value!r}: {received[-2048:]!r}"
                    assert proc.poll() is None, f"Core exited while waiting for {value!r}"
                    if watcher.select(timeout=remaining):
                        chunk = os.read(proc.stdout.fileno(), 4096)
                        assert chunk, f"Core output ended while waiting for {value!r}"
                        received.extend(chunk)

            # Do not replace a folder while the startup diskutil identity
            # Capture/Verify calls are still in flight. It is correct for
            # Core to reject a directory renamed during identity capture.
            await_message(b"LIGHTISLE_READY http://127.0.0.1:")
            await_message(b"LIGHTISLE_SHARE_PATH ")

            # This is a trusted private parent pipe, not an HTTP route.
            proc.stdin.write("share status\n")
            proc.stdin.flush()
            await_message(b"LIGHTISLE_SHARE_STATUS 1")
            original.rename(replacement)
            original.mkdir(mode=0o700)
            proc.stdin.write("share status\n")
            proc.stdin.flush()
            await_message(b"LIGHTISLE_SHARE_STATUS 0")

        proc.stdin.close()
        proc.wait(timeout=8)
        output = received.decode("utf-8", errors="replace") + proc.stdout.read()
        logs = proc.stderr.read(4096) if proc.stderr else ""
        assert proc.returncode == 0, f"Core exit {proc.returncode}"
        assert output.count("LIGHTISLE_SHARE_STATUS 1") == 1, output + "\n" + logs
        assert output.count("LIGHTISLE_SHARE_STATUS 0") == 1, output + "\n" + logs
        assert "LIGHTISLE_READY http://127.0.0.1:" in output, output
        print("PASS: owner-only share status reports online then offline after a same-name directory replacement")
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
