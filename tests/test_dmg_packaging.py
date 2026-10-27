"""Offline checks of the real drag-to-Applications DMG packaging script."""
from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]

STUB = r'''#!/usr/bin/env python3
import os
import pathlib
import shutil
import sys

tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if tool == "uname":
    print("Darwin")
    raise SystemExit(0)
if tool == "ditto":
    source, target = map(pathlib.Path, args)
    shutil.copytree(source, target, symlinks=True)
    raise SystemExit(0)
if tool == "hdiutil":
    if args[0] == "create":
        source = pathlib.Path(args[args.index("-srcfolder") + 1])
        assert (source / "LightIsle.app/Contents/Info.plist").is_file()
        assert (source / "Applications").is_symlink()
        assert os.readlink(source / "Applications") == "/Applications"
        pathlib.Path(args[-1]).write_bytes(b"mocked valid image")
        raise SystemExit(0)
    if args[0] == "verify":
        assert pathlib.Path(args[-1]).is_file()
        if os.environ.get("FAIL_VERIFY") == "1":
            raise SystemExit(7)
        raise SystemExit(0)
raise SystemExit(2)
'''


def setup(base: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path, dict[str, str]]:
    repo = base / "repo"
    (repo / "scripts").mkdir(parents=True)
    (repo / "dist").mkdir()
    script = repo / "scripts/package-dmg.sh"
    shutil.copy2(ROOT / "scripts/package-dmg.sh", script)
    app = repo / "dist/LightIsle.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Info.plist").write_text("<plist/>", encoding="utf-8")
    (app / "Contents/MacOS/LightIsle").write_bytes(b"arm64 test fixture")
    output = repo / "dist/LightIsle-dev.dmg"
    bin_dir = base / "bin"
    bin_dir.mkdir()
    dispatcher = bin_dir / "tool-stub"
    dispatcher.write_text(f"#!{sys.executable}\n" + STUB, encoding="utf-8")
    dispatcher.chmod(0o755)
    for tool in ("uname", "hdiutil", "ditto"):
        (bin_dir / tool).symlink_to(dispatcher)
    env = dict(os.environ)
    env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
    return script, app, output, env


def invoke(script: pathlib.Path, app: pathlib.Path, image: pathlib.Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/bin/bash", str(script), str(app), str(image)],
        text=True,
        capture_output=True,
        env=env,
        timeout=25,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="lightisle-dmg-packaging-") as directory:
        script, app, image, env = setup(pathlib.Path(directory))
        result = invoke(script, app, image, env)
        assert result.returncode == 0, result.stdout + result.stderr
        assert image.read_bytes() == b"mocked valid image"
        assert not list(image.parent.glob(".lightisle-dmg.*")), "staging directory was not cleaned"

        image.write_bytes(b"last verified image")
        failed = dict(env, FAIL_VERIFY="1")
        result = invoke(script, app, image, failed)
        assert result.returncode != 0, "a failed image verification was accepted"
        assert image.read_bytes() == b"last verified image", "failed build clobbered previous image"
        assert not list(image.parent.glob(".lightisle-dmg.*"))

        (app / "Contents/MacOS/LightIsle").unlink()
        result = invoke(script, app, image, env)
        assert result.returncode != 0, "incomplete app bundle was packaged"
        assert image.read_bytes() == b"last verified image"

    print("PASS: DMG packaging uses real app copy, Applications alias, verified atomic publish")


if __name__ == "__main__":
    main()
