"""Reject missing/expired manual macOS NAS production qualification reports."""
from __future__ import annotations
import datetime as dt
import json
import pathlib
import sys

REQUIRED = (
    "macos14_launch_close", "macos_current_launch_close",
    "apple_silicon_hardware", "touchid_and_password_recovery",
    "different_user_acl_http", "symlink_and_path_escape",
    "mount_unplug_reinsert", "copy_disk_full_and_rollback",
    "database_recovery_and_rollback", "backup_restore_10gib",
    "resumable_upload_5gib", "scan_10000_files",
    "android_lan_https", "sleep_wake_and_force_quit",
    "soak_72_hours", "smart_and_volume_health",
)

def verify(filename: str) -> None:
    obj=json.loads(pathlib.Path(filename).read_text(encoding="utf-8"))
    if not obj.get("reviewer") or not obj.get("hardware") or not obj.get("signedOff"):
        raise ValueError("QA reviewer, real hardware details and signoff required")
    date=dt.date.fromisoformat(obj["date"])
    if not (dt.date.today()-dt.timedelta(days=30)<=date<=dt.date.today()):
        raise ValueError("QA report must be dated within the last 30 days")
    results=obj.get("checks",{})
    missing=[item for item in REQUIRED if not isinstance(results.get(item),dict)
             or results[item].get("pass") is not True
             or not results[item].get("evidence")]
    if missing:
        raise ValueError("Production QA incomplete: "+", ".join(missing))

if __name__=="__main__":
    try:verify(sys.argv[1])
    except (ValueError, KeyError, IndexError, OSError) as error:
        print("Production qualification rejected:", error, file=sys.stderr)
        raise SystemExit(2) from error
    print("Manual qualification report complete; continue with build and notarization.")
