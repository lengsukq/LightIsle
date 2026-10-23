import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "beta-upgrade-preflight.py"
SPEC = importlib.util.spec_from_file_location("lightisle_preflight", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BetaUpgradePreflightTests(unittest.TestCase):
    def test_wrong_upgrade_directory_fails_closed_without_creating_it(self):
        with tempfile.TemporaryDirectory() as root:
            future = Path(root) / "missing"
            result, code = MODULE.inspect(future)
            self.assertEqual((code, result["status"]), (2, "blocked"))
            self.assertFalse(future.exists())

    def test_valid_existing_database_is_inspected_without_mutation(self):
        with tempfile.TemporaryDirectory() as root:
            data = Path(root)
            db_path = data / "accounts.sqlite"
            with sqlite3.connect(db_path) as conn:
                conn.execute("CREATE TABLE users(id INTEGER PRIMARY KEY)")
                conn.execute("INSERT INTO users VALUES(1)")
            before = db_path.read_bytes()
            report, code = MODULE.inspect(data)
            self.assertEqual(code, 0, report)
            self.assertEqual(report["status"], "checks_passed_not_backup_verified")
            self.assertEqual(report["databases"][0]["status"], "ok")
            self.assertEqual(before, db_path.read_bytes())
            self.assertEqual(list(data.glob("*")), [db_path])

    def test_bad_database_is_blocked_and_not_repaired(self):
        with tempfile.TemporaryDirectory() as root:
            p = Path(root) / "accounts.sqlite"
            p.write_bytes(b"corrupted-not-a-sqlite-file")
            before = p.read_bytes()
            report, code = MODULE.inspect(Path(root))
            self.assertEqual(code, 2)
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(before, p.read_bytes())

    def test_symlink_is_blocked(self):
        with tempfile.TemporaryDirectory() as root:
            data = Path(root)
            other = data / "outside.txt"
            other.write_text("secret")
            (data / "accounts.sqlite").symlink_to(other)
            report, code = MODULE.inspect(data)
            self.assertEqual(code, 2)
            self.assertIn("unsafe_database_path:accounts.sqlite", report["issues"])


if __name__ == "__main__":
    unittest.main()
