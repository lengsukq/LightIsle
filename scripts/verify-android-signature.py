#!/usr/bin/env python3
"""Fail if a purported LightIsle Release APK/AAB is signed by any other key.

Uses a read-only keystore inspection. No password or raw private key is printed.
Works locally with ~/.config/lightisle/android-release.properties and in CI
with LIGHTISLE_ANDROID_* environment values.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: python3 scripts/verify-android-signature.py <signed.apk|signed.aab>", file=sys.stderr)
        return 2
    bundle = Path(sys.argv[1]).resolve()
    if not bundle.is_file() or bundle.suffix not in {".apk", ".aab"}:
        print("Release APK or AAB does not exist", file=sys.stderr)
        return 1

    local = Path.home() / ".config/lightisle/android-release.properties"
    values: dict[str, str] = {}
    if local.is_file():
        for line in local.read_text(encoding="utf-8").splitlines():
            key, sep, value = line.partition("=")
            if sep:
                values[key] = value
    store_file = os.getenv("LIGHTISLE_ANDROID_KEYSTORE_PATH") or values.get("storeFile")
    store_password = os.getenv("LIGHTISLE_ANDROID_STORE_PASSWORD") or values.get("storePassword")
    alias = os.getenv("LIGHTISLE_ANDROID_KEY_ALIAS") or values.get("keyAlias")
    if not all((store_file, store_password, alias)):
        print("Missing Android release signing keystore configuration", file=sys.stderr)
        return 1

    if not shutil.which("keytool"):
        print("Requires JDK keytool", file=sys.stderr)
        return 1

    environment = dict(os.environ, LIGHTISLE_ANDROID_SIGNING_PASSWORD=store_password)
    expected = subprocess.run([
        "keytool", "-list", "-v", "-keystore", store_file, "-alias", alias,
        "-storepass:env", "LIGHTISLE_ANDROID_SIGNING_PASSWORD",
    ], capture_output=True, text=True, env=environment, check=False)
    if expected.returncode:
        print("Unable to verify Android release signing identity", file=sys.stderr)
        return 1
    key = re.search(r"SHA256:\s*([0-9a-fA-F:]{64,})", expected.stdout)
    if bundle.suffix == ".apk":
        sdk = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
                   or (Path.home() / "Library/Android/sdk"))
        signers = sorted((sdk / "build-tools").glob("*/apksigner"), key=lambda p: tuple(
            int(x) for x in p.parent.name.split(".") if x.isdigit()
        ))
        if not signers:
            print("Requires Android SDK build-tools apksigner", file=sys.stderr)
            return 1
        actual = subprocess.run([
            str(signers[-1]), "verify", "--print-certs", str(bundle),
        ], capture_output=True, text=True, check=False)
        signed = re.search(r"Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]+)", actual.stdout)
    else:
        # AAB is JAR-signed, unlike v2/v3 signed APKs. The public certificate
        # can be read without the private password.
        verified = subprocess.run(["jarsigner", "-verify", str(bundle)],
                                  capture_output=True, text=True, check=False)
        actual = subprocess.run(["keytool", "-printcert", "-jarfile", str(bundle)],
                                capture_output=True, text=True, check=False)
        if verified.returncode:
            print("Android App Bundle JAR signature is invalid", file=sys.stderr)
            return 1
        signed = re.search(r"SHA256:\s*([0-9a-fA-F:]{64,})", actual.stdout)
    if actual.returncode or not key or not signed or key.group(1).replace(":", "").lower() != signed.group(1).replace(":", "").lower():
        print("Android release signature does NOT match the configured keystore", file=sys.stderr)
        return 1
    print(f"PASS: {bundle.suffix.upper()[1:]} signature matches the long-lived LightIsle release keystore")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
