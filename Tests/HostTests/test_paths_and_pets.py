import binascii
import json
import os
import pathlib
import struct
import tempfile
import unittest
import zlib

from cofleet_host.config import HostConfig
from cofleet_host.database import Database
from cofleet_host.errors import APIError
from cofleet_host.paths import create_directory, list_directories
from cofleet_host.pets import PetManager


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)


def make_png(width: int, height: int) -> bytes:
    # Grayscale+alpha keeps a standards-compliant atlas fixture compact.
    raw_row = b"\x00" + (b"\x00\xff" * width)
    pixels = raw_row * height
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 4, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr) + png_chunk(b"IDAT", zlib.compress(pixels, 9)) + png_chunk(b"IEND", b"")


class PathAndPetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_directory_pages_hidden_entries_and_folder_creation(self) -> None:
        parent = self.root / "parent"
        parent.mkdir()
        for name in ("a", "b", "c", ".hidden"):
            (parent / name).mkdir()
        first = list_directories(str(parent), None, 2, False)
        self.assertEqual([item["name"] for item in first["directories"]], ["a", "b"])
        second = list_directories(str(parent), first["nextCursor"], 2, False)
        self.assertEqual([item["name"] for item in second["directories"]], ["c"])
        visible = list_directories(str(parent), None, 10, True)
        self.assertIn(".hidden", [item["name"] for item in visible["directories"]])
        created = create_directory(str(parent), "new folder")
        self.assertEqual(created["canonicalPath"], str((parent / "new folder").resolve()))

    def test_directory_creation_rejects_traversal_and_control_characters(self) -> None:
        with self.assertRaises(APIError):
            create_directory(str(self.root), "../escape")
        with self.assertRaises(APIError):
            create_directory(str(self.root), "bad\x00name")

    def test_symlink_directory_returns_canonical_target(self) -> None:
        target = self.root / "target"
        target.mkdir()
        link = self.root / "link"
        link.symlink_to(target, target_is_directory=True)
        page = list_directories(str(self.root), None, 20, False)
        row = next(item for item in page["directories"] if item["name"] == "link")
        self.assertTrue(row["isSymlink"])
        self.assertEqual(row["canonicalPath"], str(target.resolve()))

    def _manager(self) -> PetManager:
        config = HostConfig(data_dir=self.root / "state", home=self.root, pet_asset_limit=2_000_000)
        return PetManager(config, Database(config.database_path))

    def test_imports_valid_v1_and_deduplicates_digest(self) -> None:
        package = self.root / "pet"
        package.mkdir()
        (package / "spritesheet.png").write_bytes(make_png(1536, 1872))
        (package / "pet.json").write_text(
            json.dumps(
                {
                    "id": "example-pet",
                    "displayName": "Example Pet",
                    "description": "A locally owned example.",
                    "spriteVersionNumber": 1,
                    "spritesheetPath": "spritesheet.png",
                }
            ),
            encoding="utf-8",
        )
        manager = self._manager()
        first = manager.import_package(str(package))
        second = manager.import_package(str(package / "pet.json"))
        self.assertEqual(first["id"], second["id"])
        content_type, asset = manager.asset(first["id"], "spritesheet.png")
        self.assertEqual(content_type, "image/png")
        self.assertTrue(asset.startswith(b"\x89PNG"))
        manager.database.close()

    def test_rejects_wrong_dimensions_and_symlink_escape(self) -> None:
        outside = self.root / "outside.png"
        outside.write_bytes(make_png(16, 16))
        package = self.root / "pet"
        package.mkdir()
        (package / "spritesheet.png").symlink_to(outside)
        (package / "pet.json").write_text(
            json.dumps(
                {
                    "displayName": "Unsafe",
                    "spriteVersionNumber": 2,
                    "spritesheetPath": "spritesheet.png",
                }
            ),
            encoding="utf-8",
        )
        manager = self._manager()
        with self.assertRaises(APIError) as caught:
            manager.import_package(str(package))
        self.assertEqual(caught.exception.code, "unsafe_pet_package")
        manager.database.close()


if __name__ == "__main__":
    unittest.main()
