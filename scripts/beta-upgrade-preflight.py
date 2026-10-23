#!/usr/bin/env python3
"""LightIsle beta upgrade preflight (READ ONLY).

Usage: python3 scripts/beta-upgrade-preflight.py --data-dir PATH
This checks SQLite readability before the App starts a new DB migration.
It cannot prove that original NAS files are backed up or that an upgrade is
safe without an independent, restorable physical backup.
"""
import argparse
import json
from pathlib import Path
import sqlite3
import sys

MAX_DATABASES = 64


def inspect(data_dir: Path) -> tuple[dict, int]:
    report = {
        "data_dir": str(data_dir),
        "read_only": True,
        "status": "unknown",
        "databases": [],
        "issues": [],
        "warnings": [
            "This preflight does not create or validate an independent backup of your NAS files.",
            "Keep the old LightIsle.app and a verified metadata backup before upgrading.",
            "Stop LightIsle before upgrading; do not replace live database files manually.",
        ],
    }
    if not data_dir.exists():
        # A typo or a wrong OS user home must not pass an upgrade preflight.
        report["issues"].append("upgrade_data_directory_missing")
        report["status"] = "blocked"
        return report, 2
    if data_dir.is_symlink() or not data_dir.is_dir():
        report["issues"].append("data_directory_not_a_regular_directory")
        report["status"] = "blocked"
        return report, 2
    try:
        files = sorted(p for p in data_dir.iterdir() if p.name.endswith(".sqlite"))
    except OSError:
        report["issues"].append("data_directory_unreadable")
        report["status"] = "blocked"
        return report, 2
    if len(files) > MAX_DATABASES:
        report["issues"].append("too_many_sqlite_databases")
        report["status"] = "blocked"
        return report, 2
    if not files:
        report["issues"].append("no_existing_sqlite_metadata")
        report["status"] = "blocked"
        return report, 2
    for path in files:
        entry = {"name": path.name, "status": "unknown"}
        report["databases"].append(entry)
        if path.is_symlink() or not path.is_file():
            entry["status"] = "unsafe_path"
            report["issues"].append("unsafe_database_path:" + path.name)
            continue
        try:
            # URI mode=ro avoids any schema migration, repair or WAL writes.
            # '?' and '#' in filenames are escaped by Path.as_uri().
            uri = path.resolve(strict=True).as_uri() + "?mode=ro"
            db = sqlite3.connect(uri, uri=True, timeout=3)
            try:
                db.execute("PRAGMA query_only=ON")
                check = db.execute("PRAGMA quick_check(1)").fetchone()
                entry["status"] = "ok" if check and check[0] == "ok" else "invalid"
                entry["tables"] = len(db.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'").fetchall())
                if entry["status"] != "ok":
                    report["issues"].append("sqlite_integrity_failed:" + path.name)
            finally:
                db.close()
        except (OSError, sqlite3.Error):
            entry["status"] = "unreadable"
            report["issues"].append("sqlite_unreadable:" + path.name)
    if files and not (data_dir / "accounts.sqlite").exists():
        report["issues"].append("missing_accounts_database")
    if report["issues"]:
        report["status"] = "blocked"
        return report, 2
    report["status"] = "checks_passed_not_backup_verified"
    return report, 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, required=True,
                        help="The existing LightIsle private Application Support directory")
    args = parser.parse_args()
    result, exit_code = inspect(args.data_dir)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
