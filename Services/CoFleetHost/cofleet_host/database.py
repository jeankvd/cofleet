"""SQLite persistence for host-owned CoFleet state."""

import json
import os
import pathlib
import sqlite3
import threading
from contextlib import contextmanager
from typing import Any, Dict, Iterator, List, Optional, Tuple

from .errors import APIError
from .util import canonical_json, new_id, now, secure_equal, token_hash


SCHEMA_VERSION = 3
SESSION_CATALOG_CACHE_MAX_ITEMS = 5
SESSION_CATALOG_CACHE_MAX_BYTES = 128 * 1024
SESSION_CATALOG_SESSION_KEYS = frozenset(
    (
        "id",
        "hostID",
        "projectID",
        "title",
        "cwd",
        "preview",
        "createdAt",
        "updatedAt",
        "archived",
        "model",
        "accessLevel",
        "reasoningEffort",
        "serviceTier",
        "provider",
    )
)


class Database:
    """A serialized SQLite connection.

    The HTTP server is threaded, so all transactions pass through one reentrant
    lock. WAL remains enabled for robust restart behavior and future read-only
    tooling, but correctness never depends on SQLite's connection-level races.
    """

    def __init__(
        self,
        path: pathlib.Path,
        event_limit: int = 2_000,
        event_payload_limit: int = 256 * 1024,
        event_storage_limit: int = 16 * 1024 * 1024,
        event_replay_limit: int = 200,
        event_replay_bytes: int = 2 * 1024 * 1024,
    ) -> None:
        self.path = pathlib.Path(path)
        self.event_limit = event_limit
        self.event_payload_limit = event_payload_limit
        self.event_storage_limit = event_storage_limit
        self.event_replay_limit = event_replay_limit
        self.event_replay_bytes = event_replay_bytes
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            os.chmod(str(self.path.parent), 0o700)
        except OSError:
            pass
        self._lock = threading.RLock()
        self._connection = sqlite3.connect(
            str(self.path), timeout=10.0, check_same_thread=False, isolation_level=None
        )
        self._connection.row_factory = sqlite3.Row
        with self._lock:
            self._connection.execute("PRAGMA foreign_keys = ON")
            self._connection.execute("PRAGMA journal_mode = WAL")
            self._connection.execute("PRAGMA synchronous = FULL")
            self._connection.execute("PRAGMA busy_timeout = 10000")
            self._migrate()

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            self._connection.execute("BEGIN IMMEDIATE")
            try:
                yield self._connection
            except BaseException:
                self._connection.execute("ROLLBACK")
                raise
            else:
                self._connection.execute("COMMIT")

    def _migrate(self) -> None:
        self._connection.execute(
            "CREATE TABLE IF NOT EXISTS schema_metadata "
            "(key TEXT PRIMARY KEY, value TEXT NOT NULL)"
        )
        row = self._connection.execute(
            "SELECT value FROM schema_metadata WHERE key = 'schema_version'"
        ).fetchone()
        if row is not None and int(row["value"]) > SCHEMA_VERSION:
            raise RuntimeError("cofleet-host database was created by a newer version")
        if row is None:
            self._connection.executescript(
                """
                CREATE TABLE host_metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE pairing_codes (
                    code_hash TEXT PRIMARY KEY,
                    expires_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    created_by TEXT,
                    used_at REAL
                );
                CREATE TABLE devices (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    token_hash TEXT NOT NULL UNIQUE,
                    created_at REAL NOT NULL,
                    last_seen_at REAL NOT NULL,
                    revoked_at REAL
                );
                CREATE TABLE projects (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    root_path TEXT NOT NULL,
                    canonical_path TEXT NOT NULL UNIQUE,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE session_settings (
                    session_id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    access_level TEXT NOT NULL,
                    model TEXT,
                    reasoning_effort TEXT,
                    service_tier TEXT,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE session_catalog_cache (
                    project_id TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
                    payload_json TEXT NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE notes (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    session_id TEXT,
                    title TEXT NOT NULL,
                    markdown TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX notes_project_updated ON notes(project_id, updated_at DESC);
                CREATE TABLE todos (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
                    session_id TEXT,
                    text TEXT NOT NULL,
                    completed INTEGER NOT NULL,
                    position INTEGER NOT NULL,
                    revision INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
                CREATE INDEX todos_project_position ON todos(project_id, position, created_at);
                CREATE TABLE pets (
                    id TEXT PRIMARY KEY,
                    source_path TEXT NOT NULL,
                    storage_path TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    description TEXT NOT NULL,
                    sprite_version INTEGER NOT NULL,
                    manifest_json TEXT NOT NULL,
                    digest TEXT NOT NULL UNIQUE,
                    created_at REAL NOT NULL
                );
                CREATE TABLE project_pets (
                    project_id TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
                    pet_id TEXT NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
                    updated_at REAL NOT NULL
                );
                CREATE TABLE event_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_type TEXT NOT NULL,
                    data_json TEXT NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE idempotency (
                    scope TEXT NOT NULL,
                    key TEXT NOT NULL,
                    request_hash TEXT NOT NULL,
                    status_code INTEGER,
                    response_json TEXT,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    PRIMARY KEY(scope, key)
                );
                CREATE TABLE interactions (
                    id TEXT PRIMARY KEY,
                    session_id TEXT,
                    turn_id TEXT,
                    rpc_id_json TEXT NOT NULL,
                    process_generation TEXT NOT NULL,
                    method TEXT NOT NULL,
                    params_json TEXT NOT NULL,
                    state TEXT NOT NULL,
                    response_json TEXT,
                    expires_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    resolved_at REAL
                );
                CREATE INDEX interactions_state_expiry ON interactions(state, expires_at);
                """
            )
            self._connection.execute(
                "INSERT INTO schema_metadata(key, value) VALUES('schema_version', ?)",
                (str(SCHEMA_VERSION),),
            )
        else:
            version = int(row["value"])
            self._connection.execute("BEGIN IMMEDIATE")
            try:
                if version == 1:
                    interaction_columns = {
                        str(item["name"])
                        for item in self._connection.execute(
                            "PRAGMA table_info(interactions)"
                        ).fetchall()
                    }
                    if "process_generation" not in interaction_columns:
                        self._connection.execute(
                            "ALTER TABLE interactions ADD COLUMN process_generation TEXT NOT NULL "
                            "DEFAULT 'legacy-process'"
                        )
                    version = 2
                    self._connection.execute(
                        "UPDATE schema_metadata SET value = ? WHERE key = 'schema_version'",
                        (str(version),),
                    )
                if version == 2:
                    self._connection.execute(
                        "CREATE TABLE IF NOT EXISTS session_catalog_cache ("
                        "project_id TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE, "
                        "payload_json TEXT NOT NULL, updated_at REAL NOT NULL)"
                    )
                    version = 3
                    self._connection.execute(
                        "UPDATE schema_metadata SET value = ? WHERE key = 'schema_version'",
                        (str(version),),
                    )
                if version != SCHEMA_VERSION:
                    raise RuntimeError("unsupported cofleet-host database schema")
            except BaseException:
                self._connection.execute("ROLLBACK")
                raise
            else:
                self._connection.execute("COMMIT")

    def host_id(self) -> str:
        with self.transaction() as connection:
            row = connection.execute(
                "SELECT value FROM host_metadata WHERE key = 'host_id'"
            ).fetchone()
            if row is not None:
                return str(row["value"])
            host_id = new_id("host")
            connection.execute(
                "INSERT INTO host_metadata(key, value) VALUES('host_id', ?)", (host_id,)
            )
            return host_id

    # Pairing and bearer tokens -------------------------------------------------

    def create_pairing(self, code: str, expires_at: float, created_by: Optional[str]) -> None:
        digest = token_hash(code)
        timestamp = now()
        with self.transaction() as connection:
            connection.execute("DELETE FROM pairing_codes WHERE expires_at < ?", (timestamp,))
            connection.execute(
                "INSERT INTO pairing_codes(code_hash, expires_at, created_at, created_by) "
                "VALUES(?, ?, ?, ?)",
                (digest, expires_at, timestamp, created_by),
            )

    def redeem_pairing(self, code: str, device_name: str, token: str) -> Dict[str, Any]:
        digest = token_hash(code)
        timestamp = now()
        with self.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM pairing_codes WHERE code_hash = ?", (digest,)
            ).fetchone()
            if (
                row is None
                or row["used_at"] is not None
                or float(row["expires_at"]) <= timestamp
            ):
                # Avoid distinguishing expired, consumed, and unknown codes.
                raise APIError(410, "pairing_expired", "The pairing code is invalid or expired.")
            device_id = new_id("device")
            connection.execute(
                "UPDATE pairing_codes SET used_at = ? WHERE code_hash = ? AND used_at IS NULL",
                (timestamp, digest),
            )
            connection.execute(
                "INSERT INTO devices(id, name, token_hash, created_at, last_seen_at) "
                "VALUES(?, ?, ?, ?, ?)",
                (device_id, device_name, token_hash(token), timestamp, timestamp),
            )
        return {
            "id": device_id,
            "name": device_name,
            "createdAt": timestamp,
            "lastSeenAt": timestamp,
            "revoked": False,
        }

    def authenticate(self, token: str) -> Optional[Dict[str, Any]]:
        if len(token) < 32 or len(token) > 256:
            return None
        digest = token_hash(token)
        timestamp = now()
        with self.transaction() as connection:
            # The token is random, so a direct indexed lookup does not expose a
            # user-controlled low-entropy secret. Compare again in constant time.
            row = connection.execute(
                "SELECT * FROM devices WHERE token_hash = ? AND revoked_at IS NULL", (digest,)
            ).fetchone()
            if row is None or not secure_equal(str(row["token_hash"]), digest):
                return None
            connection.execute(
                "UPDATE devices SET last_seen_at = ? WHERE id = ?", (timestamp, row["id"])
            )
            return self._device(row, last_seen_at=timestamp)

    def token_is_active(self, token: str) -> bool:
        """Check a live stream token without extending or mutating its session."""
        if len(token) < 32 or len(token) > 256:
            return False
        digest = token_hash(token)
        with self._lock:
            row = self._connection.execute(
                "SELECT token_hash FROM devices WHERE token_hash = ? AND revoked_at IS NULL",
                (digest,),
            ).fetchone()
        return row is not None and secure_equal(str(row["token_hash"]), digest)

    def list_devices(self) -> List[Dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT * FROM devices ORDER BY created_at"
            ).fetchall()
        return [self._device(row) for row in rows]

    def revoke_device(self, device_id: str) -> Dict[str, Any]:
        timestamp = now()
        with self.transaction() as connection:
            row = connection.execute("SELECT * FROM devices WHERE id = ?", (device_id,)).fetchone()
            if row is None:
                raise APIError(404, "device_not_found", "The paired device was not found.")
            connection.execute(
                "UPDATE devices SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ?",
                (timestamp, device_id),
            )
            updated = connection.execute(
                "SELECT * FROM devices WHERE id = ?", (device_id,)
            ).fetchone()
        return self._device(updated)

    def rotate_device(self, device_id: str, token: str) -> Dict[str, Any]:
        timestamp = now()
        with self.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM devices WHERE id = ? AND revoked_at IS NULL", (device_id,)
            ).fetchone()
            if row is None:
                raise APIError(404, "device_not_found", "The paired device was not found.")
            connection.execute(
                "UPDATE devices SET token_hash = ?, last_seen_at = ? WHERE id = ?",
                (token_hash(token), timestamp, device_id),
            )
            updated = connection.execute(
                "SELECT * FROM devices WHERE id = ?", (device_id,)
            ).fetchone()
        return self._device(updated)

    @staticmethod
    def _device(row: sqlite3.Row, last_seen_at: Optional[float] = None) -> Dict[str, Any]:
        return {
            "id": row["id"],
            "name": row["name"],
            "createdAt": row["created_at"],
            "lastSeenAt": last_seen_at if last_seen_at is not None else row["last_seen_at"],
            "revoked": row["revoked_at"] is not None,
            "revokedAt": row["revoked_at"],
        }

    # Projects -----------------------------------------------------------------

    def create_project(self, name: str, root_path: str, canonical_path: str) -> Dict[str, Any]:
        project_id = new_id("project")
        timestamp = now()
        try:
            with self.transaction() as connection:
                connection.execute(
                    "INSERT INTO projects(id, name, root_path, canonical_path, created_at, updated_at) "
                    "VALUES(?, ?, ?, ?, ?, ?)",
                    (project_id, name, root_path, canonical_path, timestamp, timestamp),
                )
        except sqlite3.IntegrityError:
            raise APIError(
                409,
                "duplicate_project",
                "That canonical project root is already registered on this host.",
            )
        return self.get_project(project_id)

    def get_project(self, project_id: str) -> Dict[str, Any]:
        with self._lock:
            row = self._connection.execute(
                "SELECT p.*, pp.pet_id FROM projects p "
                "LEFT JOIN project_pets pp ON pp.project_id = p.id WHERE p.id = ?",
                (project_id,),
            ).fetchone()
        if row is None:
            raise APIError(404, "project_not_found", "The project was not found.")
        return self._project(row)

    def list_projects(self) -> List[Dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT p.*, pp.pet_id FROM projects p "
                "LEFT JOIN project_pets pp ON pp.project_id = p.id "
                "ORDER BY p.updated_at DESC, p.name COLLATE NOCASE"
            ).fetchall()
        return [self._project(row) for row in rows]

    def rename_project(self, project_id: str, name: str) -> Dict[str, Any]:
        with self.transaction() as connection:
            cursor = connection.execute(
                "UPDATE projects SET name = ?, updated_at = ? WHERE id = ?",
                (name, now(), project_id),
            )
            if cursor.rowcount != 1:
                raise APIError(404, "project_not_found", "The project was not found.")
        return self.get_project(project_id)

    def remove_project(self, project_id: str) -> Dict[str, Any]:
        project = self.get_project(project_id)
        with self.transaction() as connection:
            connection.execute("DELETE FROM projects WHERE id = ?", (project_id,))
        return project

    # First-page session catalog cache ---------------------------------------

    @staticmethod
    def _valid_session_catalog_payload(value: Any) -> bool:
        if not isinstance(value, dict) or set(value.keys()) != {"sessions", "nextCursor"}:
            return False
        sessions = value.get("sessions")
        cursor = value.get("nextCursor")
        if not isinstance(sessions, list) or len(sessions) > SESSION_CATALOG_CACHE_MAX_ITEMS:
            return False
        if cursor is not None and (not isinstance(cursor, str) or len(cursor) > 4_096):
            return False
        for session in sessions:
            if not isinstance(session, dict):
                return False
            if not set(session.keys()).issubset(SESSION_CATALOG_SESSION_KEYS):
                return False
            session_id = session.get("id")
            if not isinstance(session_id, str) or not session_id or len(session_id) > 256:
                return False
            if not isinstance(session.get("hostID"), str):
                return False
            if not isinstance(session.get("projectID"), str):
                return False
            if not isinstance(session.get("title"), str):
                return False
            if session.get("provider") != "codex" or not isinstance(session.get("archived"), bool):
                return False
            for key, item in session.items():
                if key == "archived":
                    continue
                if item is not None and not isinstance(item, (str, int, float, bool)):
                    return False
        return True

    def get_session_catalog_cache(self, project_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            row = self._connection.execute(
                "SELECT payload_json FROM session_catalog_cache WHERE project_id = ?",
                (project_id,),
            ).fetchone()
        if row is None:
            return None
        encoded = str(row["payload_json"])
        if len(encoded.encode("utf-8", errors="replace")) > SESSION_CATALOG_CACHE_MAX_BYTES:
            return None
        try:
            payload = json.loads(encoded)
        except (TypeError, ValueError):
            return None
        return payload if self._valid_session_catalog_payload(payload) else None

    def put_session_catalog_cache(
        self, project_id: str, payload: Dict[str, Any]
    ) -> bool:
        if not self._valid_session_catalog_payload(payload):
            raise ValueError("invalid session catalog cache payload")
        encoded = canonical_json(payload)
        if len(encoded.encode("utf-8")) > SESSION_CATALOG_CACHE_MAX_BYTES:
            raise ValueError("session catalog cache payload is too large")
        timestamp = now()
        with self.transaction() as connection:
            # Enforce the foreign key before reporting an unchanged write.
            if connection.execute(
                "SELECT 1 FROM projects WHERE id = ?", (project_id,)
            ).fetchone() is None:
                raise APIError(404, "project_not_found", "The project was not found.")
            existing = connection.execute(
                "SELECT payload_json FROM session_catalog_cache WHERE project_id = ?",
                (project_id,),
            ).fetchone()
            if existing is not None and str(existing["payload_json"]) == encoded:
                return False
            connection.execute(
                "INSERT INTO session_catalog_cache(project_id, payload_json, updated_at) "
                "VALUES(?, ?, ?) ON CONFLICT(project_id) DO UPDATE SET "
                "payload_json = excluded.payload_json, updated_at = excluded.updated_at",
                (project_id, encoded, timestamp),
            )
        return True

    def cached_current_session_id(self, project_id: str) -> Optional[str]:
        payload = self.get_session_catalog_cache(project_id)
        if payload is None or not payload["sessions"]:
            return None
        session_id = payload["sessions"][0].get("id")
        return session_id if isinstance(session_id, str) and session_id else None

    def cached_project_ids_for_session(self, session_id: str) -> List[str]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT project_id, payload_json FROM session_catalog_cache"
            ).fetchall()
        project_ids: List[str] = []
        for row in rows:
            encoded = str(row["payload_json"])
            if len(encoded.encode("utf-8", errors="replace")) > SESSION_CATALOG_CACHE_MAX_BYTES:
                continue
            try:
                payload = json.loads(encoded)
            except (TypeError, ValueError):
                continue
            if not self._valid_session_catalog_payload(payload):
                continue
            if any(item.get("id") == session_id for item in payload["sessions"]):
                project_ids.append(str(row["project_id"]))
        return project_ids

    @staticmethod
    def _project(row: sqlite3.Row) -> Dict[str, Any]:
        keys = set(row.keys())
        return {
            "id": row["id"],
            "name": row["name"],
            "rootPath": row["root_path"],
            "canonicalPath": row["canonical_path"],
            "petID": row["pet_id"] if "pet_id" in keys else None,
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        }

    # Session settings ---------------------------------------------------------

    def put_session_settings(
        self,
        session_id: str,
        project_id: str,
        access_level: str,
        model: Optional[str],
        reasoning_effort: Optional[str],
        service_tier: Optional[str],
    ) -> Dict[str, Any]:
        timestamp = now()
        with self.transaction() as connection:
            connection.execute(
                "INSERT INTO session_settings(session_id, project_id, access_level, model, "
                "reasoning_effort, service_tier, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(session_id) DO UPDATE SET project_id=excluded.project_id, "
                "access_level=excluded.access_level, model=excluded.model, "
                "reasoning_effort=excluded.reasoning_effort, service_tier=excluded.service_tier, "
                "updated_at=excluded.updated_at",
                (
                    session_id,
                    project_id,
                    access_level,
                    model,
                    reasoning_effort,
                    service_tier,
                    timestamp,
                ),
            )
        return self.get_session_settings(session_id) or {}

    def get_session_settings(self, session_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM session_settings WHERE session_id = ?", (session_id,)
            ).fetchone()
        if row is None:
            return None
        return {
            "sessionID": row["session_id"],
            "projectID": row["project_id"],
            "accessLevel": row["access_level"],
            "model": row["model"],
            "reasoningEffort": row["reasoning_effort"],
            "serviceTier": row["service_tier"],
            "updatedAt": row["updated_at"],
        }

    # Notes and todos ----------------------------------------------------------

    def create_note(
        self, project_id: str, session_id: Optional[str], title: str, markdown: str
    ) -> Dict[str, Any]:
        note_id = new_id("note")
        timestamp = now()
        with self.transaction() as connection:
            connection.execute(
                "INSERT INTO notes(id, project_id, session_id, title, markdown, revision, "
                "created_at, updated_at) VALUES(?, ?, ?, ?, ?, 1, ?, ?)",
                (note_id, project_id, session_id, title, markdown, timestamp, timestamp),
            )
        return self.get_note(note_id)

    def get_note(self, note_id: str) -> Dict[str, Any]:
        with self._lock:
            row = self._connection.execute("SELECT * FROM notes WHERE id = ?", (note_id,)).fetchone()
        if row is None:
            raise APIError(404, "note_not_found", "The note was not found.")
        return self._note(row)

    def list_notes(self, project_id: str) -> List[Dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT * FROM notes WHERE project_id = ? ORDER BY updated_at DESC", (project_id,)
            ).fetchall()
        return [self._note(row) for row in rows]

    def update_note(
        self, note_id: str, expected_revision: int, title: str, markdown: str
    ) -> Dict[str, Any]:
        with self.transaction() as connection:
            cursor = connection.execute(
                "UPDATE notes SET title = ?, markdown = ?, revision = revision + 1, updated_at = ? "
                "WHERE id = ? AND revision = ?",
                (title, markdown, now(), note_id, expected_revision),
            )
            if cursor.rowcount != 1:
                self._raise_revision(connection, "notes", note_id, "note_not_found")
        return self.get_note(note_id)

    def delete_note(self, note_id: str, expected_revision: int) -> Dict[str, Any]:
        note = self.get_note(note_id)
        with self.transaction() as connection:
            cursor = connection.execute(
                "DELETE FROM notes WHERE id = ? AND revision = ?", (note_id, expected_revision)
            )
            if cursor.rowcount != 1:
                self._raise_revision(connection, "notes", note_id, "note_not_found")
        return note

    @staticmethod
    def _note(row: sqlite3.Row) -> Dict[str, Any]:
        return {
            "id": row["id"],
            "projectID": row["project_id"],
            "sessionID": row["session_id"],
            "title": row["title"],
            "markdown": row["markdown"],
            "revision": row["revision"],
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        }

    def create_todo(
        self,
        project_id: str,
        session_id: Optional[str],
        text: str,
        completed: bool,
        position: Optional[int],
    ) -> Dict[str, Any]:
        todo_id = new_id("todo")
        timestamp = now()
        with self.transaction() as connection:
            if position is None:
                row = connection.execute(
                    "SELECT COALESCE(MAX(position), -1) + 1 AS next FROM todos WHERE project_id = ?",
                    (project_id,),
                ).fetchone()
                position = int(row["next"])
            connection.execute(
                "INSERT INTO todos(id, project_id, session_id, text, completed, position, "
                "revision, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?, 1, ?, ?)",
                (
                    todo_id,
                    project_id,
                    session_id,
                    text,
                    1 if completed else 0,
                    position,
                    timestamp,
                    timestamp,
                ),
            )
        return self.get_todo(todo_id)

    def get_todo(self, todo_id: str) -> Dict[str, Any]:
        with self._lock:
            row = self._connection.execute("SELECT * FROM todos WHERE id = ?", (todo_id,)).fetchone()
        if row is None:
            raise APIError(404, "todo_not_found", "The todo was not found.")
        return self._todo(row)

    def list_todos(self, project_id: str) -> List[Dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT * FROM todos WHERE project_id = ? ORDER BY position, created_at",
                (project_id,),
            ).fetchall()
        return [self._todo(row) for row in rows]

    def update_todo(
        self,
        todo_id: str,
        expected_revision: int,
        text: str,
        completed: bool,
        position: int,
    ) -> Dict[str, Any]:
        with self.transaction() as connection:
            cursor = connection.execute(
                "UPDATE todos SET text = ?, completed = ?, position = ?, "
                "revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ?",
                (text, 1 if completed else 0, position, now(), todo_id, expected_revision),
            )
            if cursor.rowcount != 1:
                self._raise_revision(connection, "todos", todo_id, "todo_not_found")
        return self.get_todo(todo_id)

    def delete_todo(self, todo_id: str, expected_revision: int) -> Dict[str, Any]:
        todo = self.get_todo(todo_id)
        with self.transaction() as connection:
            cursor = connection.execute(
                "DELETE FROM todos WHERE id = ? AND revision = ?", (todo_id, expected_revision)
            )
            if cursor.rowcount != 1:
                self._raise_revision(connection, "todos", todo_id, "todo_not_found")
        return todo

    @staticmethod
    def _todo(row: sqlite3.Row) -> Dict[str, Any]:
        return {
            "id": row["id"],
            "projectID": row["project_id"],
            "sessionID": row["session_id"],
            "text": row["text"],
            "completed": bool(row["completed"]),
            "position": row["position"],
            "revision": row["revision"],
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        }

    @staticmethod
    def _raise_revision(
        connection: sqlite3.Connection, table: str, resource_id: str, not_found_code: str
    ) -> None:
        row = connection.execute("SELECT revision FROM %s WHERE id = ?" % table, (resource_id,)).fetchone()
        if row is None:
            raise APIError(404, not_found_code, "The resource was not found.")
        raise APIError(
            412,
            "revision_conflict",
            "The resource changed on the host. Refresh before overwriting it.",
            {"currentRevision": row["revision"]},
        )

    # Pets ---------------------------------------------------------------------

    def add_pet(
        self,
        source_path: str,
        storage_path: str,
        display_name: str,
        description: str,
        sprite_version: int,
        manifest: Dict[str, Any],
        digest: str,
    ) -> Dict[str, Any]:
        pet_id = new_id("pet")
        try:
            with self.transaction() as connection:
                connection.execute(
                    "INSERT INTO pets(id, source_path, storage_path, display_name, description, "
                    "sprite_version, manifest_json, digest, created_at) "
                    "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        pet_id,
                        source_path,
                        storage_path,
                        display_name,
                        description,
                        sprite_version,
                        canonical_json(manifest),
                        digest,
                        now(),
                    ),
                )
        except sqlite3.IntegrityError:
            with self._lock:
                row = self._connection.execute(
                    "SELECT * FROM pets WHERE digest = ?", (digest,)
                ).fetchone()
            if row is None:
                raise
            return self._pet(row)
        return self.get_pet(pet_id)

    def get_pet(self, pet_id: str) -> Dict[str, Any]:
        with self._lock:
            row = self._connection.execute("SELECT * FROM pets WHERE id = ?", (pet_id,)).fetchone()
        if row is None:
            raise APIError(404, "pet_not_found", "The pet was not found.")
        return self._pet(row)

    def list_pets(self) -> List[Dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT * FROM pets ORDER BY display_name COLLATE NOCASE, created_at"
            ).fetchall()
        return [self._pet(row) for row in rows]

    def select_pet(self, project_id: str, pet_id: str) -> Dict[str, Any]:
        # Resolve both foreign keys into clear public errors before the upsert.
        self.get_project(project_id)
        self.get_pet(pet_id)
        with self.transaction() as connection:
            connection.execute(
                "INSERT INTO project_pets(project_id, pet_id, updated_at) VALUES(?, ?, ?) "
                "ON CONFLICT(project_id) DO UPDATE SET pet_id=excluded.pet_id, "
                "updated_at=excluded.updated_at",
                (project_id, pet_id, now()),
            )
        return self.get_project(project_id)

    @staticmethod
    def _pet(row: sqlite3.Row) -> Dict[str, Any]:
        return {
            "id": row["id"],
            "displayName": row["display_name"],
            "description": row["description"],
            "spriteVersionNumber": row["sprite_version"],
            "manifest": json.loads(row["manifest_json"]),
            "digest": row["digest"],
            "sourcePath": row["source_path"],
            "storagePath": row["storage_path"],
            "createdAt": row["created_at"],
        }

    # Durable events -----------------------------------------------------------

    def append_event(self, event_type: str, data: Dict[str, Any]) -> Dict[str, Any]:
        timestamp = now()
        payload = canonical_json(data)
        payload_bytes = len(payload.encode("utf-8"))
        if payload_bytes > self.event_payload_limit:
            data = {
                "_cofleetTruncated": True,
                "reason": "event_payload_limit",
                "originalBytes": payload_bytes,
            }
            payload = canonical_json(data)
        with self.transaction() as connection:
            cursor = connection.execute(
                "INSERT INTO event_log(event_type, data_json, created_at) VALUES(?, ?, ?)",
                (event_type, payload, timestamp),
            )
            event_id = int(cursor.lastrowid)
            cutoff = event_id - self.event_limit
            if cutoff > 0:
                connection.execute("DELETE FROM event_log WHERE id <= ?", (cutoff,))
            rows = connection.execute(
                "SELECT id, LENGTH(CAST(data_json AS BLOB)) AS bytes "
                "FROM event_log ORDER BY id DESC"
            ).fetchall()
            stored = 0
            delete_ids = []
            for row in rows:
                stored += int(row["bytes"])
                if stored > self.event_storage_limit:
                    delete_ids.append(int(row["id"]))
            if delete_ids:
                placeholders = ",".join("?" for _ in delete_ids)
                connection.execute(
                    "DELETE FROM event_log WHERE id IN (%s)" % placeholders,
                    tuple(delete_ids),
                )
        return {"id": event_id, "type": event_type, "data": data, "createdAt": timestamp}

    def events_after(self, event_id: int, limit: int = 200) -> Tuple[List[Dict[str, Any]], bool]:
        limit = max(1, min(limit, self.event_replay_limit))
        with self._lock:
            oldest = self._connection.execute("SELECT MIN(id) AS id FROM event_log").fetchone()["id"]
            rows = self._connection.execute(
                "SELECT * FROM event_log WHERE id > ? ORDER BY id LIMIT ?", (event_id, limit)
            ).fetchall()
        reset_required = oldest is not None and event_id > 0 and event_id < int(oldest) - 1
        events = []
        replay_bytes = 0
        for row in rows:
            encoded_bytes = len(str(row["data_json"]).encode("utf-8"))
            if replay_bytes + encoded_bytes > self.event_replay_bytes:
                break
            replay_bytes += encoded_bytes
            events.append(
                {
                    "id": row["id"],
                    "type": row["event_type"],
                    "data": json.loads(row["data_json"]),
                    "createdAt": row["created_at"],
                }
            )
        return events, reset_required

    def latest_event_id(self) -> int:
        with self._lock:
            value = self._connection.execute(
                "SELECT COALESCE(MAX(id), 0) AS id FROM event_log"
            ).fetchone()["id"]
        return int(value)

    # Idempotency --------------------------------------------------------------

    def claim_idempotency(
        self, scope: str, key: str, request_hash: str, ttl: int = 86_400
    ) -> Optional[Tuple[int, Dict[str, Any]]]:
        timestamp = now()
        with self.transaction() as connection:
            connection.execute("DELETE FROM idempotency WHERE expires_at <= ?", (timestamp,))
            row = connection.execute(
                "SELECT * FROM idempotency WHERE scope = ? AND key = ?", (scope, key)
            ).fetchone()
            if row is not None:
                if not secure_equal(str(row["request_hash"]), request_hash):
                    raise APIError(
                        409,
                        "idempotency_conflict",
                        "That idempotency key was used with a different request.",
                    )
                if row["response_json"] is None:
                    raise APIError(
                        409,
                        "idempotency_in_progress",
                        "The matching request is still in progress.",
                    )
                return int(row["status_code"]), json.loads(row["response_json"])
            connection.execute(
                "INSERT INTO idempotency(scope, key, request_hash, created_at, expires_at) "
                "VALUES(?, ?, ?, ?, ?)",
                (scope, key, request_hash, timestamp, timestamp + ttl),
            )
        return None

    def complete_idempotency(
        self, scope: str, key: str, status_code: int, response: Dict[str, Any]
    ) -> None:
        with self.transaction() as connection:
            connection.execute(
                "UPDATE idempotency SET status_code = ?, response_json = ? "
                "WHERE scope = ? AND key = ?",
                (status_code, canonical_json(response), scope, key),
            )

    def abandon_idempotency(self, scope: str, key: str) -> None:
        with self.transaction() as connection:
            connection.execute(
                "DELETE FROM idempotency WHERE scope = ? AND key = ? AND response_json IS NULL",
                (scope, key),
            )

    # Interactions -------------------------------------------------------------

    def create_interaction(
        self,
        rpc_id: Any,
        process_generation: str,
        method: str,
        params: Dict[str, Any],
        ttl: int,
    ) -> Dict[str, Any]:
        interaction_id = new_id("interaction")
        timestamp = now()
        session_id = params.get("threadId") if isinstance(params.get("threadId"), str) else None
        turn_id = params.get("turnId") if isinstance(params.get("turnId"), str) else None
        with self.transaction() as connection:
            connection.execute(
                "INSERT INTO interactions(id, session_id, turn_id, rpc_id_json, process_generation, method, "
                "params_json, state, expires_at, created_at) VALUES(?, ?, ?, ?, ?, ?, "
                "?, 'pending', ?, ?)",
                (
                    interaction_id,
                    session_id,
                    turn_id,
                    canonical_json(rpc_id),
                    process_generation,
                    method,
                    canonical_json(params),
                    timestamp + ttl,
                    timestamp,
                ),
            )
        return self.get_interaction(interaction_id)

    def get_interaction(self, interaction_id: str) -> Dict[str, Any]:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM interactions WHERE id = ?", (interaction_id,)
            ).fetchone()
        if row is None:
            raise APIError(404, "interaction_not_found", "The interaction was not found.")
        return self._interaction(row)

    def list_interactions(self, state: Optional[str] = "pending") -> List[Dict[str, Any]]:
        self.expire_interactions()
        with self._lock:
            if state:
                rows = self._connection.execute(
                    "SELECT * FROM interactions WHERE state = ? ORDER BY created_at", (state,)
                ).fetchall()
            else:
                rows = self._connection.execute(
                    "SELECT * FROM interactions ORDER BY created_at DESC LIMIT 200"
                ).fetchall()
        return [self._interaction(row) for row in rows]

    def expire_interactions(self) -> List[Dict[str, Any]]:
        timestamp = now()
        with self.transaction() as connection:
            rows = connection.execute(
                "SELECT * FROM interactions WHERE state = 'pending' AND expires_at <= ?",
                (timestamp,),
            ).fetchall()
            connection.execute(
                "UPDATE interactions SET state = 'expired', resolved_at = ? "
                "WHERE state = 'pending' AND expires_at <= ?",
                (timestamp, timestamp),
            )
        return [self._interaction(row, state="expired", resolved_at=timestamp) for row in rows]

    def claim_interaction(
        self, interaction_id: str, process_generation: Optional[str] = None
    ) -> Dict[str, Any]:
        timestamp = now()
        with self.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM interactions WHERE id = ?", (interaction_id,)
            ).fetchone()
            if row is None:
                raise APIError(404, "interaction_not_found", "The interaction was not found.")
            if row["state"] == "pending" and float(row["expires_at"]) <= timestamp:
                connection.execute(
                    "UPDATE interactions SET state = 'expired', resolved_at = ? WHERE id = ?",
                    (timestamp, interaction_id),
                )
                raise APIError(410, "interaction_expired", "The interaction has expired.")
            if row["state"] == "expired":
                raise APIError(410, "interaction_expired", "The interaction has expired.")
            if row["state"] != "pending":
                raise APIError(409, "interaction_resolved", "The interaction was already resolved.")
            if process_generation is None or row["process_generation"] != process_generation:
                connection.execute(
                    "UPDATE interactions SET state = 'expired', resolved_at = ? WHERE id = ?",
                    (timestamp, interaction_id),
                )
                raise APIError(
                    410,
                    "interaction_expired",
                    "The Codex process that requested this interaction has restarted.",
                )
            connection.execute(
                "UPDATE interactions SET state = 'resolving' WHERE id = ?", (interaction_id,)
            )
        return self._interaction(row, state="resolving")

    def finish_interaction(self, interaction_id: str, response: Dict[str, Any]) -> Dict[str, Any]:
        timestamp = now()
        with self.transaction() as connection:
            cursor = connection.execute(
                "UPDATE interactions SET state = 'resolved', response_json = ?, resolved_at = ? "
                "WHERE id = ? AND state = 'resolving'",
                (canonical_json(response), timestamp, interaction_id),
            )
            if cursor.rowcount != 1:
                raise APIError(409, "interaction_resolved", "The interaction was already resolved.")
        return self.get_interaction(interaction_id)

    def release_interaction(self, interaction_id: str) -> None:
        with self.transaction() as connection:
            connection.execute(
                "UPDATE interactions SET state = 'pending' WHERE id = ? AND state = 'resolving'",
                (interaction_id,),
            )

    def invalidate_pending_interactions(
        self, process_generation: Optional[str] = None
    ) -> List[Dict[str, Any]]:
        timestamp = now()
        with self.transaction() as connection:
            if process_generation is None:
                rows = connection.execute(
                    "SELECT * FROM interactions WHERE state IN ('pending', 'resolving')"
                ).fetchall()
                connection.execute(
                    "UPDATE interactions SET state = 'expired', resolved_at = ? "
                    "WHERE state IN ('pending', 'resolving')",
                    (timestamp,),
                )
            else:
                rows = connection.execute(
                    "SELECT * FROM interactions WHERE state IN ('pending', 'resolving') "
                    "AND process_generation = ?",
                    (process_generation,),
                ).fetchall()
                connection.execute(
                    "UPDATE interactions SET state = 'expired', resolved_at = ? "
                    "WHERE state IN ('pending', 'resolving') AND process_generation = ?",
                    (timestamp, process_generation),
                )
        return [self._interaction(row, state="expired", resolved_at=timestamp) for row in rows]

    @staticmethod
    def _interaction(
        row: sqlite3.Row,
        state: Optional[str] = None,
        resolved_at: Optional[float] = None,
    ) -> Dict[str, Any]:
        return {
            "id": row["id"],
            "sessionID": row["session_id"],
            "turnID": row["turn_id"],
            "method": row["method"],
            "params": json.loads(row["params_json"]),
            "state": state if state is not None else row["state"],
            "expiresAt": row["expires_at"],
            "createdAt": row["created_at"],
            "resolvedAt": resolved_at if resolved_at is not None else row["resolved_at"],
            "response": json.loads(row["response_json"]) if row["response_json"] else None,
            "_rpcID": json.loads(row["rpc_id_json"]),
            "_generation": row["process_generation"],
        }
