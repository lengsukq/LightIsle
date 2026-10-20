"""Deterministic tests for the manual release QA report gate.

The verifier must reject an incomplete, stale or malformed evidence manifest
before any signing/notarization step. These tests never require real hardware;
the report date is always pinned explicitly.
"""
from __future__ import annotations

import copy
import datetime as dt
import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts" / "verify-release-qa.py"

spec = importlib.util.spec_from_file_location("verify_release_qa", VERIFIER)
assert spec is not None and spec.loader is not None
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)

TODAY = dt.date(2026, 10, 20)


def valid_report(evidence_root: pathlib.Path | None = None) -> dict:
    if evidence_root is not None:
        evidence_root.mkdir(parents=True, exist_ok=True)
        for name in qa.REQUIRED_CHECKS:
            (evidence_root / f"{name}.mov").write_bytes(b"evidence")
    evidence = (
        lambda name: str(evidence_root / f"{name}.mov")
        if evidence_root is not None
        else f"evidence/{name}.mov"
    )
    return {
        "reviewer": "Independent QA reviewer",
        "hardware": "MacBook Pro 14-inch, M3 Max, macOS 14.7.1",
        "signedOff": True,
        "date": TODAY.isoformat(),
        "checks": {
            name: {"pass": True, "evidence": evidence(name)}
            for name in qa.REQUIRED_CHECKS
        },
    }


class VerifyReportTests(unittest.TestCase):
    def assert_rejected(self, report: object, fragment: str) -> None:
        with self.assertRaises(qa.QAReportError) as raised:
            qa.verify_report(report, today=TODAY)
        self.assertIn(fragment, str(raised.exception))

    def test_valid_report_is_accepted(self) -> None:
        qa.verify_report(valid_report(), today=TODAY)

    def test_report_older_than_thirty_days_is_rejected(self) -> None:
        report = valid_report()
        report["date"] = (TODAY - dt.timedelta(days=31)).isoformat()
        self.assert_rejected(report, "older than 30 days")

    def test_report_dated_today_or_exactly_thirty_days_old_is_accepted(self) -> None:
        for age in (0, qa.QA_VALID_DAYS):
            report = valid_report()
            report["date"] = (TODAY - dt.timedelta(days=age)).isoformat()
            qa.verify_report(report, today=TODAY)

    def test_future_dated_report_is_rejected(self) -> None:
        report = valid_report()
        report["date"] = (TODAY + dt.timedelta(days=1)).isoformat()
        self.assert_rejected(report, "in the future")

    def test_missing_reviewer_is_rejected(self) -> None:
        report = valid_report()
        del report["reviewer"]
        self.assert_rejected(report, "missing required fields: reviewer")

    def test_blank_reviewer_is_rejected(self) -> None:
        report = valid_report()
        report["reviewer"] = "   "
        self.assert_rejected(report, "reviewer must name")

    def test_placeholder_reviewer_is_rejected(self) -> None:
        for value in ("TBD", "unknown", "n/a", "x"):
            report = valid_report()
            report["reviewer"] = value
            self.assert_rejected(report, "reviewer must name")

    def test_non_string_reviewer_is_rejected(self) -> None:
        report = valid_report()
        report["reviewer"] = ["QA reviewer"]
        self.assert_rejected(report, "reviewer must name")

    def test_missing_hardware_is_rejected(self) -> None:
        report = valid_report()
        del report["hardware"]
        self.assert_rejected(report, "missing required fields: hardware")

    def test_empty_hardware_object_is_rejected(self) -> None:
        report = valid_report()
        report["hardware"] = {"model": "", "os": "   "}
        self.assert_rejected(report, "hardware must name the tested Mac model")

    def test_placeholder_hardware_is_rejected(self) -> None:
        for value in ("TBD", "unknown", {"model": "n/a"}, {}, ["Mac mini"]):
            report = valid_report()
            report["hardware"] = value
            self.assert_rejected(report, "hardware must name the tested Mac model")

    def test_hardware_object_with_details_is_accepted(self) -> None:
        for hardware in (
            {"model": "Mac mini M2", "os": "macOS 14.7"},
            {"model": "iMac 24-inch M3", "os": "macOS 14.7.1"},
            {"model": "iMac 24-inch M3", "os": "14.7.1"},
            {"model": "Mac mini M2", "os": "Mac OS 14.7"},
        ):
            report = valid_report()
            report["hardware"] = hardware
            qa.verify_report(report, today=TODAY)

    def test_hardware_object_requires_model_and_os(self) -> None:
        for hardware in (
            {"model": "Mac mini M2", "os": ""},
            {"model": "", "os": "macOS 14.7"},
            {"model": "Mac mini M2"},
            {"model": "Mac mini M2", "os": "unknown"},
            "x",
            "TBDx",
        ):
            report = valid_report()
            report["hardware"] = hardware
            self.assert_rejected(report, "hardware must name the tested Mac model and macOS version")

    def test_missing_signoff_is_rejected(self) -> None:
        report = valid_report()
        del report["signedOff"]
        self.assert_rejected(report, "missing required fields: signedOff")

    def test_truthy_non_boolean_signoff_is_rejected(self) -> None:
        for value in (1, "true", "yes"):
            report = valid_report()
            report["signedOff"] = value
            self.assert_rejected(report, "signedOff must be the boolean true")

    def test_missing_date_is_rejected(self) -> None:
        report = valid_report()
        del report["date"]
        self.assert_rejected(report, "missing required fields: date")

    def test_malformed_date_is_rejected(self) -> None:
        for value in ("20/10/2026", "2026-13-01", "20261020", "2026-10-20T00:00:00"):
            report = valid_report()
            report["date"] = value
            self.assert_rejected(report, "date must be an ISO calendar date")

    def test_non_string_date_is_rejected(self) -> None:
        report = valid_report()
        report["date"] = 20261020
        self.assert_rejected(report, "date must be an ISO calendar date")

    def test_missing_checks_object_is_rejected(self) -> None:
        report = valid_report()
        del report["checks"]
        self.assert_rejected(report, "missing required fields: checks")

    def test_checks_list_is_rejected(self) -> None:
        report = valid_report()
        report["checks"] = []
        self.assert_rejected(report, "checks must be a JSON object")

    def test_required_check_set_is_pinned(self) -> None:
        self.assertEqual(
            qa.REQUIRED_CHECKS,
            (
                "macos14_launch_close", "macos_current_launch_close",
                "apple_silicon_hardware", "touchid_and_password_recovery",
                "different_user_acl_http", "symlink_and_path_escape",
                "mount_unplug_reinsert", "copy_disk_full_and_rollback",
                "database_recovery_and_rollback", "backup_restore_10gib",
                "resumable_upload_5gib", "scan_10000_files",
                "android_lan_https", "sleep_wake_and_force_quit",
                "soak_72_hours", "smart_and_volume_health",
            ),
        )

    def test_every_required_check_is_enforced(self) -> None:
        for name in qa.REQUIRED_CHECKS:
            report = valid_report()
            del report["checks"][name]
            self.assert_rejected(report, f"{name}: missing or not an object")

    def test_non_object_check_is_rejected(self) -> None:
        report = valid_report()
        report["checks"]["soak_72_hours"] = "passed"
        self.assert_rejected(report, "soak_72_hours: missing or not an object")

    def test_failed_check_is_rejected(self) -> None:
        report = valid_report()
        report["checks"]["backup_restore_10gib"]["pass"] = False
        self.assert_rejected(report, "backup_restore_10gib: pass must be the boolean true")

    def test_truthy_non_boolean_pass_is_rejected(self) -> None:
        for value in (1, "true", "passed"):
            report = valid_report()
            report["checks"]["android_lan_https"]["pass"] = value
            self.assert_rejected(report, "android_lan_https: pass must be the boolean true")

    def test_missing_evidence_is_rejected(self) -> None:
        report = valid_report()
        del report["checks"]["scan_10000_files"]["evidence"]
        self.assert_rejected(report, "scan_10000_files: evidence must be a non-empty path")

    def test_blank_or_placeholder_evidence_is_rejected(self) -> None:
        for value in ("", "   ", "n/a", "TBD", "无", ["evidence/a.mov", " "], ["-"]):
            report = valid_report()
            report["checks"]["smart_and_volume_health"]["evidence"] = value
            self.assert_rejected(report, "smart_and_volume_health: evidence must")

    def test_evidence_must_be_strings(self) -> None:
        for value in (42, ["evidence/a.mov", 7], {"file": "a.mov"}, []):
            report = valid_report()
            report["checks"]["mount_unplug_reinsert"]["evidence"] = value
            self.assert_rejected(report, "mount_unplug_reinsert: evidence must")

    def test_multiple_evidence_items_are_accepted(self) -> None:
        report = valid_report()
        report["checks"]["database_recovery_and_rollback"]["evidence"] = [
            "evidence/recovery.mov",
            "evidence/recovery.log",
        ]
        qa.verify_report(report, today=TODAY)

    def test_multiple_problems_are_all_reported(self) -> None:
        report = copy.deepcopy(valid_report())
        report["reviewer"] = ""
        report["signedOff"] = False
        report["checks"]["resumable_upload_5gib"]["evidence"] = ""
        with self.assertRaises(qa.QAReportError) as raised:
            qa.verify_report(report, today=TODAY)
        message = str(raised.exception)
        for fragment in ("reviewer", "signedOff", "resumable_upload_5gib"):
            self.assertIn(fragment, message)

    def test_non_object_report_is_rejected(self) -> None:
        for value in ([], None, "report", 7):
            with self.assertRaises(qa.QAReportError):
                qa.verify_report(value, today=TODAY)


class CommandTests(unittest.TestCase):
    def write(self, directory: str, value: str) -> pathlib.Path:
        path = pathlib.Path(directory) / "qa.json"
        path.write_text(value, encoding="utf-8")
        return path

    def test_verify_file_accepts_valid_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = self.write(directory, json.dumps(valid_report(root / "evidence")))
            qa.verify(path, today=TODAY)
            self.assertEqual(qa.main([str(path)], today=TODAY), 0)

    def test_verify_file_rejects_missing_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(directory, json.dumps(valid_report()))
            with self.assertRaises(qa.QAReportError) as raised:
                qa.verify(path, today=TODAY)
            self.assertIn("evidence file is not readable", str(raised.exception))

    def test_relative_evidence_cannot_escape_report_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            outside = root.parent / f"{root.name}-outside.mov"
            outside.write_bytes(b"evidence")
            self.addCleanup(outside.unlink, missing_ok=True)
            report = valid_report(root / "evidence")
            report["checks"]["soak_72_hours"]["evidence"] = f"../{outside.name}"
            path = self.write(directory, json.dumps(report))
            with self.assertRaises(qa.QAReportError) as raised:
                qa.verify(path, today=TODAY)
            self.assertIn("must stay within the QA report directory", str(raised.exception))

    def test_absolute_evidence_outside_report_directory_is_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            outside = root.parent / f"{root.name}-absolute.mov"
            outside.write_bytes(b"evidence")
            self.addCleanup(outside.unlink, missing_ok=True)
            report = valid_report(root / "evidence")
            report["checks"]["soak_72_hours"]["evidence"] = str(outside)
            path = self.write(directory, json.dumps(report))
            qa.verify(path, today=TODAY)

    def test_relative_evidence_symlink_inside_report_directory_is_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            evidence = root / "evidence"
            evidence.mkdir()
            target = evidence / "real.mov"
            target.write_bytes(b"evidence")
            (evidence / "alias.mov").symlink_to(target)
            report = valid_report(evidence)
            report["checks"]["soak_72_hours"]["evidence"] = "evidence/alias.mov"
            path = self.write(directory, json.dumps(report))
            qa.verify(path, today=TODAY)

    def test_relative_evidence_symlink_cannot_escape_report_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            outside = root.parent / f"{root.name}-outside.mov"
            outside.write_bytes(b"evidence")
            self.addCleanup(outside.unlink, missing_ok=True)
            link = root / "escape.mov"
            link.symlink_to(outside)
            report = valid_report(root / "evidence")
            report["checks"]["soak_72_hours"]["evidence"] = "escape.mov"
            path = self.write(directory, json.dumps(report))
            with self.assertRaises(qa.QAReportError) as raised:
                qa.verify(path, today=TODAY)
            self.assertIn("must stay within the QA report directory", str(raised.exception))

    def test_nul_in_report_path_is_structured_rejection(self) -> None:
        self.assertEqual(qa.main(["bad\x00.json"], today=TODAY), 2)

    def test_nul_in_evidence_path_is_structured_rejection(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            report = valid_report()
            report["checks"]["soak_72_hours"]["evidence"] = "bad\x00.mov"
            path = self.write(directory, json.dumps(report))
            with self.assertRaises(qa.QAReportError) as raised:
                qa.verify(path, today=TODAY)
            self.assertIn("evidence file is not readable", str(raised.exception))

    def test_malformed_json_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(directory, '{"reviewer": "QA",')
            with self.assertRaises(qa.QAReportError) as raised:
                qa.verify(path, today=TODAY)
            self.assertIn("not valid JSON", str(raised.exception))

    def test_missing_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "absent.json"
            with self.assertRaises(qa.QAReportError) as raised:
                qa.verify(path, today=TODAY)
            self.assertIn("cannot read QA report", str(raised.exception))
            self.assertEqual(qa.main([str(path)], today=TODAY), 2)

    def test_usage_error_returns_two(self) -> None:
        self.assertEqual(qa.main([], today=TODAY), 2)


if __name__ == "__main__":
    unittest.main()
