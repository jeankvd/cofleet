"""Allowlisted community catalogs for Codex-compatible pet packages."""

import json
import re
import threading
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from .errors import APIError
from .pets import MANIFEST_LIMIT, PetManager


CATALOG_CACHE_SECONDS = 15 * 60
CATALOG_RESPONSE_LIMIT = 6 * 1024 * 1024
CATALOG_ITEM_LIMIT = 60
PET_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,119}$")


@dataclass(frozen=True)
class CatalogDefinition:
    id: str
    display_name: str
    description: str
    repository_url: str
    license_summary: str

    def public(self, item_count: Optional[int]) -> Dict[str, Any]:
        result: Dict[str, Any] = {
            "id": self.id,
            "displayName": self.display_name,
            "description": self.description,
            "repositoryURL": self.repository_url,
            "licenseSummary": self.license_summary,
        }
        if item_count is not None:
            result["itemCount"] = item_count
        return result


@dataclass(frozen=True)
class CatalogPet:
    catalog_id: str
    id: str
    display_name: str
    description: str
    author: str
    license: str
    sprite_version_number: int
    preview_url: str
    preview_kind: str
    manifest_url: str
    spritesheet_url: str
    download_hosts: Tuple[str, ...]

    def public(self) -> Dict[str, Any]:
        return {
            "catalogID": self.catalog_id,
            "id": self.id,
            "displayName": self.display_name,
            "description": self.description,
            "author": self.author,
            "license": self.license,
            "spriteVersionNumber": self.sprite_version_number,
            "previewURL": self.preview_url,
            "previewKind": self.preview_kind,
        }


CATALOGS: Tuple[CatalogDefinition, ...] = (
    CatalogDefinition(
        id="codex-pokepets",
        display_name="Codex PokéPets",
        description="Two- and three-dimensional Pokémon fan sprites packaged for Codex.",
        repository_url="https://github.com/dnnyngyen/codex-pokepets",
        license_summary="Personal fan use; Pokémon imagery is not licensed for commercial redistribution.",
    ),
    CatalogDefinition(
        id="petdex",
        display_name="Petdex",
        description="A large community gallery of Codex-compatible animated companions.",
        repository_url="https://github.com/crafter-station/petdex",
        license_summary="Licenses vary by pet and remain with each submitter.",
    ),
    CatalogDefinition(
        id="awesome-codex-pet",
        display_name="Awesome Codex Pet",
        description="A curated, GitHub-native collection with per-pet authorship and licensing.",
        repository_url="https://github.com/legeling/awesome-codex-pet",
        license_summary="Each catalog entry declares its own asset license.",
    ),
    CatalogDefinition(
        id="codex-anime-pets",
        display_name="Codex Anime Pets",
        description="A smaller collection of chibi and pixel-art Codex pets.",
        repository_url="https://github.com/chenxin-dlut/codex-anime-pets",
        license_summary="Personal, non-commercial fan use; see the repository for details.",
    ),
)


class PetCatalogManager:
    def __init__(self, pets: PetManager) -> None:
        self.pets = pets
        self._cache: Dict[str, Tuple[float, List[CatalogPet]]] = {}
        self._lock = threading.Lock()

    def list_catalogs(self) -> List[Dict[str, Any]]:
        with self._lock:
            counts = {key: len(value[1]) for key, value in self._cache.items() if value[0] > time.monotonic()}
        return [catalog.public(counts.get(catalog.id)) for catalog in CATALOGS]

    def page(
        self,
        catalog_id: str,
        query: str = "",
        cursor: Optional[str] = None,
        limit: int = 40,
    ) -> Dict[str, Any]:
        definition = self._definition(catalog_id)
        pets = self._load(catalog_id)
        normalized_query = query.strip().casefold()
        if len(normalized_query) > 120:
            raise APIError(422, "invalid_pet_catalog_query", "Pet catalog searches are limited to 120 characters.")
        if normalized_query:
            pets = [
                pet
                for pet in pets
                if normalized_query in pet.display_name.casefold()
                or normalized_query in pet.id.casefold()
                or normalized_query in pet.author.casefold()
            ]
        try:
            offset = int(cursor or "0")
        except (TypeError, ValueError):
            raise APIError(422, "invalid_cursor", "The pet catalog cursor is invalid.")
        if offset < 0:
            raise APIError(422, "invalid_cursor", "The pet catalog cursor is invalid.")
        bounded_limit = min(CATALOG_ITEM_LIMIT, max(1, limit))
        selected = pets[offset : offset + bounded_limit]
        next_offset = offset + len(selected)
        return {
            "catalog": definition.public(len(pets)),
            "pets": [pet.public() for pet in selected],
            "nextCursor": str(next_offset) if next_offset < len(pets) else None,
        }

    def install(self, catalog_id: str, pet_id: str) -> Dict[str, Any]:
        self._definition(catalog_id)
        if not PET_ID.fullmatch(pet_id):
            raise APIError(422, "invalid_pet_catalog_item", "The catalog pet identifier is invalid.")
        item = next((candidate for candidate in self._load(catalog_id) if candidate.id == pet_id), None)
        if item is None:
            raise APIError(404, "pet_catalog_item_not_found", "That pet is no longer in this catalog.")
        manifest = self._fetch(item.manifest_url, item.download_hosts, MANIFEST_LIMIT)
        spritesheet = self._fetch(
            item.spritesheet_url,
            item.download_hosts,
            self.pets.config.pet_asset_limit,
        )
        return self.pets.import_payload(manifest, spritesheet, item.manifest_url)

    def _load(self, catalog_id: str) -> List[CatalogPet]:
        now_value = time.monotonic()
        with self._lock:
            cached = self._cache.get(catalog_id)
            if cached and cached[0] > now_value:
                return cached[1]
        loaders = {
            "codex-pokepets": self._load_pokepets,
            "petdex": self._load_petdex,
            "awesome-codex-pet": self._load_awesome,
            "codex-anime-pets": self._load_anime,
        }
        loaded = loaders[catalog_id]()
        with self._lock:
            self._cache[catalog_id] = (time.monotonic() + CATALOG_CACHE_SECONDS, loaded)
        return loaded

    @staticmethod
    def _definition(catalog_id: str) -> CatalogDefinition:
        definition = next((catalog for catalog in CATALOGS if catalog.id == catalog_id), None)
        if definition is None:
            raise APIError(404, "pet_catalog_not_found", "That pet catalog is not configured.")
        return definition

    def _load_pokepets(self) -> List[CatalogPet]:
        root = "https://raw.githubusercontent.com/dnnyngyen/codex-pokepets/main"
        payload = self._fetch_json(root + "/pets.json", ("raw.githubusercontent.com",))
        rows = payload.get("pets") if isinstance(payload, dict) else None
        if not isinstance(rows, list):
            raise self._catalog_error()
        result: List[CatalogPet] = []
        for row in rows[:5000]:
            if not isinstance(row, dict):
                continue
            slug = row.get("slug")
            if not isinstance(slug, str) or not PET_ID.fullmatch(slug):
                continue
            base = root + "/pets/" + slug
            result.append(CatalogPet(
                catalog_id="codex-pokepets",
                id=slug,
                display_name=self._text(row.get("name"), slug),
                description=self._text(row.get("description"), ""),
                author=self._text(row.get("author"), "codex-pokepets"),
                license=self._text(row.get("license"), "fan-use"),
                sprite_version_number=1,
                preview_url=base + "/preview.gif",
                preview_kind="animation",
                manifest_url=base + "/pet.json",
                spritesheet_url=base + "/spritesheet.webp",
                download_hosts=("raw.githubusercontent.com",),
            ))
        return result

    def _load_petdex(self) -> List[CatalogPet]:
        payload = self._fetch_json(
            "https://petdex.dev/api/manifest",
            ("petdex.dev", "assets.petdex.dev"),
        )
        rows = payload.get("pets") if isinstance(payload, dict) else None
        if not isinstance(rows, list):
            raise self._catalog_error()
        result: List[CatalogPet] = []
        for row in rows[:5000]:
            if not isinstance(row, dict):
                continue
            slug = row.get("slug")
            manifest_url = row.get("petJsonUrl")
            spritesheet_url = row.get("spritesheetUrl")
            if not isinstance(slug, str) or not PET_ID.fullmatch(slug):
                continue
            if not isinstance(manifest_url, str) or not isinstance(spritesheet_url, str):
                continue
            if not self._allowed_url(manifest_url, ("assets.petdex.dev",)):
                continue
            if not self._allowed_url(spritesheet_url, ("assets.petdex.dev",)):
                continue
            result.append(CatalogPet(
                catalog_id="petdex",
                id=slug,
                display_name=self._text(row.get("displayName"), slug),
                description="",
                author=self._text(row.get("submittedBy"), "Petdex community"),
                license="See the individual Petdex listing",
                sprite_version_number=1,
                preview_url=spritesheet_url,
                preview_kind="atlas",
                manifest_url=manifest_url,
                spritesheet_url=spritesheet_url,
                download_hosts=("assets.petdex.dev",),
            ))
        return result

    def _load_awesome(self) -> List[CatalogPet]:
        root = "https://raw.githubusercontent.com/legeling/awesome-codex-pet/main"
        payload = self._fetch_json(root + "/pets.json", ("raw.githubusercontent.com",))
        if not isinstance(payload, list):
            raise self._catalog_error()
        result: List[CatalogPet] = []
        for row in payload[:1000]:
            if not isinstance(row, dict):
                continue
            slug = row.get("slug")
            if not isinstance(slug, str) or not PET_ID.fullmatch(slug):
                continue
            base = root + "/pets/" + slug
            version = row.get("spriteVersionNumber", 1)
            if type(version) is not int or version not in (1, 2):
                version = 1
            result.append(CatalogPet(
                catalog_id="awesome-codex-pet",
                id=slug,
                display_name=self._text(row.get("name"), slug),
                description=self._text(row.get("description"), ""),
                author=self._text(row.get("author"), "Community contributor"),
                license=self._text(row.get("license"), "See repository entry"),
                sprite_version_number=version,
                preview_url=root + "/assets/previews/" + slug + "/gifs/idle.gif",
                preview_kind="animation",
                manifest_url=base + "/pet.json",
                spritesheet_url=base + "/spritesheet.webp",
                download_hosts=("raw.githubusercontent.com",),
            ))
        return result

    def _load_anime(self) -> List[CatalogPet]:
        tree_url = "https://api.github.com/repos/chenxin-dlut/codex-anime-pets/git/trees/main?recursive=1"
        payload = self._fetch_json(tree_url, ("api.github.com",))
        rows = payload.get("tree") if isinstance(payload, dict) else None
        if not isinstance(rows, list):
            raise self._catalog_error()
        root = "https://raw.githubusercontent.com/chenxin-dlut/codex-anime-pets/main"
        slugs = sorted({
            path.split("/")[1]
            for row in rows
            if isinstance(row, dict)
            and isinstance((path := row.get("path")), str)
            and path.startswith("pets/")
            and path.endswith("/pet.json")
            and len(path.split("/")) == 3
            and PET_ID.fullmatch(path.split("/")[1])
        })
        return [
            CatalogPet(
                catalog_id="codex-anime-pets",
                id=slug,
                display_name=slug.replace("-", " ").title(),
                description="",
                author="chenxin-dlut",
                license="Personal non-commercial fan use",
                sprite_version_number=1,
                preview_url=root + "/assets/previews/" + slug + ".png",
                preview_kind="animation",
                manifest_url=root + "/pets/" + slug + "/pet.json",
                spritesheet_url=root + "/pets/" + slug + "/spritesheet.webp",
                download_hosts=("raw.githubusercontent.com",),
            )
            for slug in slugs
        ]

    def _fetch_json(self, url: str, allowed_hosts: Sequence[str]) -> Any:
        data = self._fetch(url, allowed_hosts, CATALOG_RESPONSE_LIMIT)
        try:
            return json.loads(data.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            raise self._catalog_error()

    @staticmethod
    def _fetch(url: str, allowed_hosts: Sequence[str], maximum_bytes: int) -> bytes:
        parsed = urlparse(url)
        if parsed.scheme != "https" or parsed.hostname not in allowed_hosts or parsed.username or parsed.password:
            raise APIError(502, "pet_catalog_unavailable", "A catalog returned an unsafe download URL.")
        request = Request(url, headers={"Accept": "application/json,image/*", "User-Agent": "cofleet-host/1"})
        try:
            with urlopen(request, timeout=12) as response:
                final = urlparse(response.geturl())
                if final.scheme != "https" or final.hostname not in allowed_hosts:
                    raise APIError(502, "pet_catalog_unavailable", "A catalog redirected outside its allowlist.")
                length = response.headers.get("Content-Length")
                if length and int(length) > maximum_bytes:
                    raise APIError(502, "pet_catalog_response_too_large", "A catalog response exceeded its size limit.")
                data = response.read(maximum_bytes + 1)
        except APIError:
            raise
        except (HTTPError, URLError, OSError, ValueError):
            raise APIError(502, "pet_catalog_unavailable", "The community pet catalog is temporarily unavailable.")
        if not data or len(data) > maximum_bytes:
            raise APIError(502, "pet_catalog_response_too_large", "A catalog response exceeded its size limit.")
        return data

    @staticmethod
    def _allowed_url(url: str, allowed_hosts: Sequence[str]) -> bool:
        parsed = urlparse(url)
        return (
            parsed.scheme == "https"
            and parsed.hostname in allowed_hosts
            and parsed.username is None
            and parsed.password is None
        )

    @staticmethod
    def _text(value: Any, fallback: str) -> str:
        return value.strip()[:500] if isinstance(value, str) and value.strip() else fallback

    @staticmethod
    def _catalog_error() -> APIError:
        return APIError(502, "pet_catalog_invalid", "The community pet catalog returned invalid data.")
