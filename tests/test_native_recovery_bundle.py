#!/usr/bin/env python3
"""Smoke-test bundled offline recovery on disposable SQLite-only fixtures."""
import hashlib
import fcntl
import json
import os
import pathlib
import sqlite3
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = pathlib.Path(os.environ.get("LIGHTISLE_APP_BUNDLE", str(ROOT / "dist" / "LightIsle.app")))
HELPER = APP / "Contents" / "Resources" / "core" / "lightisle-recovery"
CORE = APP / "Contents" / "Resources" / "core" / "lightisled"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(HELPER), *args, "--parent-pid", str(os.getpid())], text=True, capture_output=True,
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
        preview_result = run(*base, "--operation", "preview")
        assert preview_result.returncode == 0, preview_result.stderr + preview_result.stdout
        preview = json.loads(preview_result.stdout)
        assert preview["schemaVersion"] == 1 and preview["operation"] == "preview"
        assert preview["status"] == "ready" and preview["verified"]
        assert preview["counts"]["accounts.users"] == {"current": 1, "staged": 1, "delta": 0}
        assert len(preview["manifestSHA256"]) == 64
        assert '"previous"' not in preview_result.stdout and '"replacement"' not in preview_result.stdout
        assert str(data) not in preview_result.stdout and stage_name not in preview_result.stdout
        changed = run(
            *base, "--operation", "activate",
            "--confirm", "I_UNDERSTAND_OFFLINE_METADATA_REPLACEMENT",
            "--expected-manifest-sha256", "0" * 64,
        )
        assert changed.returncode != 0 and "staged_metadata_changed_since_preview" in changed.stderr, changed.stderr
        with sqlite3.connect(data / "accounts.sqlite") as db:
            assert db.execute("SELECT username FROM users").fetchone()[0] == "previous"
        applied = run(
            *base, "--operation", "activate",
            "--confirm", "I_UNDERSTAND_OFFLINE_METADATA_REPLACEMENT",
            "--expected-manifest-sha256", preview["manifestSHA256"],
        )
        assert applied.returncode == 0, applied.stderr
        with sqlite3.connect(data / "accounts.sqlite") as db:
            assert db.execute("SELECT username FROM users").fetchone()[0] == "replacement"
        rollback_dirs = list(data.glob("LightIsle-MetadataRollback-*"))
        assert len(rollback_dirs) == 1
        with sqlite3.connect(rollback_dirs[0] / "accounts.sqlite") as db:
            assert db.execute("SELECT username FROM users").fetchone()[0] == "previous"
        assert not (data / ".lightisle-offline-restore.json").exists()

        # A session-cleanup marker is distinct from a mixed-generation
        # metadata journal. Inspection reports it, while a verified previous
        # database remains an available rescue path if the current DB is bad.
        transaction_id = rollback_dirs[0].name.removeprefix("LightIsle-MetadataRollback-")
        marker = data / ".lightisle-revoke-recovery-sessions.json"
        marker.write_text('{"version":1}', encoding="utf-8")
        marker.chmod(0o600)
        (data / "accounts.sqlite").write_bytes(b"corrupt active account database")
        listed = run(*base, "--operation", "list")
        assert listed.returncode == 0, listed.stderr + listed.stdout
        inventory = json.loads(listed.stdout)
        assert inventory["recoveryPending"] is True
        assert inventory["metadataRecoveryPending"] is False
        assert inventory["sessionCleanupPending"] is True
        assert len(inventory["transactions"]) == 1
        assert inventory["transactions"][0]["id"] == transaction_id
        assert inventory["transactions"][0]["canRollback"] is True

        inspected = run(*base, "--operation", "inspect")
        assert inspected.returncode == 0, inspected.stderr + inspected.stdout
        inspection = json.loads(inspected.stdout)
        assert inspection["recoveryPending"] is True
        assert inspection["metadataRecoveryPending"] is False
        assert inspection["sessionCleanupPending"] is True
        assert inspection["pendingOperation"] == "session_cleanup"

        rollback_args = (*base, "--operation", "rollback", "--transaction-id", transaction_id)
        assert run(*rollback_args).returncode != 0, "rollback accepted without native confirmation"
        with (data / ".lightisle-process.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            blocked = run(*rollback_args, "--confirm", "ROLLBACK_OFFLINE_METADATA")
            assert blocked.returncode != 0 and json.loads(blocked.stdout)["error"]["code"]=="core_running", blocked.stdout
        assert (data / "accounts.sqlite").read_bytes()==b"corrupt active account database"

        rolled_back = run(
            *base, "--operation", "rollback", "--transaction-id", transaction_id,
            "--confirm", "ROLLBACK_OFFLINE_METADATA",
        )
        assert rolled_back.returncode == 0, rolled_back.stderr + rolled_back.stdout
        result = json.loads(rolled_back.stdout)
        assert result["status"] == "rolled_back"
        assert result["recoveryPending"] is False
        assert not marker.exists()
        with sqlite3.connect(data / "accounts.sqlite") as db:
            assert db.execute("SELECT username FROM users").fetchone()[0] == "previous"
        preserved = pathlib.Path(result["preservedCurrent"])
        assert (preserved / "accounts.sqlite").read_bytes() == b"corrupt active account database"
        stale=run(*rollback_args,"--confirm","ROLLBACK_OFFLINE_METADATA")
        assert stale.returncode!=0, "already-rolled-back version accepted again"
        with sqlite3.connect(data / "accounts.sqlite") as db:
            assert db.execute("SELECT username FROM users").fetchone()[0] == "previous"
    print("PASS: bundled count-only recovery preview, preview-bound activation and original-db rollback preservation")


if __name__ == "__main__":
    main()
