"""Bundled Core regression: RootRegistry preserves offline disk identity.

All test directories live under a disposable home-volume fixture. Renaming a
directory is NOT unplugging a drive: a same-path replacement must never gain
the old root ID or permissions, even after the Core restarts. Removing a
registration is explicit and must not delete files on either directory.
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "dist/LightIsle.app/Contents/Resources/core/lightisled"
WEB = ROOT / "dist/LightIsle.app/Contents/Resources/web"

if not CORE.is_file():
    raise SystemExit("Build LightIsle.app before offline-root regression test")


def encode_json(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b"=").decode()


def decode_json(value):
    return json.loads(base64.urlsafe_b64decode(value + b"=" * (-len(value) % 4)))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Core:
    def __init__(self, data):
        self.proc = subprocess.Popen(
            [str(CORE), "-port", "0", "-web-root", str(WEB),
             "-data-dir", str(data)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.pending = bytearray()
        self.selector = selectors.DefaultSelector()
        assert self.proc.stdin and self.proc.stdout
        self.selector.register(self.proc.stdout, selectors.EVENT_READ)
        self.until(lambda line: line.startswith(b"LIGHTISLE_READY http://127.0.0.1:"))

    def until(self, predicate, timeout=20):
        deadline = time.monotonic() + timeout
        while True:
            while b"\n" in self.pending:
                raw, _, remaining = self.pending.partition(b"\n")
                self.pending = bytearray(remaining)
                if predicate(raw.strip()):
                    return raw.strip()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError("Core response timed out")
            if self.selector.select(remaining):
                chunk = os.read(self.proc.stdout.fileno(), 4096)
                if not chunk:
                    self.proc.wait(timeout=5)
                    errors = self.proc.stderr.read().decode(errors="replace")
                    raise AssertionError(
                        f"Core exited ({self.proc.returncode}): {errors[-3000:]}"
                    )
                self.pending.extend(chunk)

    def native(self, operation, **fields):
        request_id = uuid.uuid4().hex
        self.proc.stdin.write(
            ("roots " + operation + " " +
             encode_json({"requestID": request_id, **fields}) + "\n").encode()
        )
        self.proc.stdin.flush()
        while True:
            line = self.until(lambda item: item.startswith(b"LIGHTISLE_ROOTS "))
            response = decode_json(line.split(b" ", 1)[1])
            if response.get("requestID") == request_id:
                assert response["operation"] == operation, response
                return response

    def close(self):
        self.selector.close()
        if self.proc.poll() is None:
            self.proc.stdin.close()
            try:
                self.proc.wait(timeout=12)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        assert self.proc.returncode == 0, self.proc.stderr.read().decode(errors="replace")
        self.proc.stdout.close()
        self.proc.stderr.close()

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(timeout=5)
        self.selector.close()
        self.proc.stdout.close()
        self.proc.stderr.close()


with tempfile.TemporaryDirectory(prefix=".lightisle-root-identity-", dir=Path.home()) as temp:
    base = Path(temp).resolve()
    data = base / "private"
    data.mkdir(mode=0o700)
    original = base / "external-fixture"
    original.mkdir(mode=0o700)
    source = original / "keep.txt"
    source.write_text("preserve-original-volume", encoding="utf-8")
    source_hash = digest(source)
    detached = base / "renamed-original"

    core = Core(data)
    try:
        added = core.native("add", name="Fixture", path=str(original))
        assert "error" not in added, added
        root = added["result"]
        root_id, generation = root["rootID"], root["generation"]

        # Change the directory at the registered pathname, but keep the
        # original object on the same mounted home volume.
        original.rename(detached)
        original.mkdir(mode=0o700)
        (original / "replacement.txt").write_text("replacement", encoding="utf-8")
        listed = core.native("list")["result"]
        offline = next(item for item in listed if item["rootID"] == root_id)
        assert offline["online"] is False, offline

        replaced = core.native(
            "rebind", rootID=root_id, generation=generation, path=str(original)
        )
        assert replaced.get("error") == "root_registry_other_folder_requires_add", replaced
        assert digest(detached / "keep.txt") == source_hash
        core.close()
        core = None

        # Restart cannot promote a same-name replacement into the old ID.
        core = Core(data)
        listed = core.native("list")["result"]
        offline = next(item for item in listed if item["rootID"] == root_id)
        assert not offline["online"] and offline["generation"] == generation, offline
        same_path = core.native(
            "rebind", rootID=root_id, generation=generation, path=str(original)
        )
        assert same_path.get("error") == "root_registry_other_folder_requires_add", same_path

        # The original physical directory can be reconnected explicitly at
        # its new pathname without inheriting the replacement directory.
        recovered = core.native(
            "rebind", rootID=root_id, generation=generation, path=str(detached)
        )
        assert "error" not in recovered, recovered
        assert recovered["result"]["generation"] > generation, recovered
        new_generation = recovered["result"]["generation"]
        stale = core.native("remove", rootID=root_id, generation=generation)
        assert stale.get("error") == "root_registry_stale", stale

        removed = core.native("remove", rootID=root_id, generation=new_generation)
        assert "error" not in removed, removed
        assert all(item["rootID"] != root_id for item in core.native("list")["result"])
        assert digest(detached / "keep.txt") == source_hash
        assert (original / "replacement.txt").read_text() == "replacement"
        core.close()
        core = None

        core = Core(data)
        assert all(item["rootID"] != root_id for item in core.native("list")["result"])
        core.close()
        core = None
        print("PASS: RootRegistry preserves offline identity, rejects replacement, "
              "allows original rebind and removes only registration")
    finally:
        if core is not None:
            core.kill()
