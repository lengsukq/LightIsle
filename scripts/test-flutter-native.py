#!/usr/bin/env python3
"""Run the Flutter native smoke flow against a temporary local Go service."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import queue
import re
import signal
import time
import shutil
import subprocess
import sys
import tempfile
import threading
from urllib.parse import urlsplit


REPOSITORY = Path(__file__).resolve().parents[1]
FLUTTER_PROJECT = REPOSITORY / "apps" / "flutter"
GO_PROJECT = REPOSITORY / "core"
FIXTURE_MAKER_SOURCE = REPOSITORY / "tests" / "MediaWorkerFixtureMaker.swift"
PACKAGED_CORE = (
    REPOSITORY
    / "dist"
    / "LightIsle.app"
    / "Contents"
    / "Resources"
    / "core"
    / "lightisled"
)
OWNER_USERNAME = "flutter_smoke_admin"
OWNER_PASSWORD = "Flutter-Smoke-Only-7391!"
TEXT_FIXTURE_NAME = "LightIsleSmokeNotes.txt"
MOVIE_FIXTURE_NAME = "LightIsleNativeSmoke.mp4"


class SmokeError(RuntimeError):
    pass


def _read_stdout_lines(stream, output_queue: queue.Queue[str | None]) -> None:
    try:
        for line in stream:
            output_queue.put(line.rstrip("\r\n"))
    finally:
        output_queue.put(None)


def _copy_stage_screenshot(device: str, name: str, output: str) -> None:
    xcrun = shutil.which("xcrun")
    if xcrun is None:
        return
    result = subprocess.run(
        [xcrun, "simctl", "get_app_container", device, "top.lengsu.lightisle.client", "data"],
        text=True, capture_output=True, check=False, timeout=20,
    )
    if result.returncode != 0:
        return
    root = Path(result.stdout.strip())
    candidates = [root / parent / "lightisle-native-evidence" / f"{name}.png"
                  for parent in ("tmp", "Library/Caches")]
    source = next((path for path in candidates if path.is_file()), None)
    if source is None:
        source = next((path for path in root.rglob(f"{name}.png")
                       if path.parent.name == "lightisle-native-evidence"), None)
    if source is not None:
        target = Path(output).expanduser().resolve()
        directory = target.parent / (target.stem + "-screens")
        directory.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, directory / source.name)
        if name == "overview":
            shutil.copy2(source, target)
        print(f"Captured native {name}: {directory / source.name}", flush=True)


def _run_flutter_test(command: list[str], arguments, capture_stages: bool):
    process = subprocess.Popen(command, cwd=FLUTTER_PROJECT, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, bufsize=1,
                               start_new_session=True)
    lines: queue.Queue[str | None] = queue.Queue()
    threading.Thread(target=_read_stdout_lines, args=(process.stdout, lines), daemon=True).start()
    deadline = time.monotonic() + arguments.test_timeout
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SmokeError("Flutter native smoke timed out.")
            try:
                line = lines.get(timeout=min(1, remaining))
            except queue.Empty:
                continue
            if line is None:
                break
            print(line, flush=True)
            marker = re.search(r"LIGHTISLE_SCREEN:([a-z]+)", line)
            if capture_stages and marker:
                _copy_stage_screenshot(arguments.device, marker.group(1), arguments.screenshot)
        return subprocess.CompletedProcess(command, process.wait(timeout=10))
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)


def _stderr_tail(path: Path, limit: int = 6000) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")[-limit:]
    except OSError:
        return ""


def _next_core_line(
    output_queue: queue.Queue[str | None],
    process: subprocess.Popen[str],
    stderr_path: Path,
    stage: str,
    timeout: float = 20,
) -> str:
    try:
        line = output_queue.get(timeout=timeout)
    except queue.Empty as error:
        raise SmokeError(
            f"Timed out waiting for Go core {stage}.\n{_stderr_tail(stderr_path)}"
        ) from error
    if line is None:
        raise SmokeError(
            f"Go core exited before {stage} (status {process.poll()}).\n"
            f"{_stderr_tail(stderr_path)}"
        )
    return line


def _expect_core_prefix(
    output_queue: queue.Queue[str | None],
    process: subprocess.Popen[str],
    stderr_path: Path,
    prefix: str,
) -> str:
    line = _next_core_line(output_queue, process, stderr_path, prefix)
    if not line.startswith(prefix):
        raise SmokeError(
            f"Unexpected Go core startup response while waiting for {prefix!r}: {line!r}.\n"
            f"{_stderr_tail(stderr_path)}"
        )
    return line


def _resolve_flutter(explicit: str | None) -> str:
    candidate = explicit or shutil.which("flutter") or "/opt/homebrew/bin/flutter"
    resolved = shutil.which(candidate) if not Path(candidate).is_absolute() else candidate
    if resolved is None or not Path(resolved).is_file():
        raise SmokeError(
            "Flutter was not found. Pass --flutter with the local Flutter executable."
        )
    return str(Path(resolved).resolve())


def _detect_platform(flutter: str, device: str, explicit: str | None) -> tuple[str, bool]:
    if explicit:
        platform = explicit
        simulator = platform == "ios" and len(device) == 36
        return platform, simulator

    result = subprocess.run(
        [flutter, "devices", "--machine"],
        cwd=FLUTTER_PROJECT,
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )
    if result.returncode == 0:
        try:
            devices = json.loads(result.stdout)
        except json.JSONDecodeError:
            devices = []
        for entry in devices:
            if entry.get("id") != device:
                continue
            target = str(entry.get("targetPlatform", "")).lower()
            if "android" in target:
                return "android", False
            if target == "ios":
                return "ios", entry.get("emulator") is True
            if "darwin" in target or target == "macos":
                return "macos", False
            break

    normalized = device.lower()
    if normalized == "macos":
        return "macos", False
    if normalized.startswith("emulator-"):
        return "android", False
    if len(device) == 36:
        return "ios", True
    raise SmokeError(
        f"Could not identify native platform for device {device!r}; pass --platform."
    )


def _resolve_core(
    explicit: str | None,
    temporary_directory: Path,
) -> tuple[Path, str]:
    if explicit:
        core = Path(explicit).expanduser().resolve()
        if not core.is_file() or not os.access(core, os.X_OK):
            raise SmokeError(f"The selected core binary is not executable: {core}")
        return core, "explicit packaged/local binary"

    go = shutil.which("go")
    if go is None:
        raise SmokeError(
            "Go was not found. Pass --core with an existing packaged lightisled binary."
        )
    output = temporary_directory / "lightisled"
    command = [go, "build", "-mod=readonly", "-o", str(output), "./cmd/lightisled"]
    print("Building the current Go core source into a temporary directory…", flush=True)
    result = subprocess.run(
        command,
        cwd=GO_PROJECT,
        text=True,
        capture_output=True,
        check=False,
        timeout=180,
    )
    if result.returncode != 0:
        details = (result.stdout + result.stderr).strip()
        if len(details) > 9000:
            details = details[-9000:]
        packaged_hint = (
            f"\nA packaged core is available at {PACKAGED_CORE}.\n"
            f"Rerun with: python3 scripts/test-flutter-native.py --device <device> "
            f"--core '{PACKAGED_CORE}'"
            if PACKAGED_CORE.is_file()
            else "\nPass --core with an existing packaged lightisled binary."
        )
        raise SmokeError(
            "The current Go source did not compile; no older binary was selected.\n"
            f"{details}{packaged_hint}"
        )
    return output, "built from current Go source"


def _resolve_media_worker(explicit: str | None, core: Path) -> Path:
    if explicit:
        worker = Path(explicit).expanduser().resolve()
        if worker.is_file() and os.access(worker, os.X_OK):
            return worker
        raise SmokeError(f"The selected media worker is not executable: {worker}")

    candidates = [
        core.with_name("lightisle-media-worker"),
        REPOSITORY / ".build" / "out" / "Products" / "Release" / "lightisle-media-worker",
        REPOSITORY / ".build" / "out" / "Products" / "Debug" / "lightisle-media-worker",
        REPOSITORY / ".build" / "debug" / "lightisle-media-worker",
        REPOSITORY
        / "dist"
        / "LightIsle.app"
        / "Contents"
        / "Resources"
        / "core"
        / "lightisle-media-worker",
    ]
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    raise SmokeError(
        "No existing lightisle-media-worker executable was found. Pass --media-worker "
        "with the bundled worker path. The smoke test needs it to probe and play the fixture."
    )


def _make_fixtures(shared_directory: Path, temporary_directory: Path) -> None:
    shared_directory.mkdir(parents=True, exist_ok=True)
    (shared_directory / TEXT_FIXTURE_NAME).write_text(
        "Temporary Flutter native smoke fixture.\n", encoding="utf-8"
    )
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        raise SmokeError("swiftc is required to make the local H.264 test video.")
    maker = temporary_directory / "media-fixture-maker"
    compile_result = subprocess.run(
        [
            swiftc,
            "-swift-version",
            "5",
            "-parse-as-library",
            "-suppress-warnings",
            str(FIXTURE_MAKER_SOURCE),
            "-o",
            str(maker),
        ],
        cwd=REPOSITORY,
        text=True,
        capture_output=True,
        check=False,
        timeout=90,
    )
    if compile_result.returncode != 0:
        raise SmokeError(
            "Could not compile the local Swift media fixture maker.\n"
            f"{compile_result.stdout}{compile_result.stderr}"
        )
    make_result = subprocess.run(
        [str(maker), "mp4", str(shared_directory / MOVIE_FIXTURE_NAME)],
        cwd=REPOSITORY,
        text=True,
        capture_output=True,
        check=False,
        timeout=45,
    )
    if make_result.returncode != 0:
        raise SmokeError(
            "Could not generate the local H.264 media fixture.\n"
            f"{make_result.stdout}{make_result.stderr}"
        )


def _close_core(process: subprocess.Popen[str] | None) -> int | None:
    if process is None:
        return None
    if process.poll() is not None:
        return process.returncode
    if process.stdin is not None:
        try:
            process.stdin.close()
        except OSError:
            pass
    try:
        return process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            return process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            return process.wait(timeout=5)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run LightIsle's Flutter native smoke flow against an isolated local Go core. "
            "By default the current Go source is built into a temporary directory."
        )
    )
    parser.add_argument("--device", required=True, help="Flutter device ID from flutter devices")
    parser.add_argument(
        "--platform",
        choices=("android", "ios", "macos"),
        help="Override device platform detection; normally inferred from Flutter.",
    )
    parser.add_argument(
        "--core",
        help="Use this existing packaged/local Go core instead of compiling current source.",
    )
    parser.add_argument(
        "--media-worker",
        help="Use this existing bundled lightisle-media-worker executable.",
    )
    parser.add_argument("--flutter", help="Path to a local Flutter executable.")
    parser.add_argument(
        "--https", action="store_true",
        help="Test the Go core's default self-signed LAN HTTPS with an explicit certificate fingerprint (macOS / iOS).",
    )
    parser.add_argument(
        "--screenshot",
        help="Optional iOS Simulator overview screenshot path; page screenshots are copied to <stem>-screens while the app is running.",
    )
    parser.add_argument(
        "--test-timeout",
        type=int,
        default=900,
        help="Maximum seconds for flutter test (default: 900).",
    )
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    if arguments.test_timeout < 60:
        raise SmokeError("--test-timeout must be at least 60 seconds.")

    flutter = _resolve_flutter(arguments.flutter)
    platform, is_simulator = _detect_platform(
        flutter, arguments.device, arguments.platform
    )
    if arguments.https and platform == "android":
        raise SmokeError("--https currently requires a macOS or iOS Simulator target on the same Mac.")
    adb_reverse = False
    adb_reverse_port: int | None = None
    process: subprocess.Popen[str] | None = None
    output_thread: threading.Thread | None = None
    source = ""
    server_url = ""
    fingerprint = ""

    with tempfile.TemporaryDirectory(prefix="lightisle-flutter-native-") as scratch:
        temporary_directory = Path(scratch)
        data_directory = temporary_directory / "data"
        shared_directory = data_directory / "SharedFiles"
        data_directory.mkdir(parents=True, exist_ok=True)

        core, source = _resolve_core(arguments.core, temporary_directory)
        media_worker = _resolve_media_worker(arguments.media_worker, core)
        _make_fixtures(shared_directory, temporary_directory)

        print(f"Target device: {arguments.device} ({platform})")
        print(f"Go core binary: {core} ({source})")
        print(f"Media worker: {media_worker}")
        print("Go data directory: isolated temporary directory")

        stderr_path = temporary_directory / "lightisled.stderr.log"
        stderr_file = stderr_path.open("w", encoding="utf-8")
        try:
            process = subprocess.Popen(
                [
                    str(core),
                    "-port",
                    "0",
                    "-data-dir",
                    str(data_directory),
                    "-media-worker",
                    str(media_worker),
                ],
                cwd=REPOSITORY,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=stderr_file,
                text=True,
                bufsize=1,
            )
            assert process.stdout is not None
            output_queue: queue.Queue[str | None] = queue.Queue()
            output_thread = threading.Thread(
                target=_read_stdout_lines,
                args=(process.stdout, output_queue),
                name="lightisled-stdout",
                daemon=True,
            )
            output_thread.start()

            ready = _expect_core_prefix(
                output_queue, process, stderr_path, "LIGHTISLE_READY "
            )
            server_url = ready.removeprefix("LIGHTISLE_READY ")
            _expect_core_prefix(
                output_queue, process, stderr_path, "LIGHTISLE_CONFIGURED 0"
            )
            _expect_core_prefix(
                output_queue, process, stderr_path, "LIGHTISLE_SHARE_ON "
            )
            _expect_core_prefix(
                output_queue, process, stderr_path, "LIGHTISLE_SHARE_PATH "
            )

            setup_json = json.dumps(
                {"username": OWNER_USERNAME, "password": OWNER_PASSWORD},
                separators=(",", ":"),
            ).encode("utf-8")
            setup_token = base64.urlsafe_b64encode(setup_json).decode("ascii").rstrip("=")
            assert process.stdin is not None
            process.stdin.write(f"admin init {setup_token}\n")
            process.stdin.flush()
            _expect_core_prefix(
                output_queue, process, stderr_path, "LIGHTISLE_INITIALIZED"
            )
            _expect_core_prefix(
                output_queue, process, stderr_path, "LIGHTISLE_ADMIN_ACCOUNT "
            )
            if arguments.https:
                process.stdin.write("remote on\n")
                process.stdin.flush()
                remote = _expect_core_prefix(
                    output_queue, process, stderr_path, "LIGHTISLE_REMOTE_ON "
                )
                fields = remote.split()
                if len(fields) != 3 or not re.fullmatch(r"[a-fA-F0-9]{64}", fields[2]):
                    raise SmokeError("Go core returned an invalid HTTPS identity.")
                server_url, fingerprint = fields[1:]
                print("Testing explicit pin verification against the temporary core's self-signed LAN HTTPS.")

            port = urlsplit(server_url).port
            if port is None:
                raise SmokeError(f"Go core returned an invalid loopback address: {server_url}")

            if platform == "android":
                adb = shutil.which("adb")
                if adb is None:
                    raise SmokeError(
                        "Android smoke requires the local adb executable for a temporary loopback reverse tunnel."
                    )
                reverse = subprocess.run(
                    [adb, "-s", arguments.device, "reverse", f"tcp:{port}", f"tcp:{port}"],
                    text=True,
                    capture_output=True,
                    check=False,
                    timeout=20,
                )
                if reverse.returncode != 0:
                    raise SmokeError(
                        f"Could not set up temporary adb reverse for the local test server.\n"
                        f"{reverse.stdout}{reverse.stderr}"
                    )
                adb_reverse = True
                adb_reverse_port = port

            test_command = [
                flutter,
                "test",
                "integration_test/client_smoke_test.dart",
                "-d",
                arguments.device,
                "--no-pub",
                f"--dart-define=LIGHTISLE_SMOKE_SERVER={server_url}",
                f"--dart-define=LIGHTISLE_SMOKE_USERNAME={OWNER_USERNAME}",
                f"--dart-define=LIGHTISLE_SMOKE_PASSWORD={OWNER_PASSWORD}",
                f"--dart-define=LIGHTISLE_SMOKE_FINGERPRINT={fingerprint}",
                f"--dart-define=LIGHTISLE_SMOKE_CAPTURE={str(platform == 'ios' and is_simulator and bool(arguments.screenshot)).lower()}",
            ]
            print(
                f"Running the login, files, gallery, cinema, playback, settings, and logout flow on {arguments.device}…",
                flush=True,
            )
            test_result = _run_flutter_test(
                test_command, arguments,
                platform == "ios" and is_simulator and bool(arguments.screenshot),
            )

            if arguments.screenshot:
                if platform == "ios" and is_simulator:
                    screenshot_path = Path(arguments.screenshot).expanduser().resolve()
                    if screenshot_path.is_file():
                        print(f"Native overview screenshot: {screenshot_path}")
                    else:
                        print("Warning: native screenshots were not captured during the test.")
                else:
                    print("Warning: --screenshot is available for iOS Simulator targets only.")
        finally:
            core_exit = _close_core(process)
            if adb_reverse:
                adb = shutil.which("adb")
                if adb is not None and adb_reverse_port is not None:
                    subprocess.run(
                        [
                            adb,
                            "-s",
                            arguments.device,
                            "reverse",
                            "--remove",
                            f"tcp:{adb_reverse_port}",
                        ],
                        text=True,
                        capture_output=True,
                        check=False,
                        timeout=20,
                    )
            stderr_file.close()
            if output_thread is not None:
                output_thread.join(timeout=2)

        if core_exit != 0:
            raise SmokeError(
                f"The isolated Go core did not exit cleanly after stdin closed (status {core_exit}).\n"
                f"{_stderr_tail(stderr_path)}"
            )
        if test_result.returncode != 0:
            return test_result.returncode
        print("PASS: Flutter native smoke flow completed; temporary server data was removed.")
        return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (SmokeError, subprocess.TimeoutExpired) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(2)
