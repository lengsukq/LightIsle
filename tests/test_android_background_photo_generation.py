"""Compile with the project's cached Kotlin compiler; never install or download tools."""
from pathlib import Path
import os
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle")) / "caches/modules-2/files-2.1"
version = re.search(
    r'id\("org.jetbrains.kotlin.android"\) version "([^"]+)"',
    (ROOT / "apps/flutter/android/settings.gradle.kts").read_text(),
).group(1)


def cached(group, artifact, version, suffix):
    files = sorted((CACHE / group / artifact / version).glob("*/" + artifact + "-" + version + suffix))
    if not files:
        raise SystemExit(f"Required project dependency absent from local cache: {group}:{artifact}:{version}; no download attempted")
    return files[0]


compiler = cached("org.jetbrains.kotlin", "kotlin-compiler-embeddable", version, ".jar")
jars = [compiler]
pom_files = sorted(
    (CACHE / "org.jetbrains.kotlin" / "kotlin-compiler-embeddable" / version)
    .glob("*/kotlin-compiler-embeddable-" + version + ".pom")
)
if pom_files:
    ns = {"m": "http://maven.apache.org/POM/4.0.0"}
    for dependency in ET.parse(pom_files[0]).getroot().findall("m:dependencies/m:dependency", ns):
        group, name, number = (
            dependency.find("m:" + key, ns).text
            for key in ("groupId", "artifactId", "version")
        )
        jars.append(cached(group, name, number, ".jar"))
else:
    # Some offline Gradle caches contain the compiler JARs without Maven POMs.
    # Use only already-cached compiler runtime JARs; never resolve or download.
    jars.extend([
        cached("org.jetbrains.kotlin", "kotlin-stdlib", version, ".jar"),
        cached("org.jetbrains.kotlin", "kotlin-script-runtime", version, ".jar"),
        cached("org.jetbrains.kotlin", "kotlin-reflect", "2.3.0", ".jar"),
        cached("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm", "1.8.1", ".jar"),
        cached("org.jetbrains.intellij.deps", "trove4j", "1.0.20181211", ".jar"),
    ])
annotations = cached("org.jetbrains", "annotations", "13.0", ".jar")
jars.append(annotations)
stdlib = cached("org.jetbrains.kotlin", "kotlin-stdlib", version, ".jar")
classpath = os.pathsep.join(map(str, jars))
with tempfile.TemporaryDirectory(prefix="lightisle-android-generation-") as temporary:
    output = Path(temporary) / "classes"
    subprocess.run(
        [
            "java", "-cp", classpath, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
            "-no-stdlib", "-no-reflect", "-jvm-target", "1.8",
            "-classpath", os.pathsep.join(map(str, [stdlib, annotations])), "-d", str(output),
            str(ROOT / "apps/flutter/android/app/src/main/kotlin/top/lengsu/lightisle/BackgroundPhotoGeneration.kt"),
            str(ROOT / "apps/flutter/android/app/src/main/kotlin/top/lengsu/lightisle/BackgroundPhotoWorkStatePolicy.kt"),
            str(ROOT / "tests/BackgroundPhotoGenerationCheck.kt"),
            str(ROOT / "apps/flutter/android/app/src/test/kotlin/top/lengsu/lightisle/BackgroundPhotoWorkStatePolicyTest.kt"),
        ],
        check=True,
    )
    subprocess.run(
        ["java", "-cp", os.pathsep.join(map(str, [output, stdlib])),
         "top.lengsu.lightisle.BackgroundPhotoGenerationCheckKt"],
        check=True,
    )
    subprocess.run(
        ["java", "-cp", os.pathsep.join(map(str, [output, stdlib])),
         "top.lengsu.lightisle.BackgroundPhotoWorkStatePolicyTestKt"],
        check=True,
    )
