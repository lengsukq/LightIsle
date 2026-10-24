"""Exercise the macOS media worker with locally generated synthetic media."""
from __future__ import annotations

import json
import argparse
import hashlib
import os
import pathlib
import re
import stat
import struct
import signal
import subprocess
import sys
import tempfile
import time


ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURE_MAKER = ROOT / "tests/MediaWorkerFixtureMaker.swift"
SPARSE_VIDEO_BYTES = 1 << 30
JPEG_SOF_MARKERS = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}


def run_fixture_maker(executable: pathlib.Path, kind: str, output: pathlib.Path) -> None:
    subprocess.run([str(executable), kind, str(output)], check=True, timeout=30)


def jpeg_dimensions(path: pathlib.Path) -> tuple[int, int]:
    data = path.read_bytes()
    assert data.startswith(b"\xff\xd8"), "thumbnail must start with JPEG SOI"
    offset = 2
    while offset < len(data):
        while offset < len(data) and data[offset] == 0xFF:
            offset += 1
        assert offset < len(data), "truncated JPEG marker"
        marker = data[offset]
        offset += 1
        if marker in {0xD8, 0xD9} or 0xD0 <= marker <= 0xD7 or marker == 0x01:
            continue
        assert offset + 2 <= len(data), "truncated JPEG segment length"
        segment_length = struct.unpack_from(">H", data, offset)[0]
        assert segment_length >= 2 and offset + segment_length <= len(data), "invalid JPEG segment length"
        if marker in JPEG_SOF_MARKERS:
            assert segment_length >= 7
            height, width = struct.unpack_from(">HH", data, offset + 3)
            return width, height
        offset += segment_length
    raise AssertionError("JPEG has no frame-size marker")


# Hosted macOS runners are virtual machines without Apple's hardware scaler;
# the frameworks the worker loads may print benign IOKit probing lines
# directly to fd 2 (observed: "IOServiceMatchingfailed for:
# AppleM2ScalerParavirtDriver"). Only unexpected diagnostics may fail a run.
BENIGN_STDERR_MARKERS = ("IOServiceMatchingfailed",)


def assert_clean_stderr(stderr: str) -> None:
    unexpected = [
        line
        for line in stderr.splitlines()
        if line.strip() and not any(marker in line for marker in BENIGN_STDERR_MARKERS)
    ]
    assert not unexpected, stderr


def run_worker(worker: pathlib.Path, source: pathlib.Path, *arguments: str):
    # The input path is used only by this shell to open the inherited read-only
    # descriptor. The worker receives fd 3 and a basename, never the source path.
    command = 'exec 3< "$1"; shift; exec "$@"'
    result = subprocess.run(
        ["/bin/bash", "-c", command, "lightisle-media-worker-test", str(source), str(worker), *arguments],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
    )
    assert_clean_stderr(result.stderr)
    lines = result.stdout.splitlines()
    assert len(lines) == 1, f"expected one JSON line, got {result.stdout!r}"
    assert len(lines[0].encode("utf-8")) <= 32 * 1024
    return result, json.loads(lines[0])


def run_orphan_before_exec(worker: pathlib.Path, source: pathlib.Path, directory: pathlib.Path) -> None:
    """Exec the worker only after its Python parent exits and it is continued."""
    stdout_path = directory / "orphan-worker.stdout"
    stderr_path = directory / "orphan-worker.stderr"
    child_pid_path = directory / "orphan-worker.pid"
    orphan_marker_path = directory / "orphan-worker.ppid"
    source_fd = os.open(source, os.O_RDONLY)
    stdout_fd = os.open(stdout_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    stderr_fd = os.open(stderr_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)

    parent_pid = os.fork()
    if parent_pid == 0:
        candidate_pid = os.fork()
        if candidate_pid == 0:
            try:
                if source_fd != 3:
                    os.dup2(source_fd, 3)
                os.set_inheritable(3, True)
                os.dup2(stdout_fd, 1)
                os.dup2(stderr_fd, 2)
                os.kill(os.getpid(), signal.SIGSTOP)
                actual_parent = os.getppid()
                if actual_parent != 1:
                    os._exit(126)
                orphan_marker_path.write_text(str(actual_parent), encoding="ascii")
                os.execv(
                    str(worker),
                    [str(worker), "probe", "--input-fd", "3", "--name", source.name],
                )
            except BaseException as error:
                try:
                    os.write(2, str(error).encode("utf-8", errors="replace"))
                finally:
                    os._exit(127)
        _, status = os.waitpid(candidate_pid, os.WUNTRACED)
        if not os.WIFSTOPPED(status):
            os._exit(125)
        child_pid_path.write_text(str(candidate_pid), encoding="ascii")
        os._exit(0)

    _, parent_status = os.waitpid(parent_pid, 0)
    if not os.WIFEXITED(parent_status) or os.WEXITSTATUS(parent_status) != 0:
        raise AssertionError(f"orphan setup parent failed: wait status {parent_status}")
    candidate_pid = int(child_pid_path.read_text(encoding="ascii"))
    os.kill(candidate_pid, signal.SIGCONT)
    deadline = time.monotonic() + 5
    state = "unknown"
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["/bin/ps", "-o", "stat=", "-p", str(candidate_pid)],
            capture_output=True,
            text=True,
            check=False,
            timeout=2,
        )
        state = result.stdout.strip()
        if not state or state.startswith("Z"):
            break
        time.sleep(0.01)
    else:
        os.kill(candidate_pid, signal.SIGKILL)
        raise AssertionError(f"orphaned media worker did not exit promptly: process state {state}")

    assert orphan_marker_path.read_text(encoding="ascii") == "1", "worker did not become orphaned before exec"
    assert stdout_path.read_bytes() == b"", "orphaned worker wrote a response instead of exiting 125"
    assert_clean_stderr(stderr_path.read_text(encoding="utf-8", errors="replace"))
    os.close(source_fd)
    os.close(stdout_fd)
    os.close(stderr_fd)


def make_sparse_video_with_tail_moov(source: pathlib.Path, destination: pathlib.Path) -> None:
    data = source.read_bytes()
    boxes = []
    offset = 0
    while offset + 8 <= len(data):
        size32 = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4 : offset + 8]
        if size32 == 1:
            assert offset + 16 <= len(data)
            box_size = struct.unpack_from(">Q", data, offset + 8)[0]
            header_size = 16
        elif size32 == 0:
            box_size = len(data) - offset
            header_size = 8
        else:
            box_size = size32
            header_size = 8
        assert box_size >= header_size and offset + box_size <= len(data)
        boxes.append((kind, offset, box_size))
        offset += box_size
    assert offset == len(data), "synthetic MP4 has invalid top-level boxes"
    mdat = next((box for box in boxes if box[0] == b"mdat"), None)
    moov = next((box for box in boxes if box[0] == b"moov"), None)
    assert mdat is not None and moov is not None, "fixture must include mdat and moov boxes"
    moov_offset = moov[1]
    assert mdat[1] + mdat[2] <= moov_offset, "fixture must place moov after media data"

    free_size = SPARSE_VIDEO_BYTES - len(data)
    assert free_size >= 8 and free_size <= 0xFFFFFFFF
    with destination.open("wb") as output:
        output.write(data[:moov_offset])
        output.write(struct.pack(">I4s", free_size, b"free"))
        output.seek(free_size - 8, os.SEEK_CUR)
        output.write(data[moov_offset:])
    stats = destination.stat()
    assert stats.st_size == SPARSE_VIDEO_BYTES
    assert stats.st_blocks * 512 < 16 * 1024 * 1024, "large MP4 fixture must remain sparse"


def is_virtual_mac() -> bool:
    """Hosted macOS runners (VirtualMac2,1…) have no VideoToolbox hardware
    decode, so poster generation legitimately software-decodes with a much
    larger peak RSS. The budget's purpose — catching a full 1 GiB slurp —
    still holds with a relaxed ceiling there."""
    try:
        model = subprocess.run(
            ["/usr/bin/sysctl", "-n", "hw.model"],
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    return model.upper().startswith("VIRTUALMAC")


def sparse_media_rss_budget() -> int:
    return 768 * 1024 * 1024 if is_virtual_mac() else 256 * 1024 * 1024


def run_worker_timed(worker: pathlib.Path, source: pathlib.Path, time_report: pathlib.Path, *arguments: str):
    command = 'exec 3< "$1"; shift; exec "$@"'
    result = subprocess.run(
        [
            "/usr/bin/time",
            "-l",
            "-o",
            str(time_report),
            "/bin/bash",
            "-c",
            command,
            "lightisle-media-worker-time-test",
            str(source),
            str(worker),
            *arguments,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=90,
    )
    assert_clean_stderr(result.stderr)
    lines = result.stdout.splitlines()
    assert len(lines) == 1, f"expected one JSON line, got {result.stdout!r}"
    assert len(lines[0].encode("utf-8")) <= 32 * 1024
    report = time_report.read_text(encoding="utf-8")
    match = re.search(r"^\s*(\d+)\s+maximum resident set size\s*$", report, re.MULTILINE)
    assert match, f"could not parse macOS time report: {report}"
    return result, json.loads(lines[0]), int(match.group(1)), report


def main() -> None:
    if sys.platform != "darwin":
        raise SystemExit("media worker fixtures require macOS frameworks")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("worker", nargs="?", default=str(ROOT / ".build/debug/lightisle-media-worker"))
    parser.add_argument(
        "--fixtures-dir",
        type=pathlib.Path,
        help="write synthetic HEIC and MP4 inputs here for a separate Core/Web smoke test",
    )
    parser.add_argument(
        "--resource-report-dir",
        type=pathlib.Path,
        help="preserve /usr/bin/time -l reports for the 1 GiB sparse-video checks",
    )
    arguments = parser.parse_args()
    worker = pathlib.Path(arguments.worker).resolve()
    assert worker.is_file(), f"worker executable not found: {worker}"

    with tempfile.TemporaryDirectory(prefix="lightisle-media-worker-test-") as temporary:
        directory = pathlib.Path(temporary)
        fixture_directory = arguments.fixtures_dir.resolve() if arguments.fixtures_dir else directory
        fixture_directory.mkdir(parents=True, exist_ok=True)
        report_directory = arguments.resource_report_dir.resolve() if arguments.resource_report_dir else directory
        report_directory.mkdir(parents=True, exist_ok=True)
        photo = fixture_directory / "synthetic.heic"
        movie = fixture_directory / "synthetic.mp4"
        if photo.exists() or movie.exists():
            raise SystemExit("refusing to overwrite existing synthetic.heic or synthetic.mp4")
        fixture_maker = directory / "fixture-maker"
        subprocess.run(
            [
                "swiftc",
                "-swift-version",
                "5",
                "-parse-as-library",
                "-suppress-warnings",
                str(FIXTURE_MAKER),
                "-o",
                str(fixture_maker),
            ],
            check=True,
            timeout=60,
        )

        run_fixture_maker(fixture_maker, "heic", photo)
        photo_digest = hashlib.sha256(photo.read_bytes()).hexdigest()
        result, response = run_worker(worker, photo, "probe", "--input-fd", "3", "--name", photo.name)
        assert result.returncode == 0, result.stdout
        assert response["version"] == 1 and response["status"] == "ok"
        assert response["kind"] == "photo" and response["container"] == "HEIC"
        assert (response["width"], response["height"]) == (80, 48)
        assert response["orientation"] == 6
        assert response["capturedAt"] == "2020-01-01T19:04:05Z"
        run_orphan_before_exec(worker, photo, directory)
        result, renamed_photo = run_worker(
            worker,
            photo,
            "probe",
            "--input-fd",
            "3",
            "--name",
            "renamed-heic.jpg",
        )
        assert result.returncode == 0 and renamed_photo["status"] == "ok"
        assert renamed_photo["container"] == "HEIC" and renamed_photo["mime"] == "image/heic"

        thumbnail = directory / "orientation-thumbnail.jpg"
        result, thumbnail_response = run_worker(
            worker,
            photo,
            "thumbnail",
            "--input-fd",
            "3",
            "--name",
            photo.name,
            "--output",
            str(thumbnail),
        )
        assert result.returncode == 0, result.stdout
        assert thumbnail_response["status"] == "ok" and thumbnail_response["orientation"] == 6
        thumbnail_width, thumbnail_height = jpeg_dimensions(thumbnail)
        assert thumbnail_width < thumbnail_height
        assert max(thumbnail_width, thumbnail_height) <= 512
        assert abs(thumbnail_width / thumbnail_height - 48 / 80) < 0.01
        assert stat.S_IMODE(thumbnail.stat().st_mode) == 0o600
        assert thumbnail.read_bytes().endswith(b"\xff\xd9")
        assert hashlib.sha256(photo.read_bytes()).hexdigest() == photo_digest, "thumbnail generation changed its source"

        occupied_output = directory / "occupied-thumbnail.jpg"
        occupied_output.write_bytes(b"preserve-existing-output")
        result, collision_response = run_worker(
            worker,
            photo,
            "thumbnail",
            "--input-fd",
            "3",
            "--name",
            photo.name,
            "--output",
            str(occupied_output),
        )
        assert result.returncode != 0 and collision_response["status"] == "error"
        assert occupied_output.read_bytes() == b"preserve-existing-output", "exclusive output replaced an existing file"

        run_fixture_maker(fixture_maker, "mp4", movie)
        result, response = run_worker(worker, movie, "probe", "--input-fd", "3", "--name", movie.name)
        assert result.returncode == 0, result.stdout
        assert response["version"] == 1 and response["status"] == "ok"
        assert response["kind"] == "video" and response["container"] == "MPEG-4"
        assert response["mime"] == "video/mp4"
        assert (response["width"], response["height"]) == (96, 64)
        assert 1.8 <= response["durationSeconds"] <= 2.2
        assert response["videoCodec"]
        result, renamed_movie = run_worker(
            worker,
            movie,
            "probe",
            "--input-fd",
            "3",
            "--name",
            "renamed-mp4.mov",
        )
        assert result.returncode == 0, result.stdout
        assert renamed_movie["container"] == "MPEG-4" and renamed_movie["mime"] == "video/mp4"

        sparse_movie = directory / "sparse-1gib.mp4"
        make_sparse_video_with_tail_moov(movie, sparse_movie)
        sparse_result, sparse_probe, probe_rss, _ = run_worker_timed(
            worker,
            sparse_movie,
            report_directory / "probe-time.txt",
            "probe",
            "--input-fd",
            "3",
            "--name",
            sparse_movie.name,
        )
        assert sparse_result.returncode == 0, sparse_result.stdout
        assert sparse_probe["status"] == "ok" and sparse_probe["container"] == "MPEG-4"
        assert sparse_probe["durationSeconds"] >= 1.8 and sparse_probe["videoCodec"]
        assert probe_rss < sparse_media_rss_budget(), f"1 GiB sparse MP4 probe RSS too high: {probe_rss}"

        sparse_poster = directory / "sparse-poster.jpg"
        poster_result, sparse_poster_response, poster_rss, _ = run_worker_timed(
            worker,
            sparse_movie,
            report_directory / "poster-time.txt",
            "poster",
            "--input-fd",
            "3",
            "--name",
            sparse_movie.name,
            "--output",
            str(sparse_poster),
        )
        assert poster_result.returncode == 0, poster_result.stdout
        assert sparse_poster_response["status"] == "ok"
        assert sparse_poster.read_bytes().startswith(b"\xff\xd8")
        assert poster_rss < sparse_media_rss_budget(), f"1 GiB sparse MP4 poster RSS too high: {poster_rss}"

        poster = directory / "poster.jpg"
        result, response = run_worker(
            worker,
            movie,
            "poster",
            "--input-fd",
            "3",
            "--name",
            movie.name,
            "--output",
            str(poster),
        )
        assert result.returncode == 0, result.stdout
        assert response["version"] == 1 and response["status"] == "ok"
        poster_bytes = poster.read_bytes()
        assert poster_bytes.startswith(b"\xff\xd8") and poster_bytes.endswith(b"\xff\xd9")
        assert stat.S_IMODE(poster.stat().st_mode) == 0o600

        unsupported = directory / "notes.txt"
        unsupported.write_text("not media", encoding="utf-8")
        result, response = run_worker(worker, unsupported, "probe", "--input-fd", "3", "--name", unsupported.name)
        assert result.returncode == 0 and response["status"] == "unsupported"

        corrupt = directory / "corrupt.mp4"
        corrupt.write_bytes(b"not an mp4 container")
        result, response = run_worker(worker, corrupt, "probe", "--input-fd", "3", "--name", corrupt.name)
        assert result.returncode != 0 and response["status"] == "error"
        assert str(corrupt) not in response.get("error", "")

        unknown = directory / "unknown-brand.mov"
        unknown.write_bytes(struct.pack(">I4s4sI", 16, b"ftyp", b"abcd", 0))
        result, response = run_worker(worker, unknown, "probe", "--input-fd", "3", "--name", unknown.name)
        assert result.returncode == 0 and response["status"] == "unsupported"
        assert response["container"] == "unknown" and "mime" not in response

    print(
        "PASS: synthetic HEIC orientation thumbnail, MP4 probe/poster, 1 GiB sparse MP4 probe/poster "
        f"(peak RSS {probe_rss / (1024 * 1024):.1f}/{poster_rss / (1024 * 1024):.1f} MiB), "
        "unsupported and corrupt media"
    )
    if arguments.fixtures_dir:
        print(f"Synthetic fixtures: {photo} {movie}")
    if arguments.resource_report_dir:
        print(f"Resource reports: {report_directory / 'probe-time.txt'} {report_directory / 'poster-time.txt'}")


if __name__ == "__main__":
    main()
