import binascii
import json
import pathlib
import struct
import tempfile
import time
import unittest
import zlib

from cofleet_host.config import HostConfig
from cofleet_host.database import Database
from cofleet_host.errors import APIError
from cofleet_host.pet_catalogs import CATALOGS, CatalogPet, PetCatalogManager
from cofleet_host.pets import PetManager
from helpers import ServiceFixture


class _FakeCatalogService:
    def __init__(self) -> None:
        self.installs = []

    def list_catalogs(self):
        return [{
            "id": "codex-pokepets",
            "displayName": "Codex PokéPets",
            "description": "Test",
            "repositoryURL": "https://github.com/dnnyngyen/codex-pokepets",
            "licenseSummary": "fan-use",
        }]

    def page(self, catalog_id, query="", cursor=None, limit=40):
        return {
            "catalog": self.list_catalogs()[0],
            "pets": [],
            "nextCursor": None,
        }

    def install(self, catalog_id, pet_id):
        self.installs.append((catalog_id, pet_id))
        return {"id": "pet_test", "displayName": "Test"}


def _png_chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = binascii.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def _make_png(width: int, height: int) -> bytes:
    row = b"\x00" + (b"\x00\xff" * width)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 4, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", zlib.compress(row * height, 9))
        + _png_chunk(b"IEND", b"")
    )


class PetCatalogTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.temporary.name)
        self.config = HostConfig(data_dir=root / "state", home=root, pet_asset_limit=3_000_000)
        self.database = Database(self.config.database_path)
        self.pets = PetManager(self.config, self.database)
        self.catalogs = PetCatalogManager(self.pets)

    def tearDown(self) -> None:
        self.database.close()
        self.temporary.cleanup()

    def _item(self, identifier: str, name: str, author: str = "Author") -> CatalogPet:
        return CatalogPet(
            catalog_id="codex-pokepets",
            id=identifier,
            display_name=name,
            description="A test pet",
            author=author,
            license="fan-use",
            sprite_version_number=1,
            preview_url="https://raw.githubusercontent.com/example/preview.gif",
            preview_kind="animation",
            manifest_url="https://raw.githubusercontent.com/example/pet.json",
            spritesheet_url="https://raw.githubusercontent.com/example/spritesheet.png",
            download_hosts=("raw.githubusercontent.com",),
        )

    def test_exposes_each_repository_as_a_separate_catalog(self) -> None:
        rows = self.catalogs.list_catalogs()
        self.assertEqual(
            [row["id"] for row in rows],
            [
                "codex-pokepets",
                "petdex",
                "awesome-codex-pet",
                "codex-anime-pets",
            ],
        )
        self.assertEqual(len(rows), len(CATALOGS))

    def test_catalog_pages_search_and_paginate_without_mixing_sources(self) -> None:
        self.catalogs._cache["codex-pokepets"] = (
            time.monotonic() + 60,
            [self._item("bulbasaur", "Bulbasaur"), self._item("charizard", "Charizard")],
        )
        first = self.catalogs.page("codex-pokepets", limit=1)
        self.assertEqual([pet["id"] for pet in first["pets"]], ["bulbasaur"])
        self.assertEqual(first["nextCursor"], "1")
        second = self.catalogs.page("codex-pokepets", cursor="1", limit=1)
        self.assertEqual([pet["id"] for pet in second["pets"]], ["charizard"])
        filtered = self.catalogs.page("codex-pokepets", query="char", limit=40)
        self.assertEqual([pet["id"] for pet in filtered["pets"]], ["charizard"])

    def test_remote_install_still_uses_pet_atlas_validation_and_deduplication(self) -> None:
        item = self._item("example", "Example")
        self.catalogs._cache["codex-pokepets"] = (time.monotonic() + 60, [item])
        manifest = json.dumps({
            "id": "example",
            "displayName": "Example",
            "spritesheetPath": "spritesheet.png",
        }).encode("utf-8")
        atlas = _make_png(1536, 1872)

        def fetch(url, _hosts, _limit):
            return manifest if url.endswith("pet.json") else atlas

        self.catalogs._fetch = fetch
        first = self.catalogs.install("codex-pokepets", "example")
        second = self.catalogs.install("codex-pokepets", "example")
        self.assertEqual(first["id"], second["id"])
        self.assertEqual(first["displayName"], "Example")

    def test_rejects_unknown_catalogs_and_non_https_downloads(self) -> None:
        with self.assertRaises(APIError) as missing:
            self.catalogs.page("not-configured")
        self.assertEqual(missing.exception.code, "pet_catalog_not_found")
        with self.assertRaises(APIError) as unsafe:
            self.catalogs._fetch("http://raw.githubusercontent.com/pet.json", ("raw.githubusercontent.com",), 100)
        self.assertEqual(unsafe.exception.code, "pet_catalog_unavailable")

    def test_catalog_routes_require_pairing_and_keep_catalog_identity(self) -> None:
        fixture = ServiceFixture()
        try:
            fake = _FakeCatalogService()
            fixture.service.pet_catalogs = fake
            with self.assertRaises(APIError) as unauthenticated:
                fixture.service.dispatch("GET", "/v1/pet-catalogs", {}, {}, {}, None)
            self.assertEqual(unauthenticated.exception.status, 401)
            device, _ = fixture.pair()
            catalogs = fixture.service.dispatch("GET", "/v1/pet-catalogs", {}, {}, {}, device)
            self.assertEqual(catalogs.payload["catalogs"][0]["id"], "codex-pokepets")
            installed = fixture.service.dispatch(
                "POST",
                "/v1/pet-catalogs/codex-pokepets/pets/bulbasaur/install",
                {},
                {},
                {},
                device,
            )
            self.assertEqual(installed.status, 201)
            self.assertEqual(fake.installs, [("codex-pokepets", "bulbasaur")])
        finally:
            fixture.close()


if __name__ == "__main__":
    unittest.main()
