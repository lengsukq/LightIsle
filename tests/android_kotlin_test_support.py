"""Shared offline Gradle/Kotlin cache helpers for standalone Android policy checks."""
from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SETTINGS_GRADLE = ROOT / "apps/flutter/android/settings.gradle.kts"


def _gradle_cache_candidates() -> list[Path]:
    candidates: list[Path] = []
    explicit_cache = os.environ.get("LIGHTISLE_GRADLE_CACHE")
    if explicit_cache:
        explicit_path = Path(explicit_cache).expanduser()
        candidates.append(explicit_path)
        candidates.append(explicit_path / "caches/modules-2/files-2.1")
    for env_name in ("GRADLE_USER_HOME", "LIGHTISLE_GRADLE_USER_HOME"):
        value = os.environ.get(env_name)
        if value:
            candidates.append(Path(value).expanduser() / "caches/modules-2/files-2.1")
    candidates.append(Path.home() / ".gradle/caches/modules-2/files-2.1")
    return candidates


def resolve_gradle_cache() -> Path:
    candidates = _gradle_cache_candidates()
    for cache in candidates:
        if cache.is_dir():
            return cache
    checked = ", ".join(str(path) for path in candidates)
    raise SystemExit(
        "Offline Gradle module cache not found (no network download attempted). "
        f"Checked: {checked}. Set GRADLE_USER_HOME or LIGHTISLE_GRADLE_CACHE to an existing cache directory."
    )


def resolve_configured_kotlin_version() -> str:
    match = re.search(
        r'id\("org.jetbrains.kotlin.android"\) version "([^"]+)"',
        SETTINGS_GRADLE.read_text(encoding="utf-8"),
    )
    if match is None:
        raise SystemExit(f"Could not identify Kotlin plugin version in {SETTINGS_GRADLE}")
    return match.group(1)


def resolve_kotlin_compiler_version(cache: Path, preferred: str) -> str:
    embeddable = cache / "org.jetbrains.kotlin" / "kotlin-compiler-embeddable"
    if (embeddable / preferred).is_dir():
        return preferred
    if embeddable.is_dir():
        versions = sorted(p.name for p in embeddable.iterdir() if p.is_dir())
        if versions:
            return versions[-1]
    return preferred


def cached_artifact(cache: Path, group: str, artifact: str, version: str, suffix: str) -> Path:
    files = sorted((cache / group / artifact / version).glob(f"*/{artifact}-{version}{suffix}"))
    if not files:
        raise SystemExit(
            f"Required project dependency absent from local cache ({cache}): "
            f"{group}:{artifact}:{version}; no download attempted"
        )
    return files[0]


def kotlin_compiler_jars(cache: Path, version: str) -> tuple[list[Path], Path, Path]:
    compiler = cached_artifact(cache, "org.jetbrains.kotlin", "kotlin-compiler-embeddable", version, ".jar")
    jars = [compiler]
    pom_files = sorted(
        (cache / "org.jetbrains.kotlin" / "kotlin-compiler-embeddable" / version).glob(
            f"*/kotlin-compiler-embeddable-{version}.pom"
        )
    )
    if pom_files:
        namespace = {"m": "http://maven.apache.org/POM/4.0.0"}
        for dependency in ET.parse(pom_files[0]).getroot().findall("m:dependencies/m:dependency", namespace):
            group, name, number = (
                dependency.find("m:" + key, namespace).text
                for key in ("groupId", "artifactId", "version")
            )
            jars.append(cached_artifact(cache, group, name, number, ".jar"))
    else:
        # Some offline Gradle caches contain compiler JARs without Maven POMs.
        jars.extend([
            cached_artifact(cache, "org.jetbrains.kotlin", "kotlin-stdlib", version, ".jar"),
            cached_artifact(cache, "org.jetbrains.kotlin", "kotlin-script-runtime", version, ".jar"),
            cached_artifact(cache, "org.jetbrains.kotlin", "kotlin-reflect", "2.3.0", ".jar"),
            cached_artifact(cache, "org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm", "1.8.1", ".jar"),
            cached_artifact(cache, "org.jetbrains.intellij.deps", "trove4j", "1.0.20181211", ".jar"),
        ])
    annotations = cached_artifact(cache, "org.jetbrains", "annotations", "13.0", ".jar")
    jars.append(annotations)
    stdlib = cached_artifact(cache, "org.jetbrains.kotlin", "kotlin-stdlib", version, ".jar")
    return jars, stdlib, annotations


def find_local_kotlinc() -> Path | None:
    candidates: list[Path] = []
    which_kotlinc = shutil.which("kotlinc")
    if which_kotlinc:
        candidates.append(Path(which_kotlinc))
    for kotlin_home in (
        Path("/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc"),
        Path("/Applications/IntelliJ IDEA.app/Contents/plugins/Kotlin/kotlinc"),
    ):
        candidates.append(kotlin_home / "bin/kotlinc")
    return next((path for path in candidates if path.is_file()), None)


def require_java() -> str:
    java = shutil.which("java")
    if java is None:
        raise SystemExit("java runtime not found in PATH; install JDK 17+ to execute Kotlin checks.")
    return java
