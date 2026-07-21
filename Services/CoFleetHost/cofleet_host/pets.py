"""Validation and import of locally owned Codex-compatible pet packages."""

import hashlib
import json
import os
import pathlib
import shutil
import stat
import struct
import zlib
from typing import Any, Dict, List, Optional, Tuple

from .config import HostConfig
from .database import Database
from .errors import APIError
from .util import CONTROL_CHARACTERS, atomic_write, canonical_json


MANIFEST_LIMIT = 64 * 1024
EXPECTED_DIMENSIONS = {1: (1536, 1872), 2: (1536, 2288)}
ALLOWED_SPRITE_EXTENSIONS = {".png", ".webp"}


def _read_regular(path: pathlib.Path, limit: int) -> bytes:
    try:
        if path.is_symlink():
            raise APIError(422, "unsafe_pet_package", "Pet package files cannot be symlinks.")
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(str(path), flags)
    except FileNotFoundError:
        raise APIError(404, "pet_asset_not_found", "A pet package file is missing.")
    except PermissionError:
        raise APIError(403, "pet_asset_unreadable", "A pet package file is not readable.")
    except OSError:
        raise APIError(422, "unsafe_pet_package", "A pet package file could not be opened safely.")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise APIError(422, "unsafe_pet_package", "Pet package assets must be regular files.")
        if metadata.st_size <= 0 or metadata.st_size > limit:
            raise APIError(422, "pet_asset_size", "A pet package file has an invalid size.")
        chunks = bytearray()
        while len(chunks) <= limit:
            chunk = os.read(descriptor, min(64 * 1024, limit + 1 - len(chunks)))
            if not chunk:
                break
            chunks.extend(chunk)
        if len(chunks) > limit:
            raise APIError(422, "pet_asset_size", "A pet package file is too large.")
        return bytes(chunks)
    finally:
        os.close(descriptor)


def _png_size(data: bytes) -> Tuple[int, int]:
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise APIError(422, "invalid_pet_image", "The PNG spritesheet header is invalid.")
    offset = 8
    chunks: List[bytes] = []
    image_size: Optional[Tuple[int, int]] = None
    bit_depth = 0
    color_type = -1
    interlace = -1
    saw_end = False
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        kind = data[offset + 4 : offset + 8]
        end = offset + 12 + length
        if length > len(data) or end > len(data):
            raise APIError(422, "invalid_pet_image", "A PNG chunk is truncated.")
        payload = data[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack(">I", data[offset + 8 + length : end])[0]
        if zlib.crc32(kind + payload) & 0xFFFFFFFF != expected_crc:
            raise APIError(422, "invalid_pet_image", "A PNG chunk checksum is invalid.")
        if offset == 8 and (kind != b"IHDR" or length != 13):
            raise APIError(422, "invalid_pet_image", "PNG must begin with a valid IHDR chunk.")
        if kind == b"IHDR":
            width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if width <= 0 or height <= 0 or compression != 0 or filtering != 0 or interlace != 0:
                raise APIError(422, "invalid_pet_image", "The PNG encoding is unsupported.")
            image_size = (width, height)
        elif kind == b"IDAT":
            chunks.append(payload)
        elif kind == b"IEND":
            if length != 0:
                raise APIError(422, "invalid_pet_image", "The PNG IEND chunk is invalid.")
            saw_end = True
            offset = end
            break
        offset = end
    if not saw_end or offset != len(data) or image_size is None or not chunks:
        raise APIError(422, "invalid_pet_image", "The PNG spritesheet is incomplete.")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type)
    if channels is None or bit_depth not in (8, 16):
        raise APIError(422, "invalid_pet_image", "The PNG color format is unsupported.")
    row_bytes = (image_size[0] * channels * bit_depth + 7) // 8
    expected_size = (row_bytes + 1) * image_size[1]
    decompressor = zlib.decompressobj()
    try:
        decoded = decompressor.decompress(b"".join(chunks), expected_size + 1)
        if decompressor.unconsumed_tail or len(decoded) > expected_size:
            raise APIError(422, "invalid_pet_image", "The PNG pixel stream is larger than declared.")
        remaining = expected_size + 1 - len(decoded)
        if remaining > 0:
            decoded += decompressor.flush(remaining)
    except zlib.error:
        raise APIError(422, "invalid_pet_image", "The PNG pixel stream is invalid.")
    if not decompressor.eof or len(decoded) != expected_size:
        raise APIError(422, "invalid_pet_image", "The PNG pixel stream has an invalid size.")
    return image_size


def _webp_size(data: bytes) -> Tuple[int, int]:
    if len(data) < 30 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise APIError(422, "invalid_pet_image", "The WebP spritesheet header is invalid.")
    riff_size = int.from_bytes(data[4:8], "little")
    if riff_size + 8 != len(data):
        raise APIError(422, "invalid_pet_image", "The WebP container size is invalid.")
    offset = 12
    while offset + 8 <= len(data):
        chunk_size = int.from_bytes(data[offset + 4 : offset + 8], "little")
        offset += 8 + chunk_size + (chunk_size & 1)
        if offset > len(data):
            raise APIError(422, "invalid_pet_image", "A WebP chunk is truncated.")
    if offset != len(data):
        raise APIError(422, "invalid_pet_image", "The WebP container is malformed.")
    kind = data[12:16]
    if kind == b"VP8X" and len(data) >= 30:
        width = 1 + int.from_bytes(data[24:27], "little")
        height = 1 + int.from_bytes(data[27:30], "little")
        return width, height
    if kind == b"VP8L" and len(data) >= 25 and data[20] == 0x2F:
        bits = int.from_bytes(data[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    if kind == b"VP8 " and len(data) >= 30 and data[23:26] == b"\x9d\x01\x2a":
        width, height = struct.unpack("<HH", data[26:30])
        return width & 0x3FFF, height & 0x3FFF
    raise APIError(422, "invalid_pet_image", "The WebP dimensions could not be read.")


class PetManager:
    def __init__(self, config: HostConfig, database: Database) -> None:
        self.config = config
        self.database = database

    def discover(self) -> List[Dict[str, Any]]:
        root = self.config.home / ".codex" / "pets"
        if not root.is_dir():
            return []
        found: List[Dict[str, Any]] = []
        try:
            children = sorted(root.iterdir(), key=lambda path: path.name.casefold())[:200]
        except OSError:
            return []
        for child in children:
            manifest = child / "pet.json"
            try:
                normalized, _, digest = self.validate(str(manifest))
            except APIError:
                continue
            found.append(
                {
                    "sourcePath": str(manifest),
                    "displayName": normalized["displayName"],
                    "description": normalized["description"],
                    "spriteVersionNumber": normalized["spriteVersionNumber"],
                    "digest": digest,
                }
            )
        return found

    def validate(self, raw_path: str) -> Tuple[Dict[str, Any], bytes, str]:
        if not isinstance(raw_path, str) or not raw_path or len(raw_path) > 4096:
            raise APIError(422, "invalid_pet_path", "A pet.json path or package folder is required.")
        if CONTROL_CHARACTERS.search(raw_path):
            raise APIError(422, "invalid_pet_path", "The pet path contains control characters.")
        candidate = pathlib.Path(raw_path).expanduser()
        if not candidate.is_absolute():
            raise APIError(422, "invalid_pet_path", "Pet paths must be absolute.")
        manifest_path = candidate / "pet.json" if candidate.is_dir() else candidate
        manifest_bytes = _read_regular(manifest_path, MANIFEST_LIMIT)
        try:
            manifest = json.loads(manifest_bytes.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            raise APIError(422, "invalid_pet_manifest", "pet.json must contain valid UTF-8 JSON.")
        if not isinstance(manifest, dict):
            raise APIError(422, "invalid_pet_manifest", "pet.json must contain a JSON object.")
        display_name = manifest.get("displayName")
        if not isinstance(display_name, str) or not display_name.strip() or len(display_name) > 80:
            raise APIError(422, "invalid_pet_manifest", "displayName must contain 1 to 80 characters.")
        if CONTROL_CHARACTERS.search(display_name):
            raise APIError(422, "invalid_pet_manifest", "displayName contains control characters.")
        description = manifest.get("description", "")
        if not isinstance(description, str) or len(description) > 500:
            raise APIError(422, "invalid_pet_manifest", "description must be at most 500 characters.")
        sprite_version = manifest.get("spriteVersionNumber", 1)
        if type(sprite_version) is not int or sprite_version not in EXPECTED_DIMENSIONS:
            raise APIError(422, "unsupported_pet_version", "Only Codex pet versions 1 and 2 are supported.")
        sprite_path_value = manifest.get("spritesheetPath", manifest.get("spriteSheetPath"))
        if not isinstance(sprite_path_value, str) or not sprite_path_value:
            raise APIError(422, "invalid_pet_manifest", "spritesheetPath is required.")
        if CONTROL_CHARACTERS.search(sprite_path_value) or len(sprite_path_value) > 512:
            raise APIError(422, "invalid_pet_manifest", "spritesheetPath is invalid.")
        relative = pathlib.PurePosixPath(sprite_path_value.replace("\\", "/"))
        if relative.is_absolute() or ".." in relative.parts or not relative.parts:
            raise APIError(422, "unsafe_pet_package", "The spritesheet path must stay inside the package.")
        source_root = manifest_path.parent.resolve(strict=True)
        sprite_path = source_root.joinpath(*relative.parts)
        try:
            resolved_sprite = sprite_path.resolve(strict=True)
            common = os.path.commonpath((str(source_root), str(resolved_sprite)))
        except (ValueError, OSError, RuntimeError):
            raise APIError(422, "unsafe_pet_package", "The spritesheet path cannot be resolved safely.")
        if common != str(source_root) or sprite_path.is_symlink():
            raise APIError(422, "unsafe_pet_package", "The spritesheet cannot escape through a symlink.")
        extension = resolved_sprite.suffix.lower()
        if extension not in ALLOWED_SPRITE_EXTENSIONS:
            raise APIError(422, "invalid_pet_image", "Spritesheets must be PNG or WebP.")
        asset = _read_regular(resolved_sprite, self.config.pet_asset_limit)
        size = _png_size(asset) if extension == ".png" else _webp_size(asset)
        if size != EXPECTED_DIMENSIONS[sprite_version]:
            raise APIError(
                422,
                "invalid_pet_dimensions",
                "Version %d spritesheets must be %dx%d pixels." % (
                    sprite_version,
                    EXPECTED_DIMENSIONS[sprite_version][0],
                    EXPECTED_DIMENSIONS[sprite_version][1],
                ),
                {"actualWidth": size[0], "actualHeight": size[1]},
            )
        normalized = {
            "id": str(manifest.get("id") or display_name.strip().lower().replace(" ", "-"))[:80],
            "displayName": display_name.strip(),
            "description": description.strip(),
            "spriteVersionNumber": sprite_version,
            "spritesheetPath": "spritesheet" + extension,
            "frameWidth": 192,
            "frameHeight": 208,
            "columns": 8,
            "rows": 9 if sprite_version == 1 else 11,
        }
        digest = hashlib.sha256(canonical_json(normalized).encode("utf-8") + asset).hexdigest()
        return normalized, asset, digest

    def import_package(self, raw_path: str) -> Dict[str, Any]:
        normalized, asset, digest = self.validate(raw_path)
        existing = [pet for pet in self.database.list_pets() if pet["digest"] == digest]
        if existing:
            return existing[0]
        destination = self.config.pets_path / digest
        destination.mkdir(parents=True, exist_ok=True, mode=0o700)
        sprite_name = normalized["spritesheetPath"]
        atomic_write(str(destination / sprite_name), asset, 0o600)
        atomic_write(
            str(destination / "pet.json"),
            (canonical_json(normalized) + "\n").encode("utf-8"),
            0o600,
        )
        return self.database.add_pet(
            source_path=str(pathlib.Path(raw_path).expanduser()),
            storage_path=str(destination),
            display_name=normalized["displayName"],
            description=normalized["description"],
            sprite_version=normalized["spriteVersionNumber"],
            manifest=normalized,
            digest=digest,
        )

    def asset(self, pet_id: str, name: str) -> Tuple[str, bytes]:
        pet = self.database.get_pet(pet_id)
        allowed = {"pet.json", pet["manifest"]["spritesheetPath"]}
        if name not in allowed or name != os.path.basename(name):
            raise APIError(404, "pet_asset_not_found", "The pet asset was not found.")
        path = pathlib.Path(pet["storagePath"]) / name
        data = _read_regular(path, self.config.pet_asset_limit)
        content_type = "application/json" if name.endswith(".json") else (
            "image/png" if name.endswith(".png") else "image/webp"
        )
        return content_type, data
