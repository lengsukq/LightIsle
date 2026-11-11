#!/usr/bin/env python3
"""Check local Markdown links and documentation-index coverage (no dependencies)."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
SOURCES = [
    ROOT / "README.md",
    ROOT / "README_EN.md",
    ROOT / "AGENTS.md",
    ROOT / "apps/flutter/README.md",
    ROOT / "assets/brand/README.md",
    *sorted(DOCS.rglob("*.md")),
]
LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
HEADING = re.compile(r"^#{1,6} +(.+)$")


def heading_ids(doc: Path) -> set[str]:
    """Approximate GitHub heading IDs, including repeated heading suffixes."""
    used: dict[str, int] = {}
    result: set[str] = set()
    for line in doc.read_text(encoding="utf-8").splitlines():
        match = HEADING.match(line)
        if not match:
            continue
        title = re.sub(r"<[^>]*>", "", match.group(1)).lower()
        title = re.sub(r"[^\w\s-]", "", title, flags=re.UNICODE)
        base = re.sub(r"\s", "-", title.strip())
        count = used.get(base, 0)
        used[base] = count + 1
        result.add(base if count == 0 else f"{base}-{count}")
    return result


def main() -> int:
    errors: list[str] = []
    checked = 0
    headings: dict[Path, set[str]] = {}
    for source in SOURCES:
        if not source.is_file():
            errors.append(f"Missing documentation source: {source}")
            continue
        for link in LINK.findall(source.read_text(encoding="utf-8")):
            if link.startswith(("https:", "http:", "mailto:", "data:", "app:")):
                continue
            filename, _, fragment = link.partition("#")
            target = (source.parent / filename).resolve() if filename else source.resolve()
            checked += 1
            if not target.exists():
                errors.append(f"{source.relative_to(ROOT)}: missing {link}")
            elif fragment and target.suffix.lower() == ".md":
                if target not in headings:
                    headings[target] = heading_ids(target)
                if fragment.lower() not in headings[target]:
                    errors.append(f"{source.relative_to(ROOT)}: missing anchor {link}")

    index = (DOCS / "INDEX.md").read_text(encoding="utf-8")
    for document in DOCS.rglob("*.md"):
        if document.name != "INDEX.md":
            relative = document.relative_to(DOCS).as_posix()
            if f"({relative})" not in index:
                errors.append(f"Missing index entry: docs/{relative}")

    for issue in errors:
        print(f"ERROR: {issue}", file=sys.stderr)
    print(f"Docs: {len(SOURCES)} Markdown files, {checked} internal links, "
          f"{len(errors)} issue(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
