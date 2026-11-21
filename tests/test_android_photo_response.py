"""Compile with this project's cached Kotlin compiler; never install or download tools."""
import os
import subprocess
import tempfile

from android_kotlin_test_support import (
    ROOT,
    kotlin_compiler_jars,
    require_java,
    resolve_configured_kotlin_version,
    resolve_gradle_cache,
    resolve_kotlin_compiler_version,
)


def main() -> None:
    java = require_java()
    cache = resolve_gradle_cache()
    version = resolve_kotlin_compiler_version(cache, resolve_configured_kotlin_version())
    jars, stdlib, annotations = kotlin_compiler_jars(cache, version)
    classpath = os.pathsep.join(map(str, jars))

    with tempfile.TemporaryDirectory(prefix="lightisle-android-response-") as temporary:
        output = f"{temporary}/classes"
        subprocess.run(
            [
                java, "-cp", classpath, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                "-no-stdlib", "-no-reflect", "-jvm-target", "1.8",
                "-classpath", os.pathsep.join(map(str, [stdlib, annotations])), "-d", output,
                str(ROOT / "apps/flutter/android/app/src/main/kotlin/top/lengsu/lightisle/BoundedPhotoResponse.kt"),
                str(ROOT / "tests/BoundedPhotoResponseCheck.kt"),
            ],
            check=True,
        )
        subprocess.run(
            [java, "-cp", os.pathsep.join(map(str, [output, str(stdlib)])),
             "top.lengsu.lightisle.BoundedPhotoResponseCheckKt"],
            check=True,
        )


if __name__ == "__main__":
    main()
