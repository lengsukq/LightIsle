"""Verify that the packaged LightIsle Mac icon and Web identity are unified."""
from __future__ import annotations

import json
import pathlib
import plistlib
import struct

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "dist/LightIsle.app"
RES = APP / "Contents/Resources"
WEB = RES / "web"

with (APP / "Contents/Info.plist").open("rb") as handle:
    plist = plistlib.load(handle)
assert plist["CFBundleIconFile"] == "LightIsle.icns"
icon = RES / plist["CFBundleIconFile"]
assert icon.is_file() and icon.read_bytes()[:4] == b"icns"
assert icon.stat().st_size > 5000, "macOS icon unusually small"

def png_size(location: pathlib.Path) -> tuple[int, int]:
    data = location.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", location
    return struct.unpack(">II", data[16:24])

assert png_size(RES / "LightIsleLogo.png") == (512,512)
for name, size in [
    ("favicon.png", 32),
    ("apple-touch-icon.png", 180),
    ("brand-icon.png", 192),
    ("brand-icon-512.png", 512)
]:
    assert png_size(WEB / name) == (size, size), name

source_svg = (ROOT / "assets/brand/lightisle-logo.svg").read_bytes()
assert source_svg == (WEB / "brand-icon.svg").read_bytes()
assert b"LightIsle" in source_svg and b"polygon" in source_svg
page = (WEB / "index.html").read_text(encoding="utf-8")
assert "brand-icon.svg" in page and "apple-touch-icon.png" in page
manifest = json.loads((WEB / "manifest.webmanifest").read_text())
assert len(manifest["icons"]) >= 2
assert (ROOT / "apps/macos/Sources/LightIsle/BrandMark.swift").exists()
print("PASS: macOS Finder/Dock .icns + SwiftUI PNG + web favicon/PWA/SVG brand consistency")

