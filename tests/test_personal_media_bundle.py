"""Real bundled Core -> fd media worker -> authorized API -> album lifecycle.

Inputs are synthesized with installed macOS frameworks in an isolated data
directory. This test never uses the owner's NAS database or downloads media.
"""
from __future__ import annotations

import base64
import hashlib
import http.cookiejar
import json
import pathlib
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

from test_media_worker import FIXTURE_MAKER, run_fixture_maker


ROOT = pathlib.Path(__file__).resolve().parents[1]
BUNDLE = ROOT / "dist/LightIsle.app"
CORE = BUNDLE / "Contents/Resources/core/lightisled"
WEB = BUNDLE / "Contents/Resources/web"


def jpeg_dimensions(data: bytes) -> tuple[int, int]:
    """Read SOF dimensions without depending on an external image package."""
    assert data.startswith(b"\xff\xd8")
    offset = 2
    while offset < len(data):
        assert data[offset] == 0xFF, "invalid JPEG marker"
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        marker = data[offset]
        offset += 1
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            continue
        assert marker not in (0xD9, 0xDA), "JPEG has no frame dimensions"
        length = int.from_bytes(data[offset:offset + 2], "big")
        assert length >= 2 and offset + length <= len(data)
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            assert length >= 8
            return (int.from_bytes(data[offset + 5:offset + 7], "big"),
                    int.from_bytes(data[offset + 3:offset + 5], "big"))
        offset += length
    raise AssertionError("JPEG has no frame dimensions")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="lightisle-personal-media-") as temporary:
        base = pathlib.Path(temporary)
        data = base / "data"
        shared = data / "SharedFiles"
        shared.mkdir(parents=True)
        maker = base / "fixture-maker"
        subprocess.run(
            ["swiftc", "-swift-version", "5", "-parse-as-library", "-suppress-warnings", str(FIXTURE_MAKER), "-o", str(maker)],
            check=True, timeout=60,
        )
        photo = shared / "photo.heic"
        movie = shared / "Personal.2024.mp4"
        renamed_movie = shared / "Renamed.2024.mov"
        run_fixture_maker(maker, "heic", photo)
        run_fixture_maker(maker, "mp4", movie)
        shutil.copyfile(movie, renamed_movie)
        (shared / "corrupt.mp4").write_bytes(b"corrupt fixture, not an MP4")
        original_hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in shared.iterdir()}
        process = subprocess.Popen(
            [str(CORE), "-port", "0", "-data-dir", str(data), "-web-root", str(WEB)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )
        try:
            ready = process.stdout.readline().strip()
            assert ready.startswith("LIGHTISLE_READY http://127.0.0.1:"), ready
            url = ready.split(" ", 1)[1]
            assert process.stdout.readline().strip() == "LIGHTISLE_CONFIGURED 0"
            assert process.stdout.readline().startswith("LIGHTISLE_SHARE_ON ")
            assert process.stdout.readline().startswith("LIGHTISLE_SHARE_PATH ")
            credentials = {"username": "media_owner", "password": "personal-media-test-password"}
            encoded = base64.urlsafe_b64encode(json.dumps(credentials).encode()).rstrip(b"=").decode()
            process.stdin.write("admin init " + encoded + "\n")
            process.stdin.flush()
            assert process.stdout.readline().strip() == "LIGHTISLE_INITIALIZED"
            assert process.stdout.readline().startswith("LIGHTISLE_ADMIN_ACCOUNT ")

            def client():
                return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

            owner = client()
            viewer = client()

            def request(path, method="GET", payload=None, opener=owner):
                headers = {"X-LightIsle-Request": "1"} if method not in ("GET", "HEAD") else {}
                body = None
                if payload is not None:
                    headers["Content-Type"] = "application/json"
                    body = json.dumps(payload).encode()
                return opener.open(urllib.request.Request(url + path, data=body, headers=headers, method=method), timeout=30)

            def api(path, method="GET", payload=None, opener=owner):
                with request(path, method, payload, opener) as response:
                    return json.load(response)

            def denied(path, method="GET", payload=None):
                try:
                    with request(path, method, payload, viewer):
                        raise AssertionError("read-only viewer unexpectedly allowed: " + path)
                except urllib.error.HTTPError as error:
                    assert error.code == 403, (path, error.code, error.read())

            assert api("/api/v2/auth/login", "POST", credentials)["role"] == "admin"
            for path in ("/api/v2/photos/scan", "/api/v2/cinema/scan"):
                assert api(path, "POST")["started"]
            for path in ("/api/v2/photos/status", "/api/v2/cinema/status"):
                deadline = time.monotonic() + 30
                while True:
                    status = api(path)["status"]
                    if not status["running"]:
                        break
                    assert time.monotonic() < deadline, (path, status)
                    time.sleep(0.05)
                assert not status.get("lastError"), (path, status)

            assets = api("/api/v2/photos")["assets"]
            photo_asset = next(asset for asset in assets if asset["path"] == photo.name)
            video_asset = next(asset for asset in assets if asset["path"] == movie.name)
            assert photo_asset["probeStatus"] == "ready", photo_asset
            assert photo_asset["orientation"] == 6 and (photo_asset["width"], photo_asset["height"]) == (80, 48)
            assert photo_asset["capturedAt"] == "2020-01-01T19:04:05Z", photo_asset
            assert photo_asset["takenAt"] == 1577905445, photo_asset
            films = api("/api/v2/cinema")["films"]
            film = next(item for item in films if item["path"] == movie.name)
            renamed = next(item for item in films if item["path"] == renamed_movie.name)
            corrupt = next(item for item in films if item["path"] == "corrupt.mp4")
            for item in (film, renamed):
                assert item["probeStatus"] == "ready" and item["browserPlayback"] == "verified-direct", item
                assert item["mime"] == "video/mp4", item
                assert (item["width"], item["height"]) == (96, 64), item
                assert 1.8 <= item["durationSeconds"] <= 2.2, item
            assert corrupt["probeStatus"] == "failed" and corrupt["browserPlayback"] == "download-only", corrupt
            film_base = f"/api/v2/cinema/{film['id']}"
            with request(film_base + "/poster", "HEAD") as response:
                assert response.headers["Content-Type"] == "image/jpeg"
                assert int(response.headers["Content-Length"]) > 0
            for endpoint in (film_base + "/poster", f"/api/v2/photos/{video_asset['id']}/thumbnail", f"/api/v2/photos/{photo_asset['id']}/thumbnail"):
                with request(endpoint) as response:
                    jpeg = response.read()
                    assert response.headers["Content-Type"] == "image/jpeg" and jpeg.startswith(b"\xff\xd8") and jpeg.endswith(b"\xff\xd9"), endpoint
                    if endpoint == f"/api/v2/photos/{photo_asset['id']}/thumbnail":
                        width, height = jpeg_dimensions(jpeg)
                        assert width < height and max(width, height) <= 512, (endpoint, width, height)
                        assert abs(width / height - 48 / 80) < 0.025, (width, height)
            with request(f"/api/v2/cinema/{renamed['id']}/stream") as response:
                assert response.headers["Content-Type"] == "video/mp4"
                assert response.read() == movie.read_bytes()

            member = api("/api/v2/users", "POST", {"username": "media_viewer", "password": "personal-viewer-password", "role": "member"})
            member_id = member["id"]
            api("/api/v2/auth/login", "POST", {"username": "media_viewer", "password": "personal-viewer-password"}, viewer)
            denied(film_base + "/poster")
            api(f"/api/v2/users/{member_id}/file-grants", "PUT", {"path": ".", "canWrite": False})
            with request(film_base + "/poster", opener=viewer) as response:
                assert response.headers["Content-Type"] == "image/jpeg"
            page = api("/api/v2/files?path=.", opener=viewer)
            assert not page["canWrite"] and all(not entry["canWrite"] for entry in page["entries"])
            assert all(not asset["canWrite"] for asset in api("/api/v2/photos", opener=viewer)["assets"])
            denied(f"/api/v2/photos/{photo_asset['id']}/favorite", "POST", {"favorite": True})
            denied("/api/v2/photos/albums", "POST", {"name": "cannot create"})

            # Ownership and current directory grants remain separate: a revoked
            # uploader may discard their own temporary bytes, never publish them.
            api(f"/api/v2/users/{member_id}/file-grants", "PUT", {"path": ".", "canWrite": True})
            pending=api("/api/v2/uploads", "POST", {"path":"unfinished.txt","size":3}, viewer)
            another=api("/api/v2/uploads", "POST", {"path":"cancel-by-owner.txt","size":3}, viewer)
            api(f"/api/v2/users/{member_id}/file-grants", "PUT", {"path": ".", "canWrite": False})
            listing=api("/api/v2/admin/uploads?limit=20")
            record=next(item for item in listing["uploads"] if item["id"]==pending["id"])
            assert record["ownerID"]==member_id and not record["ownerCanWrite"],record
            denied("/api/v2/admin/uploads")
            denied(f"/api/v2/uploads/{pending['id']}/complete", "POST")
            api(f"/api/v2/uploads/{another['id']}", "DELETE", opener=viewer)
            api(f"/api/v2/admin/uploads/{pending['id']}", "DELETE")
            assert not api("/api/v2/admin/uploads")["uploads"]
            assert not (shared/"unfinished.txt").exists() and not (shared/"cancel-by-owner.txt").exists()

            api(f"/api/v2/photos/{photo_asset['id']}/favorite", "POST", {"favorite": True})
            album = api("/api/v2/photos/albums", "POST", {"name": "旅行"})
            album_base = f"/api/v2/photos/albums/{album['id']}"
            api(album_base + "/items", "POST", {"assetId": photo_asset["id"]})
            renamed_album = api(album_base, "PATCH", {"name": "旅行 🌊"})
            assert renamed_album["name"] == "旅行 🌊" and renamed_album["count"] == 1
            api(album_base + f"/items/{photo_asset['id']}", "DELETE")
            assert api(f"/api/v2/photos?album={album['id']}")["assets"] == []
            api(album_base, "DELETE")
            assert next(asset for asset in api("/api/v2/photos")["assets"] if asset["id"] == photo_asset["id"])["favorite"]
            for name, expected_hash in original_hashes.items():
                assert hashlib.sha256((shared / name).read_bytes()).hexdigest() == expected_hash, name
            process.stdin.close()
            assert process.wait(timeout=15) == 0, "Core failed to stop after owner EOF"
            print("PASS: bundled HEIC metadata, real video posters/probe, renamed MIME, scoped read-only access, album lifecycle, original preservation, EOF shutdown")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
