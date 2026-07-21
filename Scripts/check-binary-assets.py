#!/usr/bin/env python3
"""Reject unexplained binaries and validate every generated app icon."""

from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
from decimal import Decimal
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parent.parent
SKIP_PARTS = {".git", ".build", "DerivedData", ".venv", "__pycache__"}


def own_git_repository() -> bool:
    result = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "--show-toplevel"],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0 and Path(result.stdout.strip()).resolve() == ROOT


def candidate_files() -> Iterable[Path]:
    if own_git_repository():
        result = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            check=True,
            capture_output=True,
        )
        for raw_path in result.stdout.split(b"\0"):
            if raw_path:
                yield ROOT / os.fsdecode(raw_path)
        return

    for path in ROOT.rglob("*"):
        if path.is_file() and not SKIP_PARTS.intersection(path.relative_to(ROOT).parts):
            if path.name != "Local.xcconfig":
                yield path


def png_dimensions(path: Path) -> tuple[int, int, int]:
    with path.open("rb") as stream:
        header = stream.read(26)
    if len(header) != 26 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError("invalid PNG header")
    width, height = struct.unpack(">II", header[16:24])
    color_type = header[25]
    return width, height, color_type


def expected_pixels(image: dict[str, str]) -> int:
    points = Decimal(image["size"].split("x", 1)[0])
    scale = Decimal(image["scale"].removesuffix("x"))
    return int(points * scale)


def main() -> int:
    errors: list[str] = []
    files = sorted(set(candidate_files()))

    for path in files:
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        sample = path.read_bytes()[:8192]
        if b"\0" not in sample:
            continue
        if path.suffix.lower() != ".png" or "Assets" not in relative.parts or ".xcassets" not in str(relative):
            errors.append(f"unexplained binary file: {relative}")

    referenced_pngs: set[Path] = set()
    for contents_path in sorted((ROOT / "Assets").glob("*.xcassets/AppIcon.appiconset/Contents.json")):
        catalog = json.loads(contents_path.read_text(encoding="utf-8"))
        for image in catalog.get("images", []):
            filename = image.get("filename")
            if not filename:
                continue
            png_path = contents_path.parent / filename
            referenced_pngs.add(png_path.resolve())
            if not png_path.is_file():
                errors.append(f"missing app icon referenced by {contents_path.relative_to(ROOT)}: {filename}")
                continue
            try:
                width, height, color_type = png_dimensions(png_path)
            except ValueError as error:
                errors.append(f"{png_path.relative_to(ROOT)}: {error}")
                continue
            expected = expected_pixels(image)
            if width != expected or height != expected:
                errors.append(
                    f"{png_path.relative_to(ROOT)}: expected {expected}x{expected}, found {width}x{height}"
                )
            if color_type not in {0, 2, 3}:
                errors.append(f"{png_path.relative_to(ROOT)}: app icons must not contain an alpha channel")

    actual_pngs = {path.resolve() for path in (ROOT / "Assets").rglob("*.png")}
    for orphan in sorted(actual_pngs - referenced_pngs):
        errors.append(f"unexplained PNG not referenced by an app icon catalog: {orphan.relative_to(ROOT)}")

    if errors:
        for error in errors:
            print(f"check-binary-assets: {error}", file=sys.stderr)
        return 1

    print(f"check-binary-assets: validated {len(referenced_pngs)} app icons; no unexplained binaries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
