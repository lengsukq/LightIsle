"""Exercise the actual bundled root factory and private owner pipe with disposable data."""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.cookiejar
import io
import json
import os
from pathlib import Path
import queue
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
BUNDLE = PROJECT / "dist/LightIsle.app/Contents/Resources"
PASSWORD = "Local-preview-only-2026!"


def encode(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")


def decode(value):
    return json.loads(base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)))


class Fixture:
    def __init__(self):
        self.temporary = tempfile.TemporaryDirectory(prefix=".lightisle-root-preview-", dir=Path.home())
        self.base = Path(self.temporary.name).resolve()
        self.data = self.base / "private"
        self.paths = [self.base / "disk-a", self.base / "disk-b"]
        self.destination = self.base / "backup-target"
        self.lines = queue.Queue()
        self.core = None
        self.errors = None
        try:
            for path in [self.data, self.destination, *self.paths]:
                path.mkdir(mode=0o700)
            for index, path in enumerate(self.paths):
                (path / "same.txt").write_text(f"This file belongs to directory {'AB'[index]}.\n")
                (path / "family").mkdir(mode=0o700)
                (path / "family/member.txt").write_text(f"family-{'AB'[index]}")
            maker = self.base / "fixture-maker"
            subprocess.run(["swiftc", "-parse-as-library", str(PROJECT / "tests/MediaWorkerFixtureMaker.swift"), "-o", str(maker)], check=True, capture_output=True)
            subprocess.run([str(maker), "heic", str(self.paths[0] / "same.heic")], check=True)
            shutil.copyfile(self.paths[0] / "same.heic", self.paths[1] / "same.heic")
            self.originals = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                              for root in self.paths for path in root.rglob("*") if path.is_file()}
            self.start()
            self.send("admin init " + encode({"username": "previewadmin", "password": PASSWORD}))
            self.wait_line("LIGHTISLE_INITIALIZED")
            self.admin = self.login("previewadmin")
            self.roots = [self.native("add", name=name, path=str(path))["result"]
                          for name, path in zip(["照片盘 A", "影像盘 B"], self.paths)]
            self.members = []
            for index, name in enumerate(["previewreader", "previewother"]):
                member = self.request(self.admin, "/api/v1/users", method="POST",
                                      body={"username": name, "password": PASSWORD, "role": "member"}, expected=201)
                root = self.roots[index]
                self.request(self.admin, self.route(root, f"/users/{member['id']}/file-grants"), method="PUT",
                             body={"path": ".", "canWrite": False}, root=root)
                self.members.append(self.login(name))
        except BaseException:
            self.close()
            raise

    def start(self):
        self.errors = (self.base / "core.stderr").open("w+")
        self.core = subprocess.Popen([
            str(BUNDLE / "core/lightisled"), "-port", "0", "-data-dir", str(self.data),
            "-web-root", str(BUNDLE / "web"), "-multi-root-preview",
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors, text=True, bufsize=1)
        self.lines = queue.Queue()
        threading.Thread(target=self.pump, args=(self.core.stdout, self.lines), daemon=True).start()
        self.endpoint = self.wait_line("LIGHTISLE_READY ").split(" ", 1)[1]

    @staticmethod
    def pump(stream, lines):
        for line in stream:
            lines.put(line.strip())
        lines.put(None)

    def wait_line(self, prefix):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            line = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            if line is None:
                self.errors.flush()
                raise AssertionError("Core exited: " + (self.base / "core.stderr").read_text()[-3000:])
            if line.startswith(prefix):
                return line
        raise AssertionError("No native response for " + prefix)

    def send(self, command):
        self.core.stdin.write(command + "\n")
        self.core.stdin.flush()

    def native(self, operation, **request):
        request_id = uuid.uuid4().hex
        self.send("roots " + operation + " " + encode({"requestID": request_id, **request}))
        reply = decode(self.wait_line("LIGHTISLE_ROOTS ").split(" ", 1)[1])
        assert reply["requestID"] == request_id, reply
        return reply

    def login(self, username):
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.request(opener, "/api/v1/auth/login", method="POST", body={"username": username, "password": PASSWORD})
        return opener

    @staticmethod
    def route(root, suffix):
        return "/api/v2/roots/" + root["rootID"] + suffix

    def request(self, opener, path, method="GET", body=None, root=None, expected=200, raw=False, headers=None):
        request_headers = {"X-LightIsle-Request": "1", **(headers or {})}
        if root is not None:
            request_headers["X-LightIsle-Root-Generation"] = str(root["generation"])
        payload = body
        if isinstance(body, dict):
            payload = json.dumps(body).encode()
            request_headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.endpoint + path, data=payload, method=method, headers=request_headers)
        try:
            response = opener.open(request, timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            data = response.read()
            assert response.status == expected, (method, path, response.status, data[:300])
            return data if raw else json.loads(data)

    def backup_status(self, root):
        reply = self.native("backup-status", rootID=root["rootID"], generation=root["generation"])
        assert "error" not in reply, reply
        return reply["result"]["status"]

    def wait_backup(self, root):
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            status = self.backup_status(root)
            if not status["running"]:
                assert not status.get("lastError"), status
                return status
            time.sleep(0.1)
        raise AssertionError("Root backup did not finish")

    def exercise(self):
        a, b = self.roots
        discovery = self.request(self.members[0], "/api/v2/roots")["roots"]
        assert [item["rootID"] for item in discovery] == [a["rootID"]]
        assert all("path" not in item and "binding" not in item for item in discovery)
        for index, root in enumerate(self.roots):
            content = self.request(self.admin, self.route(root, "/files/content?path=same.txt"), root=root, raw=True)
            assert content == (self.paths[index] / "same.txt").read_bytes()
            verified = self.request(self.members[index], self.route(root, "/files/sha256?path=same.txt"), root=root)
            assert verified == {"algorithm": "sha256", "sha256": hashlib.sha256(content).hexdigest(), "size": len(content)}
            # The same path in another root must not become a content hash oracle.
            self.request(self.members[1-index], self.route(root, "/files/sha256?path=same.txt"), root=root, expected=404)
        self.request(self.members[0], self.route(b, "/files?path=.") , expected=404)
        self.request(self.members[0], self.route(a, "/files/folders"), method="POST", body={"path": "denied"}, root=a, expected=403)
        self.request(self.admin, self.route(a, "/files/folders"), method="POST", body={"path": "only-a"}, root=a, expected=201)
        assert (self.paths[0] / "only-a").is_dir() and not (self.paths[1] / "only-a").exists()
        archive = self.request(self.members[0], self.route(a, "/files/archive?path=family"), root=a, raw=True)
        with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
            assert zipped.read("family/member.txt") == b"family-A"
        upload = self.request(self.admin, self.route(a, "/uploads"), method="POST", body={"path": "uploaded.txt", "size": 4}, root=a, expected=201)
        self.request(self.admin, self.route(b, "/uploads/" + upload["id"]), root=b, expected=404)
        self.request(self.admin, self.route(a, "/uploads/" + upload["id"]), method="PATCH", body=b"root", root=a, headers={"X-Upload-Offset": "0"})
        self.request(self.admin, self.route(a, "/uploads/" + upload["id"] + "/complete"), method="POST", body={}, root=a)
        assert (self.paths[0] / "uploaded.txt").read_bytes() == b"root" and not (self.paths[1] / "uploaded.txt").exists()
        for root in self.roots:
            self.request(self.admin, self.route(root, "/photos/scan"), method="POST", body={}, root=root, expected=202)
        for root in self.roots:
            deadline = time.monotonic() + 20
            while self.request(self.admin, self.route(root, "/photos/status"), root=root)["status"]["running"]:
                assert time.monotonic() < deadline
                time.sleep(0.05)
        album = self.request(self.members[0], self.route(a, "/photos/private-albums"), method="POST", body={"name": "只读成员的私人相册"}, root=a, expected=201)
        photos = self.request(self.members[0], self.route(a, "/photos"), root=a)["assets"]
        assert len(photos) == 1, photos
        self.request(self.members[0], self.route(a, f"/photos/private-albums/{album['id']}/items"), method="POST", body={"assetID": photos[0]["id"]}, root=a)
        share = self.request(self.members[0], self.route(a, "/file-shares"), method="POST", body={"path": "same.txt", "hours": 1}, root=a, expected=201)
        self.request(self.admin, self.route(b, "/public/file/" + share["token"]), expected=404, raw=True)
        denied_backup = self.native("backup-start", rootID=a["rootID"], generation=a["generation"], path=str(self.paths[1]))
        assert denied_backup.get("error"), denied_backup
        started = self.native("backup-start", rootID=a["rootID"], generation=a["generation"], path=str(self.destination))
        assert "error" not in started, started
        status = self.wait_backup(a)
        snapshot = Path(status["lastSnapshot"])
        manifest = json.loads((snapshot / "manifest.json").read_text())
        assert manifest["logicalRootID"] == a["rootID"] and manifest["rootGeneration"] == a["generation"]
        assert manifest["sourceRootID"].startswith("fsr1:")
        restore = self.native("backup-restore", rootID=a["rootID"], generation=a["generation"], path=str(snapshot))
        assert "error" not in restore, restore
        restored = self.wait_backup(a)
        stage = Path(restored["restoredMetadata"]).name
        preview = subprocess.run([str(BUNDLE / "core/lightisle-recovery"), "--operation", "preview",
                                  "--data-dir", str(self.data), "--stage", stage,
                                  "--parent-pid", str(os.getpid())], check=True, capture_output=True, text=True)
        counts = json.loads(preview.stdout)
        assert counts["verified"] and counts["counts"]["accounts.users"]["staged"] == 3
        # The unopened compatibility root has no v2 gallery DB. The preview
        # must report an unknown aggregate rather than inventing zero rows.
        assert counts["counts"]["gallery.privateAlbums"]["staged"] is None
        assert "some_counts_unknown_for_legacy_schema" in counts["warnings"]
        staged_gallery = self.data / stage / ("gallery-root-" + a["rootID"] + ".sqlite")
        with sqlite3.connect(staged_gallery.as_uri() + "?mode=ro", uri=True) as database:
            assert database.execute("SELECT COUNT(*) FROM private_albums").fetchone()[0] == 1
        assert counts["counts"]["accounts.rootFileShares"]["current"] == 1
        assert counts["counts"]["accounts.rootFileShares"]["staged"] == 0
        old = a.copy()
        deadline = time.monotonic() + 3
        while True:
            rebound = self.native("rebind", rootID=a["rootID"], generation=a["generation"], path=str(self.paths[0]))
            if rebound.get("error") != "root_registry_busy" or time.monotonic() >= deadline:
                break
            time.sleep(0.05)
        assert "error" not in rebound, rebound
        self.roots[0] = rebound["result"]
        self.request(self.admin, self.route(old, "/files/folders"), method="POST", body={"path": "stale-write"}, root=old, expected=409)
        self.request(self.admin, self.route(old, "/public/file/" + share["token"]), expected=404, raw=True)
        for path, expected in self.originals.items():
            assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == expected
        print("PASS: bundled two-root routing, read-only ACL and SHA-256 isolation, ZIP/upload/share isolation, root-bound backup, live read-only recovery preview, stale rebind refusal, original hashes", flush=True)

    def close(self):
        if self.core is not None:
            if self.core.poll() is None:
                self.core.stdin.close()
                try:
                    self.core.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    self.core.kill()
                    self.core.wait(timeout=5)
            self.core = None
        if self.errors is not None:
            self.errors.close()
        self.temporary.cleanup()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hold-for-browser", type=Path)
    options = parser.parse_args()
    fixture = Fixture()
    try:
        fixture.exercise()
        if options.hold_for_browser:
            state = options.hold_for_browser.resolve()
            state.parent.mkdir(parents=True, exist_ok=True)
            state.write_text(json.dumps({"endpoint": fixture.endpoint, "base": str(fixture.base),
                                         "roots": fixture.roots, "pid": os.getpid(), "corePID": fixture.core.pid}))
            deadline = time.monotonic() + 900
            while time.monotonic() < deadline and not state.with_suffix(".stop").exists():
                time.sleep(0.25)
            state.unlink(missing_ok=True)
    finally:
        fixture.close()


if __name__ == "__main__":
    main()
