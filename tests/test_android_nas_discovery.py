"""Compile the platform-independent discovery policy with only cached project Kotlin jars."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle")) / "caches/modules-2/files-2.1"
version_match = re.search(
    r'id\("org.jetbrains.kotlin.android"\) version "([^"]+)"',
    (ROOT / "apps/flutter/android/settings.gradle.kts").read_text(),
)
if version_match is None:
    raise SystemExit("Could not identify the Kotlin version already configured by this project")
version = version_match.group(1)


def cached(group, artifact, number, suffix):
    files = sorted((CACHE / group / artifact / number).glob("*/" + artifact + "-" + number + suffix))
    if not files:
        raise SystemExit(f"Required project dependency absent from local cache: {group}:{artifact}:{number}; no download attempted")
    return files[0]


source = ROOT / "apps/flutter/android/app/src/main/kotlin/top/lengsu/lightisle/NasDiscoveryPolicy.kt"
check = ROOT / "tests/NasDiscoveryCheck.kt"


def local_kotlinc():
    candidates = []
    if shutil.which("kotlinc"):
        candidates.append(Path(shutil.which("kotlinc")))
    for kotlin_home in (
        Path("/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc"),
        Path("/Applications/IntelliJ IDEA.app/Contents/plugins/Kotlin/kotlinc"),
    ):
        candidates.append(kotlin_home / "bin/kotlinc")
    return next((path for path in candidates if path.is_file()), None)


with tempfile.TemporaryDirectory(prefix="lightisle-android-nas-discovery-") as temporary:
    output = Path(temporary) / "classes"
    output.mkdir()
    kotlinc = local_kotlinc()
    if kotlinc is not None:
        if os.access(kotlinc, os.X_OK):
            compiler_command = [str(kotlinc)]
        else:
            compiler_command = ["bash", str(kotlinc)]
        subprocess.run(
            compiler_command + ["-jvm-target", "1.8", "-d", str(output), str(source), str(check)],
            check=True,
        )
        kotlin_home = kotlinc.parent.parent
        runtime_jars = [kotlin_home / "lib/kotlin-stdlib.jar"]
    else:
        compiler = cached("org.jetbrains.kotlin", "kotlin-compiler-embeddable", version, ".jar")
        pom = cached("org.jetbrains.kotlin", "kotlin-compiler-embeddable", version, ".pom")
        namespace = {"m": "http://maven.apache.org/POM/4.0.0"}
        jars = [compiler]
        for dependency in ET.parse(pom).getroot().findall("m:dependencies/m:dependency", namespace):
            group, artifact, number = (
                dependency.find("m:" + key, namespace).text
                for key in ("groupId", "artifactId", "version")
            )
            jars.append(cached(group, artifact, number, ".jar"))
        annotations = cached("org.jetbrains", "annotations", "13.0", ".jar")
        jars.append(annotations)
        stdlib = cached("org.jetbrains.kotlin", "kotlin-stdlib", version, ".jar")
        classpath = os.pathsep.join(map(str, jars))
        subprocess.run(
            [
                "java", "-cp", classpath, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                "-no-stdlib", "-no-reflect", "-jvm-target", "1.8",
                "-classpath", os.pathsep.join(map(str, [stdlib, annotations])), "-d", str(output),
                str(source), str(check),
            ],
            check=True,
        )
        runtime_jars = [stdlib]

    subprocess.run(
        ["java", "-cp", os.pathsep.join(map(str, [output, *runtime_jars])),
         "top.lengsu.lightisle.NasDiscoveryCheckKt"],
        check=True,
    )
