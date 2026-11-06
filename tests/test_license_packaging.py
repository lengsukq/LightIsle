"""Offline assertions that published LightIsle bundles carry the new license."""
from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LICENSE = ROOT / "LICENSE"
BUILD = ROOT / "scripts/build-macos.sh"
REQUIRED = "Required Notice: Copyright (c) 2026 lengsukq"
IDENTIFIER = "PolyForm-Noncommercial-1.0.0"


def main() -> None:
    license_text = LICENSE.read_text(encoding="utf-8")
    assert license_text.startswith("# PolyForm Noncommercial License 1.0.0\n")
    assert "https://polyformproject.org/licenses/noncommercial/1.0.0" in license_text
    assert REQUIRED in license_text
    assert "## Noncommercial Organizations" in license_text
    assert "## No Other Rights" in license_text

    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    assert IDENTIFIER in readme
    assert "COMMERCIAL.md" in readme
    assert "MIT 版本" in readme
    assert "旧" in (ROOT / "COMMERCIAL.md").read_text(encoding="utf-8")
    for name in ("CONTRIBUTING.md", "CONTRIBUTOR_LICENSE_AGREEMENT.md", "THIRD_PARTY_NOTICES.md"):
        assert (ROOT / name).is_file(), name

    package = json.loads((ROOT / "apps/web/package.json").read_text(encoding="utf-8"))
    lock = json.loads((ROOT / "apps/web/package-lock.json").read_text(encoding="utf-8"))
    assert package["license"] == IDENTIFIER
    assert lock["packages"][""]["license"] == IDENTIFIER

    script = BUILD.read_text(encoding="utf-8")
    for name in ("LICENSE", "COMMERCIAL.md", "THIRD_PARTY_NOTICES.md"):
        assert f'cp {name} "$APP/Contents/Resources/{name}"' in script
    assert script.index('cp LICENSE "$APP/Contents/Resources/LICENSE"') < script.index(
        'codesign --force --deep --sign - "$APP"'
    )
    print("PASS: noncommercial license, commercial notice, and macOS bundle packaging")


if __name__ == "__main__":
    main()
