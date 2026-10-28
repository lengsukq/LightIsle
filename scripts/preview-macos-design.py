#!/usr/bin/env python3
"""Assemble an isolated debug UI host from an already-built local executable.

No Core, downloads, real NAS directories or macOS preference changes. Launch
its printed .app path to inspect actual SwiftUI views with labelled fixtures.
"""
import argparse
import hashlib
import pathlib
import plistlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--name", default="Preview")
p.add_argument("--scenario", choices=["ready", "offline", "empty", "setup", "loading", "failure"], default="ready")
p.add_argument("--appearance", choices=["light", "dark"], default="light")
p.add_argument("--width", type=int, default=1120)
p.add_argument("--height", type=int, default=730)
p.add_argument("--page", default="overview")
p.add_argument("--storage")
p.add_argument("--connection")
p.add_argument("--settings")
p.add_argument("--docker")
p.add_argument("--accessible", action="store_true")
a = p.parse_args()
if not 850 <= a.width <= 2000 or not 570 <= a.height <= 1400:
    p.error("Use a width of 850–2000 and a height of 570–1400.")
if not a.name.replace("-", "").replace(" ", "").isalnum():
    p.error("Name must contain letters, digits, spaces or hyphens.")
binary = ROOT / ".build/debug/LightIsle"
if not binary.is_file():
    p.error("Build the debug executable locally first: swift build -c debug --disable-automatic-resolution")
name = "LightIsle Design " + a.name
bundle = ROOT / ".build" / (name + ".app")
contents = bundle / "Contents"
(contents / "MacOS").mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(exist_ok=True)
shutil.copy2(binary, contents / "MacOS/LightIsle")
shutil.copy2(ROOT / "apps/macos/Resources/LightIsleLogo.png", contents / "Resources/LightIsleLogo.png")
info = dict(CFBundleExecutable="LightIsle", CFBundleIdentifier="dev.lightisle.design-" + hashlib.sha256(a.name.encode()).hexdigest()[:12],
            CFBundleName=name, CFBundleDisplayName=name, CFBundlePackageType="APPL", CFBundleVersion="1",
            NSHighResolutionCapable=True, LSMinimumSystemVersion="14.0", LightIsleDesignPreview=True,
            LightIsleDesignScenario=a.scenario, LightIsleDesignAppearance=a.appearance,
            LightIsleDesignWidth=float(a.width), LightIsleDesignHeight=float(a.height), LightIsleDesignPage=a.page)
for key, value in [("Storage", a.storage), ("Connection", a.connection), ("Settings", a.settings), ("Docker", a.docker)]:
    if value:
        info["LightIsleDesign" + key] = value
if a.accessible:
    info.update(LightIsleDesignReducedMotion="true", LightIsleDesignOpaque="true", LightIsleDesignContrast="high")
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
print(bundle)
