"""Run the release flow against local tool stubs; never contacts Apple services."""
from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
RELEASE_SCRIPT = ROOT / "scripts/release-macos.sh"
TICKET = "LightIsle.app/Contents/Resources/notary-ticket.test"

STUB = r'''#!/usr/bin/env python3
import os
import pathlib
import sys
import zipfile

tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
log = pathlib.Path(os.environ["ACTION_LOG"])
with log.open("a", encoding="utf-8") as stream:
    stream.write(tool + "\t" + "\t".join(args) + "\n")

def result(code=0, output="", error=""):
    if output:
        print(output)
    if error:
        print(error, file=sys.stderr)
    raise SystemExit(code)

if tool == "uname":
    result(output="Darwin" if args == ["-s"] else "arm64")
if tool in ("python3", "go", "spctl"):
    result()
if tool == "lipo":
    result(output=os.environ.get("MOCK_ARCHS", "arm64"))
if tool == "bash":
    if args != ["scripts/build-macos.sh"]:
        result(2, error="unexpected bash invocation")
    app = pathlib.Path.cwd() / "dist/LightIsle.app"
    for relative in (
        "Contents/MacOS/LightIsle",
        "Contents/Resources/core/lightisled",
        "Contents/Resources/core/lightisle-recovery",
        "Contents/Resources/core/lightisle-media-worker",
    ):
        binary = app / relative
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(b"offline packaging fixture")
        binary.chmod(0o755)
    result()
if tool == "codesign":
    if args and args[0] == "-dv":
        result(error="Authority=Developer ID Application: Offline Test")
    result()
if tool == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        if not pathlib.Path(args[2]).is_file():
            result(2, error="submission archive missing")
        result()
    if args[:2] == ["stapler", "staple"]:
        marker = pathlib.Path(args[2]) / "Contents/Resources/notary-ticket.test"
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("mock stapled ticket", encoding="utf-8")
        result()
    if args[:2] == ["stapler", "validate"]:
        marker = pathlib.Path(args[2]) / "Contents/Resources/notary-ticket.test"
        present = marker.is_file()
        with log.open("a", encoding="utf-8") as stream:
            stream.write("STAPLE_VALIDATION\t" + str(args[2]) + "\t" + ("present" if present else "missing") + "\n")
        result(0 if present else 7, error="ticket missing" if not present else "")
    result(2, error="unexpected xcrun invocation")
if tool == "ditto":
    if args[0] == "-c":
        app, archive = pathlib.Path(args[-2]), pathlib.Path(args[-1])
        archive.parent.mkdir(parents=True, exist_ok=True)
        drop_ticket = archive.name == "LightIsle.zip" and os.environ.get("DROP_FINAL_TICKET") == "1"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
            for path in app.rglob("*"):
                if not path.is_file():
                    continue
                if drop_ticket and path.name == "notary-ticket.test":
                    continue
                output.write(path, path.relative_to(app.parent).as_posix())
        result()
    if args[0] == "-x":
        archive, destination = pathlib.Path(args[2]), pathlib.Path(args[3])
        with zipfile.ZipFile(archive) as source:
            source.extractall(destination)
        result()
    result(2, error="unexpected ditto invocation")
result(2, error="unexpected tool: " + tool)
'''


def create_sandbox(base: pathlib.Path, *, arches: str = "arm64", drop_ticket: bool = False):
    repo = base / "repo"
    bin_dir = base / "bin"
    temp_dir = base / "tmp"
    (repo / "scripts").mkdir(parents=True)
    (repo / "dist").mkdir()
    bin_dir.mkdir()
    temp_dir.mkdir()
    shutil.copy2(RELEASE_SCRIPT, repo / "scripts/release-macos.sh")
    (repo / "scripts/verify-release-qa.py").write_text("", encoding="utf-8")
    qa_report = repo / "qa-report.json"
    qa_report.write_text("{}", encoding="utf-8")
    action_log = base / "actions.log"
    dispatcher = bin_dir / "tool-stub"
    dispatcher.write_text(f"#!{sys.executable}\n" + STUB, encoding="utf-8")
    dispatcher.chmod(0o755)
    for name in ("uname", "python3", "go", "bash", "lipo", "codesign", "xcrun", "spctl", "ditto"):
        (bin_dir / name).symlink_to(dispatcher)
    env = os.environ.copy()
    env.update(
        {
            "PATH": str(bin_dir) + os.pathsep + env.get("PATH", ""),
            "TMPDIR": str(temp_dir),
            "ACTION_LOG": str(action_log),
            "LIGHTISLE_DEVELOPER_ID": "Developer ID Application: Offline Test",
            "LIGHTISLE_NOTARY_PROFILE": "offline-test-profile",
            "LIGHTISLE_QA_REPORT": str(qa_report),
            "MOCK_ARCHS": arches,
            "DROP_FINAL_TICKET": "1" if drop_ticket else "0",
        }
    )
    return repo, env, action_log


def run_release(base: pathlib.Path, *, arches: str = "arm64", drop_ticket: bool = False):
    repo, env, action_log = create_sandbox(base, arches=arches, drop_ticket=drop_ticket)
    return repo, action_log, subprocess.run(
        ["/bin/bash", str(repo / "scripts/release-macos.sh")],
        cwd=repo,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="lightisle-release-success-") as temporary:
        repo, actions, result = run_release(pathlib.Path(temporary))
        assert result.returncode == 0, result.stdout + result.stderr
        final_zip = repo / "dist/LightIsle.zip"
        submission_zip = repo / "dist/LightIsle-notary-submit.zip"
        with zipfile.ZipFile(final_zip) as archive:
            assert TICKET in archive.namelist(), "final archive omitted the stapled ticket"
            assert (
                "LightIsle.app/Contents/Resources/core/lightisle-media-worker" in archive.namelist()
            ), "final archive omitted the media worker"
        assert not submission_zip.exists(), "temporary notary submission archive was retained"
        events = actions.read_text(encoding="utf-8")
        validations = [line.split("\t") for line in events.splitlines() if line.startswith("STAPLE_VALIDATION\t")]
        assert len(validations) == 2 and validations[0][2] == "present"
        assert validations[0][1] == str(repo / "dist/LightIsle.app")
        assert validations[1][2] == "present" and "lightisle-release-verify." in validations[1][1]
        assert any(
            line.startswith("codesign\t--verify\t--deep\t--strict\t--verbose=2\t")
            and "lightisle-release-verify." in line
            for line in events.splitlines()
        ), "the extracted app signature was not checked"
        assert any(
            line.startswith("spctl\t--assess\t--type\texecute\t--verbose=2\t")
            and "lightisle-release-verify." in line
            for line in events.splitlines()
        ), "the extracted app was not assessed"
        assert any(
            line.startswith("lipo\t-archs\t") and line.endswith("/lightisle-media-worker")
            and "lightisle-release-verify." in line
            for line in events.splitlines()
        ), "the extracted media worker architecture was not checked"
        assert any(
            line.startswith("codesign\t--verify\t--strict\t--verbose=2\t")
            and line.endswith("/lightisle-media-worker")
            and "lightisle-release-verify." in line
            for line in events.splitlines()
        ), "the extracted media worker signature was not checked"
        assert "xcrun\tnotarytool\tsubmit\t" in events, "the notary stub was not used"

    with tempfile.TemporaryDirectory(prefix="lightisle-release-wrong-arch-") as temporary:
        repo, actions, result = run_release(pathlib.Path(temporary), arches="arm64 x86_64")
        assert result.returncode != 0, "universal executable unexpectedly passed the arm64-only gate"
        assert "xcrun\tnotarytool\tsubmit\t" not in actions.read_text(encoding="utf-8")
        assert not (repo / "dist/LightIsle-notary-submit.zip").exists()
        assert not (repo / "dist/LightIsle.zip").exists()

    with tempfile.TemporaryDirectory(prefix="lightisle-release-lost-ticket-") as temporary:
        repo, actions, result = run_release(pathlib.Path(temporary), drop_ticket=True)
        assert result.returncode != 0, "release accepted an archive missing its stapled ticket"
        events = actions.read_text(encoding="utf-8")
        validations = [line.split("\t") for line in events.splitlines() if line.startswith("STAPLE_VALIDATION\t")]
        assert len(validations) == 2 and validations[1][2] == "missing"
        assert "lightisle-release-verify." in validations[1][1]
        assert not (repo / "dist/LightIsle-notary-submit.zip").exists()
        assert not (repo / "dist/LightIsle.zip").exists(), "failed distribution archive was left publishable"

    print("PASS: mocked release accepted stapled ZIP and rejected wrong architecture or lost ticket")


if __name__ == "__main__":
    main()
