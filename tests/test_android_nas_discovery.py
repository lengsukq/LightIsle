"""Compile the platform-independent discovery policy with local kotlinc or cached Kotlin jars."""
import os
from pathlib import Path
import subprocess
import tempfile

from android_kotlin_test_support import (
    ROOT,
    find_local_kotlinc,
    kotlin_compiler_jars,
    require_java,
    resolve_configured_kotlin_version,
    resolve_gradle_cache,
    resolve_kotlin_compiler_version,
)


def main() -> None:
    java = require_java()
    source = ROOT / "apps/flutter/android/app/src/main/kotlin/top/lengsu/lightisle/NasDiscoveryPolicy.kt"
    check = ROOT / "tests/NasDiscoveryCheck.kt"

    with tempfile.TemporaryDirectory(prefix="lightisle-android-nas-discovery-") as temporary:
        output = Path(temporary) / "classes"
        output.mkdir()
        kotlinc = find_local_kotlinc()
        if kotlinc is not None:
            compiler_command = [str(kotlinc)] if os.access(kotlinc, os.X_OK) else ["bash", str(kotlinc)]
            subprocess.run(
                compiler_command + ["-jvm-target", "1.8", "-d", str(output), str(source), str(check)],
                check=True,
            )
            kotlin_home = kotlinc.parent.parent
            runtime_jars = [kotlin_home / "lib/kotlin-stdlib.jar"]
        else:
            cache = resolve_gradle_cache()
            version = resolve_kotlin_compiler_version(cache, resolve_configured_kotlin_version())
            jars, stdlib, annotations = kotlin_compiler_jars(cache, version)
            subprocess.run(
                [
                    java, "-cp", os.pathsep.join(map(str, jars)), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                    "-no-stdlib", "-no-reflect", "-jvm-target", "1.8",
                    "-classpath", os.pathsep.join(map(str, [stdlib, annotations])), "-d", str(output),
                    str(source), str(check),
                ],
                check=True,
            )
            runtime_jars = [stdlib]

        subprocess.run(
            [java, "-cp", os.pathsep.join(map(str, [output, *runtime_jars])),
             "top.lengsu.lightisle.NasDiscoveryCheckKt"],
            check=True,
        )


if __name__ == "__main__":
    main()
