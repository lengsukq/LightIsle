#!/usr/bin/env python3
"""Smoke-test bundled offline recovery on disposable SQLite-only fixtures."""
import hashlib
import json
import pathlib
import sqlite3
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "dist" / "LightIsle.app"
HELPER = APP / "Contents" / "Resources" / "core" / "lightisle-recovery"
CORE = APP / "Contents" / "Resources" / "core" / "lightisled"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(HELPER), *args], text=True, capture_output=True,
        check=False, timeout=20,
    )


def make_db(filename: pathlib.Path, username: str) -> bytes:
    with sqlite3.connect(filename) as db:
        db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL)")
        db.execute("INSERT INTO users(id,username) VALUES(1,?)", (username,))
    return filename.read_bytes()


def main() -> None:
    assert HELPER.is_file() and CORE.is_file(), "bundled backend/recovery helper missing"
    with tempfile.TemporaryDirectory(prefix="lightisle-recovery-smoke-") as temp:
        data = pathlib.Path(temp)
        make_db(data / "accounts.sqlite", "previous")
        stage_name = "LightIsle-RestoredMetadata-smoketest"
        stage = data / stage_name
        stage.mkdir(mode=0o700)
        snapshot = make_db(stage / "accounts.sqlite", "replacement")
        (stage / "metadata-manifest.json").write_text(
            json.dumps([{
                "path": "accounts.sqlite",
                "size": len(snapshot),
                "sha256": hashlib.sha256(snapshot).hexdigest(),
            }]),
            encoding="utf-8",
        )
        base = ("--data-dir", str(data), "--stage", stage_name)
        assert run(*base, "--operation", "verify").returncode == 0
        assert run(*base, "--operation", "activate").returncode != 0
        with sqlite3.connect(data / "accounts.sqlite") as db:
            assert db.execute("SELECT username FROM users").fetchone()[0] == "previous"
        applied = run(
            *base, "--operation", "activate",
            "--confirm", "I_UNDERSTAND_OFFLINE_METADATA_REPLACEMENT",
        )
        assert applied.returncode == 0, applied.stderr
        with sqlite3.connect(data / "accounts.sqlite") as db:
            assert db.execute("SELECT username FROM users").fetchone()[0] == "replacement"
        rollback_dirs = list(data.glob("LightIsle-MetadataRollback-*"))
        assert len(rollback_dirs) == 1
        with sqlite3.connect(rollback_dirs[0] / "accounts.sqlite") as db:
            assert db.execute("SELECT username FROM users").fetchone()[0] == "previous"
        assert not (data / ".lightisle-offline-restore.json").exists()
    print("PASS: bundled owner-only offline recovery verify/activate and original-db rollback preservation")


if __name__ == "__main__":
    main()
