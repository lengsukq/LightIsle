#!/usr/bin/env python3
"""Create the long-lived LightIsle Android signing identity and upload Actions secrets.

Run once: python3 scripts/setup-android-signing.py --upload
Secrets and the keystore are stored OUTSIDE the repository in
~/.config/lightisle, with owner-only permissions. Subsequent runs reuse the
existing identity; they never silently rotate a signing key.
"""

from __future__ import annotations

import argparse
import base64
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys

REPO = "lengsukq/LightIsle"
DIRECTORY = Path.home() / ".config" / "lightisle"
KEYSTORE = DIRECTORY / "android-release.jks"
PROPERTIES = DIRECTORY / "android-release.properties"
ALIAS = "lightisle"


def run(args: list[str], *, data: str | None = None, env=None) -> None:
    result = subprocess.run(args, input=data, text=True, capture_output=True, env=env, check=False)
    if result.returncode:
        # Avoid accidentally exposing keytool / gh command arguments or secrets.
        raise RuntimeError(f"{args[0]} failed (exit {result.returncode}); inspect local configuration")


def load_properties() -> dict[str, str]:
    properties: dict[str, str] = {}
    for line in PROPERTIES.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#"):
            key, sep, value = line.partition("=")
            if sep:
                properties[key] = value
    for name in ("storeFile", "storePassword", "keyPassword", "keyAlias"):
        if not properties.get(name):
            raise RuntimeError(f"Missing local signing property {name}")
    if Path(properties["storeFile"]).resolve() != KEYSTORE.resolve():
        raise RuntimeError("Local signing properties refer to a different keystore")
    return properties


def create_once() -> dict[str, str]:
    DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    DIRECTORY.chmod(0o700)
    if KEYSTORE.exists() != PROPERTIES.exists():
        raise RuntimeError("Only one signing file exists; refusing to overwrite or rotate the Android identity")
    if not KEYSTORE.exists():
        keytool = shutil.which("keytool")
        if not keytool:
            raise RuntimeError("keytool not found: install JDK 17 or newer")
        password = secrets.token_urlsafe(40)
        environment = dict(os.environ, LIGHTISLE_GENERATED_STORE_PASSWORD=password)
        run([
            keytool, "-genkeypair", "-v",
            "-keystore", str(KEYSTORE),
            "-storetype", "PKCS12",
            "-alias", ALIAS,
            "-keyalg", "RSA", "-keysize", "3072",
            "-validity", "10000",
            "-dname", "CN=LightIsle Android, O=LightIsle Open Source, C=CN",
            "-storepass:env", "LIGHTISLE_GENERATED_STORE_PASSWORD",
            "-keypass:env", "LIGHTISLE_GENERATED_STORE_PASSWORD",
            "-noprompt",
        ], env=environment)
        KEYSTORE.chmod(0o600)
        contents = (
            f"storeFile={KEYSTORE}\n"
            f"storePassword={password}\n"
            f"keyPassword={password}\n"
            f"keyAlias={ALIAS}\n"
        )
        descriptor = os.open(PROPERTIES, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as file:
            file.write(contents)
        print("Created a new Android release signing identity (private, not in Git).")
    else:
        print("Reusing the existing Android release signing identity; no key rotation.")
    KEYSTORE.chmod(0o600)
    PROPERTIES.chmod(0o600)
    return load_properties()


def upload(properties: dict[str, str]) -> None:
    if not shutil.which("gh"):
        raise RuntimeError("GitHub CLI not installed")
    values = {
        "LIGHTISLE_ANDROID_KEYSTORE_BASE64": base64.b64encode(KEYSTORE.read_bytes()).decode("ascii"),
        "LIGHTISLE_ANDROID_STORE_PASSWORD": properties["storePassword"],
        "LIGHTISLE_ANDROID_KEY_PASSWORD": properties["keyPassword"],
        "LIGHTISLE_ANDROID_KEY_ALIAS": properties["keyAlias"],
    }
    for name, value in values.items():
        # gh encrypts before sending; pass through STDIN to keep secrets out of
        # command-line arguments, terminal logs, and the committed repository.
        run(["gh", "secret", "set", name, "--repo", REPO, "--app", "actions"], data=value)
        print(f"Uploaded GitHub Actions secret: {name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upload", action="store_true", help=f"Upload four signing secrets to {REPO}")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        props = create_once()
        if args.upload:
            upload(props)
        print(f"Keystore: {KEYSTORE}")
        print(f"Local properties: {PROPERTIES}")
        print("Keep an offline backup: losing this key breaks updates to existing APK installations.")
        return 0
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Android signing setup failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
