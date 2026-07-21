"""Canonical and bounded filesystem operations."""

import os
import pathlib
import stat
from typing import Any, Dict, List, Optional

from .errors import APIError
from .util import CONTROL_CHARACTERS, decode_cursor, encode_cursor


def canonical_directory(raw_path: str) -> pathlib.Path:
    if not isinstance(raw_path, str) or not raw_path or len(raw_path) > 4096:
        raise APIError(422, "invalid_path", "A directory path is required.")
    if CONTROL_CHARACTERS.search(raw_path):
        raise APIError(422, "invalid_path", "The directory path contains control characters.")
    candidate = pathlib.Path(raw_path).expanduser()
    if not candidate.is_absolute():
        raise APIError(422, "invalid_path", "Directory paths must be absolute.")
    try:
        canonical = candidate.resolve(strict=True)
    except FileNotFoundError:
        raise APIError(404, "directory_not_found", "The directory does not exist.")
    except (OSError, RuntimeError):
        raise APIError(403, "directory_unreadable", "The directory cannot be resolved.")
    try:
        mode = canonical.stat().st_mode
    except OSError:
        raise APIError(403, "directory_unreadable", "The directory cannot be inspected.")
    if not stat.S_ISDIR(mode):
        raise APIError(422, "not_a_directory", "The selected path is not a directory.")
    return canonical


def list_directories(
    raw_path: str,
    cursor: Optional[str],
    limit: int,
    show_hidden: bool,
) -> Dict[str, Any]:
    directory = canonical_directory(raw_path)
    offset = decode_cursor(cursor)
    entries: List[Dict[str, Any]] = []
    try:
        scanned = list(os.scandir(str(directory)))
    except PermissionError:
        raise APIError(403, "directory_unreadable", "The directory is not readable.")
    except OSError:
        raise APIError(503, "directory_unavailable", "The directory could not be read.")
    scanned.sort(key=lambda entry: (entry.name.casefold(), entry.name))
    for entry in scanned:
        if not show_hidden and entry.name.startswith("."):
            continue
        try:
            if not entry.is_dir(follow_symlinks=True):
                continue
            target = pathlib.Path(entry.path).resolve(strict=True)
            readable = os.access(str(target), os.R_OK | os.X_OK)
            entries.append(
                {
                    "name": entry.name,
                    "path": entry.path,
                    "canonicalPath": str(target),
                    "isSymlink": entry.is_symlink(),
                    "readable": readable,
                }
            )
        except (FileNotFoundError, PermissionError, OSError, RuntimeError):
            # A racing or inaccessible symlink is not a navigable directory.
            continue
    page = entries[offset : offset + limit]
    next_offset = offset + len(page)
    return {
        "path": str(directory),
        "parentPath": str(directory.parent) if directory.parent != directory else None,
        "directories": page,
        "nextCursor": encode_cursor(next_offset) if next_offset < len(entries) else None,
    }

def create_directory(raw_parent: str, raw_name: str) -> Dict[str, Any]:
    parent = canonical_directory(raw_parent)
    if not isinstance(raw_name, str):
        raise APIError(422, "invalid_directory_name", "A folder name is required.")
    name = raw_name.strip()
    if (
        not name
        or len(name.encode("utf-8")) > 255
        or name in (".", "..")
        or "/" in name
        or (os.altsep is not None and os.altsep in name)
        or CONTROL_CHARACTERS.search(name)
    ):
        raise APIError(422, "invalid_directory_name", "The folder name is invalid.")
    child = parent / name
    try:
        os.mkdir(str(child), 0o755)
    except FileExistsError:
        raise APIError(409, "directory_exists", "A file or folder with that name already exists.")
    except PermissionError:
        raise APIError(403, "directory_unwritable", "The parent directory is not writable.")
    except OSError:
        raise APIError(503, "directory_creation_failed", "The folder could not be created.")
    canonical = canonical_directory(str(child))
    # A single-component mkdir should remain under the canonical parent. Check
    # anyway to make the invariant explicit if an unusual filesystem races us.
    try:
        common = os.path.commonpath((str(parent), str(canonical)))
    except ValueError:
        common = ""
    if common != str(parent):
        try:
            os.rmdir(str(child))
        except OSError:
            pass
        raise APIError(409, "path_changed", "The new folder resolved outside its parent.")
    return {
        "name": name,
        "path": str(child),
        "canonicalPath": str(canonical),
        "isSymlink": False,
        "readable": True,
    }
