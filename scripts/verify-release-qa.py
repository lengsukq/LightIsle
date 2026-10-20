"""Validate the structure and recency of a manual macOS release QA report.

This gate only checks that an evidence manifest is complete, well-typed and
recent. A passing report is not proof that the hardware tests ran: a human
reviewer must still inspect every referenced recording, log or report before
any build is labeled a production release.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import re
import stat
import sys
from typing import Any

QA_VALID_DAYS = 30

REQUIRED_CHECKS = (
    "macos14_launch_close", "macos_current_launch_close",
    "apple_silicon_hardware", "touchid_and_password_recovery",
    "different_user_acl_http", "symlink_and_path_escape",
    "mount_unplug_reinsert", "copy_disk_full_and_rollback",
    "database_recovery_and_rollback", "backup_restore_10gib",
    "resumable_upload_5gib", "scan_10000_files",
    "android_lan_https", "sleep_wake_and_force_quit",
    "soak_72_hours", "smart_and_volume_health",
)

_ISO_DATE_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}\Z")

# Values that look like a filled field but carry no auditable evidence.
_PLACEHOLDER_VALUES = frozenset({
    "-", "n/a", "na", "none", "null", "tbd", "todo", "pending", "unknown",
    "pass", "passed", "ok", "done", "yes", "true", "test",
    "待补", "待定", "无", "通过",
})


class QAReportError(ValueError):
    """The supplied QA report cannot be accepted as release evidence."""


def _is_placeholder(value: str) -> bool:
    return not value.strip() or value.strip().casefold() in _PLACEHOLDER_VALUES


def _validate_hardware(value: Any) -> None:
    if isinstance(value, str):
        model = value
        os_version = value
    elif isinstance(value, dict):
        model = value.get("model")
        os_version = value.get("os")
    else:
        model = os_version = None
    if (
        isinstance(model, str)
        and isinstance(os_version, str)
        and not _is_placeholder(model)
        and not _is_placeholder(os_version)
        and len(model.strip()) >= 3
        and re.search(r"\b(?:i?mac(?:book)?|mac\s+(?:mini|studio|pro))\b", model, re.IGNORECASE)
        and re.search(r"\bmac\s*os\s*\d+(?:\.\d+)*\b|\b\d+\.\d+(?:\.\d+)*\b", os_version, re.IGNORECASE)
    ):
        return
    raise QAReportError(
        "hardware must name the tested Mac model and macOS version, either in "
        "a descriptive string or as non-empty model and os fields"
    )


def _validate_signed_off(value: Any) -> None:
    # ``1`` and ``"true"`` are common truthy mistakes; acceptance is explicit.
    if value is not True:
        raise QAReportError("signedOff must be the boolean true")


def _validate_date(value: Any, today: dt.date) -> None:
    if not isinstance(value, str) or not _ISO_DATE_PATTERN.fullmatch(value.strip()):
        raise QAReportError("date must be an ISO calendar date (YYYY-MM-DD)")
    try:
        date = dt.date.fromisoformat(value.strip())
    except ValueError as error:
        raise QAReportError(
            f"date must be an ISO calendar date (YYYY-MM-DD): {error}"
        ) from error
    if date > today:
        raise QAReportError(f"date {date.isoformat()} is in the future")
    if (today - date).days > QA_VALID_DAYS:
        raise QAReportError(
            f"date {date.isoformat()} is older than {QA_VALID_DAYS} days; "
            "rerun the hardware qualification"
        )


def _validate_evidence(name: str, value: Any) -> None:
    if isinstance(value, str):
        entries: list[Any] = [value]
    elif isinstance(value, list) and value:
        entries = value
    else:
        raise QAReportError(
            f"{name}: evidence must be a non-empty path string or a non-empty "
            "list of path strings"
        )
    if any(not isinstance(entry, str) for entry in entries):
        raise QAReportError(f"{name}: evidence must contain only path strings")
    if any(_is_placeholder(entry) for entry in entries):
        raise QAReportError(
            f"{name}: evidence must name a real recording, log or report"
        )


def verify_report(report: Any, *, today: dt.date | None = None) -> None:
    """Accept *report* or raise :class:`QAReportError`.

    ``today`` exists so tests can pin the 30-day window without depending on
    the wall clock or on any real hardware.
    """
    if not isinstance(report, dict):
        raise QAReportError("QA report must be a JSON object")

    missing_fields = [
        key for key in ("reviewer", "hardware", "signedOff", "date", "checks")
        if key not in report
    ]
    if missing_fields:
        raise QAReportError("missing required fields: " + ", ".join(missing_fields))

    issues: list[str] = []
    reviewer = report.get("reviewer")
    if not isinstance(reviewer, str) or _is_placeholder(reviewer) or len(reviewer.strip()) < 3:
        issues.append("reviewer must name the independent person or team who ran the tests")
    try:
        _validate_hardware(report.get("hardware"))
    except QAReportError as error:
        issues.append(str(error))
    try:
        _validate_signed_off(report.get("signedOff"))
    except QAReportError as error:
        issues.append(str(error))
    try:
        _validate_date(report.get("date"), today or dt.date.today())
    except QAReportError as error:
        issues.append(str(error))

    checks = report.get("checks")
    if not isinstance(checks, dict):
        issues.append("checks must be a JSON object")
    else:
        for name in REQUIRED_CHECKS:
            result = checks.get(name)
            if not isinstance(result, dict):
                issues.append(f"{name}: missing or not an object")
                continue
            if result.get("pass") is not True:
                issues.append(f"{name}: pass must be the boolean true")
            try:
                _validate_evidence(name, result.get("evidence"))
            except QAReportError as error:
                issues.append(str(error))

    if issues:
        raise QAReportError("production QA incomplete: " + "; ".join(issues))


def load_report(filename: str | pathlib.Path) -> Any:
    path = pathlib.Path(filename)
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError, ValueError) as error:
        raise QAReportError(f"cannot read QA report {path}: {error}") from error
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise QAReportError(f"QA report is not valid JSON: {error}") from error


def verify(filename: str | pathlib.Path, *, today: dt.date | None = None) -> None:
    try:
        report_path = pathlib.Path(filename).resolve()
    except (OSError, RuntimeError, ValueError) as error:
        raise QAReportError(f"cannot resolve QA report {filename!r}: {error}") from error
    report = load_report(report_path)
    verify_report(report, today=today)
    base_dir = report_path.parent.resolve()
    checks = report["checks"]
    for name in REQUIRED_CHECKS:
        evidence = checks[name]["evidence"]
        entries = [evidence] if isinstance(evidence, str) else evidence
        for entry in entries:
            try:
                path = pathlib.Path(entry)
                relative = not path.is_absolute()
                if relative:
                    path = base_dir / path
                path = path.resolve(strict=True)
                if relative and not path.is_relative_to(base_dir):
                    raise QAReportError(
                        f"{name}: relative evidence must stay within the QA report directory: {entry}"
                    )
                info = path.stat()
            except QAReportError:
                raise
            except (OSError, RuntimeError, ValueError) as error:
                raise QAReportError(f"{name}: evidence file is not readable: {entry}: {error}") from error
            if not stat.S_ISREG(info.st_mode) or not os.access(path, os.R_OK) or info.st_size == 0:
                raise QAReportError(f"{name}: evidence must name a non-empty regular file: {entry}")


def main(argv: list[str] | None = None, *, today: dt.date | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if len(arguments) != 1:
        print("usage: verify-release-qa.py <qa-report.json>", file=sys.stderr)
        return 2
    try:
        verify(arguments[0], today=today)
    except QAReportError as error:
        print("Production qualification rejected:", error, file=sys.stderr)
        return 2
    print("Manual qualification report complete; continue with build and notarization.")
    print("Report structure accepted; a human must still verify every cited evidence item.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
