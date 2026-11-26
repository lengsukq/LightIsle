#!/usr/bin/env python3
"""Build and verify the Git-hosted LightIsle Official Plugin Store (plugins-store/).

Reads plugin source directories under plugins-store/plugins/<id>/ plus shared
static assets under plugins-store/shared/, deterministically packages each
plugin into plugins-store/packages/<id>.liapp.zip (with embedded
package-manifest.json per-file SHA-256 digests), and generates
plugins-store/registry.json with outer archive SHA-256 digests and sizes.

Usage:
  python3 -B scripts/build-plugin-store.py          # rebuild packages & registry.json
  python3 -B scripts/build-plugin-store.py --check  # verify packages & registry.json match sources
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STORE_DIR = ROOT / "plugins-store"
SHARED_DIR = STORE_DIR / "shared"
PLUGINS_DIR = STORE_DIR / "plugins"
PACKAGES_DIR = STORE_DIR / "packages"
REGISTRY_PATH = STORE_DIR / "registry.json"

STORE_SCHEMA_VERSION = 1
PACKAGE_SCHEMA_VERSION = 1
STORE_NAME = "LightIsle 官方家庭轻应用商店"
STORE_REPO = "https://github.com/lengsukq/LightIsle"
FIXED_ZIP_DATE = (2026, 1, 1, 0, 0, 0)
FIXED_TIMESTAMP = "2026-01-01T00:00:00Z"

SHARED_CSS_PLACEHOLDER = "/*__LIGHTISLE_SHARED_CSS__*/"
SHARED_JS_PLACEHOLDER = "/*__LIGHTISLE_KV_JS__*/"

PLUGIN_ID_RE = re.compile(r"^[a-z][a-z0-9-]{0,40}$")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")
MAX_PACKAGE_BYTES = 64 * 1024 * 1024
SKIP_PARTS = {"node_modules", "__pycache__", ".venv", "venv"}

# Preserves a curated display order in the store catalog; any additional plugins
# added later are appended alphabetically after this list.
PREFERRED_ORDER = [
    "network-pulse",
    "family-subscriptions",
    "warranty-vault",
    "family-board",
    "medicine-expiry",
    "utility-ledger",
    "baby-growth",
    "house-info",
    "weekly-menu",
    "pet-care",
]

PLUGIN_TAGS = {
    "network-pulse": ["zero-ram", "network"],
    "family-subscriptions": ["zero-ram", "kv-sync", "reminders"],
    "warranty-vault": ["zero-ram", "kv-sync", "reminders"],
    "family-board": ["zero-ram", "kv-sync"],
    "medicine-expiry": ["zero-ram", "kv-sync", "reminders"],
    "utility-ledger": ["zero-ram", "kv-sync"],
    "baby-growth": ["zero-ram", "kv-sync"],
    "house-info": ["zero-ram", "kv-sync"],
    "weekly-menu": ["zero-ram", "kv-sync", "reminders"],
    "pet-care": ["zero-ram", "kv-sync", "reminders"],
}


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def should_skip(rel_posix: str, is_dir: bool) -> bool:
    parts = rel_posix.split("/")
    for part in parts:
        if not part or part.startswith(".") or part in SKIP_PARTS:
            return True
    if not is_dir:
        lower = rel_posix.lower()
        if lower == "env.json" or lower.endswith("/env.json") or lower == "package-manifest.json":
            return True
    return False


def load_shared_assets() -> tuple[str, str]:
    css_path = SHARED_DIR / "lightisle-shared.css"
    js_path = SHARED_DIR / "lightisle-kv.js"
    if not css_path.is_file() or not js_path.is_file():
        raise RuntimeError(f"missing shared assets under {SHARED_DIR}")
    return css_path.read_text(encoding="utf-8"), js_path.read_text(encoding="utf-8")


def sanitize_manifest(raw_manifest: dict, plugin_id: str) -> dict:
    if raw_manifest.get("schemaVersion") != 2:
        raise RuntimeError(f"{plugin_id}: plugin.json schemaVersion must be 2")
    if raw_manifest.get("id") != plugin_id:
        raise RuntimeError(f"{plugin_id}: plugin.json id mismatch ({raw_manifest.get('id')!r})")
    version = str(raw_manifest.get("version", "")).strip()
    if not SEMVER_RE.match(version):
        raise RuntimeError(f"{plugin_id}: invalid semver version {version!r}")
    name = str(raw_manifest.get("name", "")).strip()
    if not name:
        raise RuntimeError(f"{plugin_id}: plugin.json missing name")
    out = json.loads(json.dumps(raw_manifest))
    access = out.get("access")
    if isinstance(access, dict):
        access["allowedUserIDs"] = []
        access.pop("allowedUserIds", None)
        if access.get("policy") == "selected_members":
            access["policy"] = "admin_only"
    return out


def build_plugin_zip(plugin_dir: Path, shared_css: str, shared_js: str) -> tuple[bytes, dict]:
    plugin_id = plugin_dir.name
    if not PLUGIN_ID_RE.match(plugin_id):
        raise RuntimeError(f"invalid plugin directory id: {plugin_id!r}")

    manifest_path = plugin_dir / "plugin.json"
    if not manifest_path.is_file():
        raise RuntimeError(f"{plugin_id}: missing plugin.json")
    raw_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest = sanitize_manifest(raw_manifest, plugin_id)

    files_to_pack: list[tuple[str, bytes, int]] = []
    for root_dir, dirnames, filenames in os.walk(plugin_dir, followlinks=False):
        dirnames.sort()
        filenames.sort()
        cur = Path(root_dir)
        # Filter out skipped directories in-place.
        kept_dirs = []
        for d in dirnames:
            rel_d = (cur / d).relative_to(plugin_dir).as_posix()
            if (cur / d).is_symlink():
                raise RuntimeError(f"{plugin_id}: symlink not allowed ({rel_d})")
            if not should_skip(rel_d, True):
                kept_dirs.append(d)
        dirnames[:] = kept_dirs

        for fname in filenames:
            fpath = cur / fname
            rel_posix = fpath.relative_to(plugin_dir).as_posix()
            if fpath.is_symlink():
                raise RuntimeError(f"{plugin_id}: symlink not allowed ({rel_posix})")
            if should_skip(rel_posix, False):
                continue

            if rel_posix == "plugin.json":
                payload = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
                mode = 0o600
            else:
                raw_bytes = fpath.read_bytes()
                if rel_posix.endswith(".html"):
                    text = raw_bytes.decode("utf-8")
                    if SHARED_CSS_PLACEHOLDER in text:
                        text = text.replace(SHARED_CSS_PLACEHOLDER, shared_css, 1)
                    if SHARED_JS_PLACEHOLDER in text:
                        text = text.replace(SHARED_JS_PLACEHOLDER, shared_js, 1)
                    if SHARED_CSS_PLACEHOLDER in text or SHARED_JS_PLACEHOLDER in text:
                        raise RuntimeError(f"{plugin_id}: unresolved shared placeholder in {rel_posix}")
                    payload = text.encode("utf-8")
                else:
                    payload = raw_bytes
                st_mode = fpath.stat().st_mode
                mode = 0o700 if (st_mode & 0o100) else 0o600
            files_to_pack.append((rel_posix, payload, mode))

    files_to_pack.sort(key=lambda item: item[0])
    total_uncompressed = sum(len(item[1]) for item in files_to_pack)
    if total_uncompressed == 0 or total_uncompressed > MAX_PACKAGE_BYTES:
        raise RuntimeError(f"{plugin_id}: invalid package uncompressed size {total_uncompressed}")

    buf = io.BytesIO()
    manifest_entries = []
    with zipfile.ZipFile(buf, mode="w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel_posix, payload, mode in files_to_pack:
            zi = zipfile.ZipInfo(filename=rel_posix, date_time=FIXED_ZIP_DATE)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = (mode & 0o777) << 16
            zf.writestr(zi, payload)
            manifest_entries.append({
                "path": rel_posix,
                "size": len(payload),
                "sha256": sha256_hex(payload),
            })

        pkg_manifest = {
            "schemaVersion": PACKAGE_SCHEMA_VERSION,
            "appId": manifest["id"],
            "name": manifest["name"],
            "version": manifest["version"],
            "exportedAt": FIXED_TIMESTAMP,
            "fileCount": len(manifest_entries),
            "files": manifest_entries,
        }
        pkg_raw = (json.dumps(pkg_manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        zi = zipfile.ZipInfo(filename="package-manifest.json", date_time=FIXED_ZIP_DATE)
        zi.compress_type = zipfile.ZIP_DEFLATED
        zi.external_attr = (0o600) << 16
        zf.writestr(zi, pkg_raw)

    zip_bytes = buf.getvalue()
    web_cfg = manifest.get("web") or {}
    access_cfg = manifest.get("access") or {}
    icon_rel = str(manifest.get("icon") or "").strip()
    icon_path = f"plugins/{plugin_id}/{icon_rel}" if icon_rel and (plugin_dir / icon_rel).is_file() else ""
    tags = manifest.get("tags") if isinstance(manifest.get("tags"), list) else PLUGIN_TAGS.get(plugin_id, [])

    entry = {
        "id": manifest["id"],
        "name": manifest["name"],
        "version": manifest["version"],
        "author": manifest.get("author", "LightIsle Official"),
        "category": manifest.get("category", "utility"),
        "mode": web_cfg.get("mode", "static"),
        "defaultScope": access_cfg.get("policy", "admin_only"),
        "description": manifest.get("description", ""),
        "tags": tags,
        "iconPath": icon_path,
        "packagePath": f"packages/{plugin_id}.liapp.zip",
        "sha256": sha256_hex(zip_bytes),
        "sizeBytes": len(zip_bytes),
    }
    return zip_bytes, entry


def ordered_plugin_dirs() -> list[Path]:
    if not PLUGINS_DIR.is_dir():
        raise RuntimeError(f"missing plugins directory: {PLUGINS_DIR}")
    dirs = [p for p in PLUGINS_DIR.iterdir() if p.is_dir() and not p.name.startswith(".")]
    order_index = {pid: idx for idx, pid in enumerate(PREFERRED_ORDER)}
    dirs.sort(key=lambda p: (order_index.get(p.name, len(PREFERRED_ORDER)), p.name))
    return dirs


def main() -> int:
    parser = argparse.ArgumentParser(description="Build or check LightIsle Git plugin store artifacts.")
    parser.add_argument("--check", action="store_true", help="Verify packages and registry.json are up to date")
    args = parser.parse_args()

    shared_css, shared_js = load_shared_assets()
    plugin_dirs = ordered_plugin_dirs()
    if not plugin_dirs:
        print("ERROR: no plugins found in plugins-store/plugins/", file=sys.stderr)
        return 1

    built_packages: dict[str, bytes] = {}
    registry_entries: list[dict] = []
    for pdir in plugin_dirs:
        zip_bytes, entry = build_plugin_zip(pdir, shared_css, shared_js)
        built_packages[f"{pdir.name}.liapp.zip"] = zip_bytes
        registry_entries.append(entry)

    registry_doc = {
        "schemaVersion": STORE_SCHEMA_VERSION,
        "storeName": STORE_NAME,
        "repository": STORE_REPO,
        "updatedAt": FIXED_TIMESTAMP,
        "plugins": registry_entries,
    }
    expected_registry = (json.dumps(registry_doc, ensure_ascii=False, indent=2) + "\n").encode("utf-8")

    if args.check:
        errors: list[str] = []
        if not REGISTRY_PATH.is_file() or REGISTRY_PATH.read_bytes() != expected_registry:
            errors.append(f"{REGISTRY_PATH.relative_to(ROOT)} is out of date")
        if not PACKAGES_DIR.is_dir():
            errors.append(f"{PACKAGES_DIR.relative_to(ROOT)} directory is missing")
        else:
            existing = {p.name for p in PACKAGES_DIR.iterdir() if p.is_file() and p.name.endswith(".liapp.zip")}
            expected_names = set(built_packages.keys())
            for extra in sorted(existing - expected_names):
                errors.append(f"stale package artifact: plugins-store/packages/{extra}")
            for name, payload in sorted(built_packages.items()):
                pkg_path = PACKAGES_DIR / name
                if not pkg_path.is_file() or pkg_path.read_bytes() != payload:
                    errors.append(f"out-of-date package artifact: plugins-store/packages/{name}")
        if errors:
            for err in errors:
                print(f"ERROR: {err}", file=sys.stderr)
            print("Run `python3 -B scripts/build-plugin-store.py` to refresh store artifacts.", file=sys.stderr)
            return 1
        print(f"PASS: plugin store verified ({len(registry_entries)} plugins, SHA-256 & registry.json in sync)")
        return 0

    PACKAGES_DIR.mkdir(parents=True, exist_ok=True)
    for existing_pkg in PACKAGES_DIR.glob("*.liapp.zip"):
        if existing_pkg.name not in built_packages:
            existing_pkg.unlink()
    for name, payload in sorted(built_packages.items()):
        (PACKAGES_DIR / name).write_bytes(payload)
    REGISTRY_PATH.write_bytes(expected_registry)
    print(f"Built plugin store: {len(registry_entries)} plugins -> {REGISTRY_PATH.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
