"""Provider-neutral CoFleet v1 service layer backed by Codex app-server."""

import json
import datetime
import os
import pathlib
import platform
import re
import socket
import subprocess
import shutil
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, Dict, List, Mapping, Optional, Tuple, Union
from urllib.parse import quote

from . import __version__
from .activity import CodexFilesystemActivityWatcher
from .codex import CodexAppServerSupervisor
from .config import HostConfig
from .database import Database
from .errors import APIError, CodexRPCError, CodexUnavailable
from .events import EventBroker
from .paths import canonical_directory, create_directory, list_directories
from .pet_catalogs import PetCatalogManager
from .pets import PetManager
from .tailscale import verify_private_serve
from .transcript import CodexRolloutTranscriptTail
from .util import (
    bounded_int,
    clean_pairing_code,
    json_hash,
    make_etag,
    new_id,
    now,
    pairing_code,
    parse_etag,
    random_token,
    require_string,
    bounded_json_value,
)


ACCESS_PROFILES: Dict[str, Dict[str, str]] = {
    "ask_for_approval": {
        "approvalPolicy": "untrusted",
        "approvalsReviewer": "user",
        "sandbox": "workspace-write",
    },
    "approve_for_me": {
        "approvalPolicy": "on-request",
        "approvalsReviewer": "auto_review",
        "sandbox": "workspace-write",
    },
    "full_access": {
        "approvalPolicy": "never",
        "approvalsReviewer": "user",
        "sandbox": "danger-full-access",
    },
}


# Thread creation and resumption accept the string-valued `sandbox` mode above,
# while turn/start accepts the structured `sandboxPolicy` union. Keep the
# public profiles in their stable, user-facing form and translate explicitly at
# the app-server boundary so every turn replaces the thread's previous policy.
TURN_SANDBOX_POLICIES: Dict[str, Dict[str, Any]] = {
    "workspace-write": {
        "type": "workspaceWrite",
        "networkAccess": False,
        "writableRoots": [],
    },
    "danger-full-access": {"type": "dangerFullAccess"},
}


CURRENT_CODEX_SOURCE_KINDS = [
    "cli",
    "vscode",
    "exec",
    "appServer",
    "subAgent",
    "subAgentReview",
    "subAgentCompact",
    "subAgentThreadSpawn",
    "subAgentOther",
    "unknown",
]
LEGACY_CODEX_SOURCE_KINDS = ["cli", "vscode", "appServer", "unknown"]


@dataclass
class ServiceResponse:
    status: int = 200
    payload: Optional[Dict[str, Any]] = None
    headers: Dict[str, str] = field(default_factory=dict)
    body: Optional[bytes] = None
    content_type: str = "application/json; charset=utf-8"


@dataclass
class SSERequest:
    after_id: int
    once: bool = False
    session_id: Optional[str] = None


DispatchResult = Union[ServiceResponse, SSERequest]


class CoFleetHostService:
    def __init__(
        self,
        config: HostConfig,
        database: Optional[Database] = None,
        codex: Optional[CodexAppServerSupervisor] = None,
        start_maintenance: bool = True,
        invalidate_pending_interactions_on_start: bool = True,
        private_serve_verifier=verify_private_serve,
        desktop_opener=None,
        filesystem_watcher_factory=None,
        pet_catalog_manager=None,
    ) -> None:
        self.config = config.validate()
        self.private_serve_status = None
        if self.config.require_private_tailscale:
            self.private_serve_status = private_serve_verifier(self.config.port)
        self.database = database or Database(
            config.database_path,
            config.event_limit,
            config.event_payload_limit,
            config.event_storage_limit,
            config.event_replay_limit,
            config.event_replay_bytes,
        )
        self.events = EventBroker(self.database)
        self.codex = codex or CodexAppServerSupervisor(
            command=config.codex_command,
            timeout=config.rpc_timeout,
            notification_handler=self._on_codex_notification,
            interaction_handler=self._on_codex_interaction,
            max_concurrent_requests=config.max_concurrent_codex_rpcs,
        )
        # Supplied fakes can expose assignable handlers too.
        if codex is not None:
            if hasattr(codex, "notification_handler"):
                codex.notification_handler = self._on_codex_notification
            if hasattr(codex, "interaction_handler"):
                codex.interaction_handler = self._on_codex_interaction
        self.desktop_opener = desktop_opener or self._open_codex_thread
        self._transcript_tail = CodexRolloutTranscriptTail(self.config.codex_state_path)
        self.pets = PetManager(config, self.database)
        self.pet_catalogs = pet_catalog_manager or PetCatalogManager(self.pets)
        self.host_id = self.database.host_id()
        if invalidate_pending_interactions_on_start:
            stale_interactions = self.database.invalidate_pending_interactions()
            if stale_interactions:
                self.events.publish(
                    "interaction.invalidated",
                    {"count": len(stale_interactions), "reason": "host_restart"},
                )
        self._closed = threading.Event()
        self._session_catalog_condition = threading.Condition()
        self._session_catalog_lifecycle_lock = threading.Lock()
        self._session_catalog_refreshing: set[str] = set()
        self._session_catalog_refresh_again: set[str] = set()
        self._session_catalog_executor = ThreadPoolExecutor(
            max_workers=4, thread_name_prefix="cofleet-session-catalog"
        )
        self._background_maintenance_enabled = start_maintenance
        self._codex_source_kinds = list(CURRENT_CODEX_SOURCE_KINDS)
        self._codex_source_kinds_lock = threading.Lock()
        self._external_activity_condition = threading.Condition()
        self._external_activity_deadlines: Dict[str, float] = {}
        self._external_activity_attempts: Dict[str, int] = {}
        self._external_activity_inflight: set[str] = set()
        self._external_activity_states: Dict[Tuple[str, str], Tuple[str, Optional[str], Optional[str]]] = {}
        self._external_turn_fingerprints: Dict[Tuple[str, str], str] = {}
        self._external_item_fingerprints: Dict[Tuple[str, str, str], str] = {}
        self._native_activity_at: Dict[str, float] = {}
        self._external_activity_last_seen: Dict[str, float] = {}
        self._external_stale_followups: Dict[str, int] = {}
        self._external_activity_executor = ThreadPoolExecutor(
            max_workers=2, thread_name_prefix="cofleet-desktop-reconcile"
        )
        self._external_activity_thread: Optional[threading.Thread] = None
        self._filesystem_activity_watcher = None
        self._pairing_attempts: List[float] = []
        self._pairing_lock = threading.Lock()
        self._interaction_lock = threading.Lock()
        self._session_resume_lock = threading.Lock()
        self._resumed_session_generations: Dict[str, str] = {}
        self._stream_lock = threading.Lock()
        self._stream_items: Dict[Tuple[str, str, str], Dict[str, Any]] = {}
        self._turn_started_at: Dict[Tuple[str, str], float] = {}
        self._source_cache: Dict[str, Tuple[float, Dict[str, Any]]] = {}
        self._source_lock = threading.Lock()
        if start_maintenance:
            self._external_activity_thread = threading.Thread(
                target=self._external_activity_loop,
                name="cofleet-desktop-activity-debounce",
                daemon=True,
            )
            self._external_activity_thread.start()
            watcher_factory = filesystem_watcher_factory or CodexFilesystemActivityWatcher
            try:
                self._filesystem_activity_watcher = watcher_factory(
                    (
                        self.config.codex_state_path / "sessions",
                        self.config.codex_state_path / "archived_sessions",
                    ),
                    self._on_codex_filesystem_activity,
                )
            except Exception:
                # Live app-server events remain fully functional when a host OS
                # cannot grant filesystem notification access.
                self._filesystem_activity_watcher = None
            if self._filesystem_activity_watcher is not None:
                for project in self.database.list_projects():
                    cached = self.database.get_session_catalog_cache(project["id"])
                    if cached is not None:
                        for session in cached["sessions"]:
                            self._track_session_id(session.get("id"))
            # Start and warm Codex before an iPhone/Watch asks for its first catalog.
            # `thread/list` is metadata-only and primes the app-server's task index;
            # failures are intentionally silent because normal requests retain their
            # structured retry/error behavior.
            threading.Thread(target=self._warm_codex_catalog, daemon=True).start()
            threading.Thread(target=self._maintenance_loop, daemon=True).start()

    def close(self) -> None:
        self._closed.set()
        watcher = self._filesystem_activity_watcher
        if watcher is not None:
            watcher.close()
        with self._external_activity_condition:
            self._external_activity_condition.notify_all()
        activity_thread = self._external_activity_thread
        if activity_thread is not None and activity_thread is not threading.current_thread():
            activity_thread.join(timeout=2.0)
        with self._session_catalog_condition:
            self._session_catalog_condition.notify_all()
        self.codex.close()
        self._external_activity_executor.shutdown(wait=True, cancel_futures=True)
        self._session_catalog_executor.shutdown(wait=False, cancel_futures=True)
        # A refresh never holds this lock while waiting for Codex. Closing the
        # supervisor first wakes real app-server requests, while the lock keeps
        # a completed daemon refresh from racing SQLite shutdown.
        with self._session_catalog_lifecycle_lock:
            self.database.close()

    def _warm_codex_catalog(self) -> None:
        # Warm each registered project into durable storage. Unlike the old
        # one-item global probe, these results are retained and immediately
        # useful to a newly launched Apple client.
        try:
            projects = self.database.list_projects()
        except Exception:
            return
        for project in projects:
            self._schedule_session_catalog_refresh(project["id"])

    def _schedule_session_catalog_refresh(
        self, project_id: str, force_followup: bool = False
    ) -> bool:
        if self._closed.is_set():
            return False
        with self._session_catalog_condition:
            if project_id in self._session_catalog_refreshing:
                if force_followup:
                    self._session_catalog_refresh_again.add(project_id)
                return False
            self._session_catalog_refreshing.add(project_id)
        try:
            self._session_catalog_executor.submit(
                self._session_catalog_refresh_worker, project_id
            )
        except Exception:
            with self._session_catalog_condition:
                self._session_catalog_refreshing.discard(project_id)
                self._session_catalog_condition.notify_all()
            return False
        return True

    def _schedule_session_catalog_after_mutation(self, project_id: str) -> bool:
        if not self._background_maintenance_enabled:
            return False
        return self._schedule_session_catalog_refresh(project_id, force_followup=True)

    def _session_catalog_refresh_worker(self, project_id: str) -> None:
        while not self._closed.is_set():
            try:
                self._refresh_session_catalog(project_id)
            except Exception:
                # The persisted snapshot remains valid during a Codex outage.
                pass
            with self._session_catalog_condition:
                if (
                    project_id in self._session_catalog_refresh_again
                    and not self._closed.is_set()
                ):
                    self._session_catalog_refresh_again.discard(project_id)
                    continue
                self._session_catalog_refresh_again.discard(project_id)
                self._session_catalog_refreshing.discard(project_id)
                self._session_catalog_condition.notify_all()
                return
        with self._session_catalog_condition:
            self._session_catalog_refresh_again.discard(project_id)
            self._session_catalog_refreshing.discard(project_id)
            self._session_catalog_condition.notify_all()

    # Authentication and pairing ---------------------------------------------

    def authenticate(self, authorization: Optional[str]) -> Dict[str, Any]:
        if not authorization or not authorization.startswith("Bearer "):
            raise APIError(401, "authentication_required", "A paired-device bearer token is required.")
        token = authorization[7:].strip()
        device = self.database.authenticate(token)
        if device is None:
            raise APIError(401, "invalid_token", "The paired-device token is invalid or revoked.")
        return device

    def stream_token_is_active(self, authorization: Optional[str]) -> bool:
        if not authorization or not authorization.startswith("Bearer "):
            return False
        return self.database.token_is_active(authorization[7:].strip())

    def create_pairing_code(self, created_by: Optional[str] = None) -> Dict[str, Any]:
        code = pairing_code()
        expires_at = now() + 600
        self.database.create_pairing(code, expires_at, created_by)
        self.events.publish("pairing.created", {"expiresAt": expires_at})
        return {"code": code, "expiresAt": expires_at}

    def redeem_pairing(self, body: Dict[str, Any]) -> Dict[str, Any]:
        self._check_pairing_rate()
        code = clean_pairing_code(require_string(body.get("code"), "code", 6, 32))
        name = require_string(body.get("deviceName"), "deviceName", 1, 80)
        token = random_token()
        device = self.database.redeem_pairing(code, name, token)
        self.events.publish("device.paired", {"device": device})
        return {"device": device, "token": token, "host": self.host_info()}

    def _check_pairing_rate(self) -> None:
        timestamp = now()
        with self._pairing_lock:
            self._pairing_attempts = [value for value in self._pairing_attempts if value > timestamp - 60]
            if len(self._pairing_attempts) >= 12:
                raise APIError(429, "pairing_rate_limited", "Too many pairing attempts; wait one minute.")
            self._pairing_attempts.append(timestamp)

    # Public dispatch ----------------------------------------------------------

    def dispatch(
        self,
        method: str,
        path: str,
        query: Mapping[str, str],
        headers: Mapping[str, str],
        body: Optional[Dict[str, Any]],
        device: Optional[Dict[str, Any]],
    ) -> DispatchResult:
        method = method.upper()
        segments = [segment for segment in path.split("/") if segment]
        body = body or {}

        if method == "GET" and segments == ["v1", "health"]:
            return ServiceResponse(payload={"ok": True, "service": "cofleet-host", "version": __version__})
        if method == "POST" and segments == ["v1", "pairings", "redeem"]:
            return ServiceResponse(status=201, payload=self.redeem_pairing(body))
        if device is None:
            raise APIError(401, "authentication_required", "Pair this device before using CoFleet.")

        if method == "GET" and segments == ["v1", "host"]:
            return ServiceResponse(payload={"host": self.host_info()})
        if method == "GET" and segments == ["v1", "permission-profiles"]:
            return ServiceResponse(payload={"permissionProfiles": self.permission_profiles()})
        if method == "POST" and segments == ["v1", "pairings"]:
            return ServiceResponse(status=201, payload=self.create_pairing_code(device["id"]))
        if method == "GET" and segments == ["v1", "devices"]:
            return ServiceResponse(payload={"devices": self.database.list_devices()})
        if len(segments) == 4 and segments[:2] == ["v1", "devices"]:
            return self._dispatch_device(method, segments[2], segments[3], device)
        if len(segments) == 3 and segments[:2] == ["v1", "devices"] and method == "DELETE":
            if segments[2] != device["id"]:
                raise APIError(403, "device_scope", "A device may only revoke its own token in v1.")
            revoked = self.database.revoke_device(segments[2])
            self.events.publish("device.revoked", {"deviceID": segments[2]})
            return ServiceResponse(payload={"device": revoked})

        if method == "GET" and segments == ["v1", "account"]:
            return ServiceResponse(payload={"account": self.codex.request("account/read", {"refreshToken": False})})
        if method == "GET" and segments == ["v1", "account", "limits"]:
            result = self.codex.request("account/rateLimits/read", {})
            bounded = bounded_json_value(result)
            return ServiceResponse(
                payload={
                    "limits": bounded if isinstance(bounded, dict) else {"_cofleetTruncated": True}
                }
            )
        if method == "POST" and segments == ["v1", "account", "login"]:
            login_type = body.get("type", "chatgpt")
            if login_type not in ("chatgpt", "chatgptDeviceCode"):
                raise APIError(422, "unsupported_login", "Use ChatGPT browser or device-code login.")
            params: Dict[str, Any] = {"type": login_type}
            if login_type == "chatgpt":
                params.update(
                    {
                        "appBrand": "codex",
                        "codexStreamlinedLogin": True,
                        "useHostedLoginSuccessPage": True,
                    }
                )
            return ServiceResponse(payload={"login": self.codex.request("account/login/start", params)})
        if method == "GET" and segments == ["v1", "models"]:
            result = self.codex.request("model/list", {"limit": 100, "includeHidden": False})
            return ServiceResponse(payload={"models": self._normalize_models(result)})

        if method == "GET" and segments == ["v1", "directories"]:
            raw_path = query.get("path") or str(self.config.home)
            page = list_directories(
                raw_path,
                query.get("cursor"),
                bounded_int(query.get("limit"), "limit", 100, 1, 200),
                query.get("showHidden", "false").lower() == "true",
            )
            return ServiceResponse(payload=page)
        if method == "POST" and segments == ["v1", "directories"]:
            created = create_directory(body.get("parentPath"), body.get("name"))
            self.events.publish("directory.created", {"canonicalPath": created["canonicalPath"]})
            return ServiceResponse(status=201, payload={"directory": created})

        if segments == ["v1", "projects"]:
            return self._dispatch_projects(method, query, body)
        if segments == ["v1", "projects", "suggestions"] and method == "GET":
            return self._project_suggestions(query)
        if len(segments) >= 3 and segments[:2] == ["v1", "projects"]:
            return self._dispatch_project(method, segments[2:], query, headers, body)

        if segments == ["v1", "sessions"] and method == "POST":
            return self._create_session(body)
        if len(segments) >= 3 and segments[:2] == ["v1", "sessions"]:
            return self._dispatch_session(method, segments[2:], query, headers, body)

        if segments == ["v1", "interactions"] and method == "GET":
            state = query.get("state", "pending")
            if state not in ("pending", "resolved", "expired", ""):
                raise APIError(422, "invalid_state", "The interaction state is invalid.")
            interactions = [self._public_interaction(item) for item in self.database.list_interactions(state or None)]
            return ServiceResponse(payload={"interactions": interactions})
        if (
            len(segments) == 4
            and segments[:2] == ["v1", "interactions"]
            and segments[3] == "resolve"
            and method == "POST"
        ):
            return self._resolve_interaction(segments[2], body)

        if len(segments) == 3 and segments[:2] == ["v1", "notes"]:
            return self._dispatch_note(method, segments[2], headers, body)
        if len(segments) == 3 and segments[:2] == ["v1", "todos"]:
            return self._dispatch_todo(method, segments[2], headers, body)

        if segments == ["v1", "pets"]:
            if method == "GET":
                return ServiceResponse(payload={"pets": self.database.list_pets()})
            if method == "POST":
                pet = self.pets.import_package(body.get("sourcePath"))
                self.events.publish("pet.imported", {"pet": pet})
                return ServiceResponse(status=201, payload={"pet": pet})
        if segments == ["v1", "pets", "discover"] and method == "GET":
            return ServiceResponse(payload={"pets": self.pets.discover()})
        if len(segments) == 5 and segments[:2] == ["v1", "pets"] and segments[3] == "assets" and method == "GET":
            content_type, data = self.pets.asset(segments[2], segments[4])
            return ServiceResponse(body=data, content_type=content_type)
        if segments == ["v1", "pet-catalogs"] and method == "GET":
            return ServiceResponse(payload={"catalogs": self.pet_catalogs.list_catalogs()})
        if len(segments) == 4 and segments[:2] == ["v1", "pet-catalogs"] and segments[3] == "pets" and method == "GET":
            return ServiceResponse(payload=self.pet_catalogs.page(
                segments[2],
                query=query.get("query", ""),
                cursor=query.get("cursor"),
                limit=bounded_int(query.get("limit"), "limit", 40, 1, 60),
            ))
        if (
            len(segments) == 6
            and segments[:2] == ["v1", "pet-catalogs"]
            and segments[3] == "pets"
            and segments[5] == "install"
            and method == "POST"
        ):
            pet = self.pet_catalogs.install(segments[2], segments[4])
            self.events.publish("pet.imported", {"pet": pet, "catalogID": segments[2]})
            return ServiceResponse(status=201, payload={"pet": pet})

        if segments == ["v1", "events"] and method == "GET":
            return self._sse_request(query, headers, None)
        raise APIError(404, "route_not_found", "That CoFleet host endpoint does not exist.")

    def _dispatch_device(
        self, method: str, device_id: str, action: str, device: Dict[str, Any]
    ) -> ServiceResponse:
        if method != "POST" or action != "rotate":
            raise APIError(404, "route_not_found", "That device endpoint does not exist.")
        if device_id != device["id"]:
            raise APIError(403, "device_scope", "A device may only rotate its own token.")
        token = random_token()
        rotated = self.database.rotate_device(device_id, token)
        self.events.publish("device.rotated", {"deviceID": device_id})
        return ServiceResponse(payload={"device": rotated, "token": token})

    # Host and projects --------------------------------------------------------

    def host_info(self) -> Dict[str, Any]:
        return {
            "id": self.host_id,
            "displayName": self.config.display_name or socket.gethostname().split(".")[0],
            "platform": platform.system().lower(),
            "platformVersion": platform.release(),
            "architecture": platform.machine(),
            "homePath": str(canonical_directory(str(self.config.home))),
            "serviceVersion": __version__,
            "codexAvailable": self.codex.available(),
            "transport": "tailscale-serve" if self.config.require_private_tailscale else "loopback",
            "publicExposureAllowed": False,
            "capabilities": {
                "projects": True,
                "folderCreation": True,
                "sessions": True,
                "streaming": True,
                "interactions": True,
                "notes": True,
                "todos": True,
                "pets": True,
                "codexDesktopOpen": (
                    platform.system() == "Darwin" and shutil.which("open") is not None
                ),
                "sourceControl": ["git", "plastic"],
            },
        }

    @staticmethod
    def permission_profiles() -> List[Dict[str, Any]]:
        labels = {
            "ask_for_approval": ("Ask for approval", False),
            "approve_for_me": ("Approve for me", False),
            "full_access": ("Full access", True),
        }
        return [
            {"id": key, "label": labels[key][0], "dangerous": labels[key][1], **value}
            for key, value in ACCESS_PROFILES.items()
        ]

    def _codex_thread_list(self, params: Mapping[str, Any]) -> Dict[str, Any]:
        """List all current Codex source variants with an old-server fallback."""

        with self._codex_source_kinds_lock:
            source_kinds = list(self._codex_source_kinds)
        request = dict(params)
        request["sourceKinds"] = source_kinds
        try:
            return self.codex.request("thread/list", request)
        except CodexRPCError as error:
            if source_kinds == LEGACY_CODEX_SOURCE_KINDS:
                raise
            rpc_code = error.details.get("rpcCode")
            if rpc_code not in (None, -32602) and "source" not in error.message.lower():
                raise
            with self._codex_source_kinds_lock:
                self._codex_source_kinds = list(LEGACY_CODEX_SOURCE_KINDS)
            fallback = dict(params)
            fallback["sourceKinds"] = list(LEGACY_CODEX_SOURCE_KINDS)
            return self.codex.request("thread/list", fallback)

    def _dispatch_projects(
        self, method: str, query: Mapping[str, str], body: Dict[str, Any]
    ) -> ServiceResponse:
        if method == "GET":
            projects = self.database.list_projects()
            # Source-control discovery is bounded and only runs when a client
            # explicitly refreshes the catalog. A small worker cap prevents a
            # slow repository from serially delaying every other project.
            if len(projects) > 1:
                with ThreadPoolExecutor(max_workers=min(4, len(projects))) as executor:
                    projects = list(executor.map(self._project_with_source_control, projects))
            else:
                projects = [self._project_with_source_control(project) for project in projects]
            return ServiceResponse(payload={"projects": projects})
        if method != "POST":
            raise APIError(405, "method_not_allowed", "That method is not allowed.")
        canonical = canonical_directory(body.get("rootPath"))
        name_value = body.get("name") or canonical.name or str(canonical)
        name = require_string(name_value, "name", 1, 120)
        project = self._project_with_source_control(
            self.database.create_project(name, str(canonical), str(canonical))
        )
        self.events.publish("project.created", {"project": project})
        self._schedule_session_catalog_after_mutation(project["id"])
        return ServiceResponse(status=201, payload={"project": project})

    def _dispatch_project(
        self,
        method: str,
        rest: List[str],
        query: Mapping[str, str],
        headers: Mapping[str, str],
        body: Dict[str, Any],
    ) -> DispatchResult:
        project_id = rest[0]
        if len(rest) == 1:
            if method == "GET":
                project = self._project_with_source_control(self.database.get_project(project_id))
                return ServiceResponse(payload={"project": project})
            if method == "PATCH":
                name = require_string(body.get("name"), "name", 1, 120)
                project = self._project_with_source_control(
                    self.database.rename_project(project_id, name)
                )
                self.events.publish("project.updated", {"project": project})
                return ServiceResponse(payload={"project": project})
            if method == "DELETE":
                project = self.database.remove_project(project_id)
                self.events.publish("project.removed", {"projectID": project_id})
                return ServiceResponse(payload={"project": project, "directoryDeleted": False})
        if len(rest) == 2 and rest[1] == "sessions" and method == "GET":
            return self._project_sessions(project_id, query)
        if len(rest) == 2 and rest[1] == "source-control" and method == "GET":
            return ServiceResponse(payload={"sourceControl": self.source_control(project_id)})
        if len(rest) == 2 and rest[1] in ("notes", "note"):
            return self._project_notes(project_id, rest[1], method, headers, body)
        if len(rest) == 2 and rest[1] == "todos":
            return self._project_todos(project_id, method, body)
        if len(rest) == 2 and rest[1] == "pet" and method == "PUT":
            pet_id = require_string(body.get("petID"), "petID", 1, 128)
            project = self._project_with_source_control(
                self.database.select_pet(project_id, pet_id)
            )
            self.events.publish("project.petChanged", {"projectID": project_id, "petID": pet_id})
            return ServiceResponse(payload={"project": project})
        raise APIError(404, "route_not_found", "That project endpoint does not exist.")

    def _project_suggestions(self, query: Mapping[str, str]) -> ServiceResponse:
        limit = bounded_int(query.get("limit"), "limit", 20, 1, 50)
        params: Dict[str, Any] = {
            "limit": limit,
            "sortKey": "recency_at",
            "sortDirection": "desc",
            "archived": False,
        }
        if query.get("cursor"):
            params["cursor"] = query["cursor"]
        result = self._codex_thread_list(params)
        roots: Dict[str, Dict[str, Any]] = {}
        for thread in result.get("data", []):
            if not isinstance(thread, dict) or not isinstance(thread.get("cwd"), str):
                continue
            try:
                canonical = str(canonical_directory(thread["cwd"]))
            except APIError:
                continue
            existing = roots.get(canonical)
            updated = thread.get("updatedAt", thread.get("createdAt", 0))
            if existing is None or updated > existing["lastActivityAt"]:
                roots[canonical] = {
                    "rootPath": canonical,
                    "name": pathlib.Path(canonical).name or canonical,
                    "lastActivityAt": updated,
                    "latestSession": self._normalize_session(thread),
                }
        suggestions = sorted(roots.values(), key=lambda row: row["lastActivityAt"], reverse=True)
        return ServiceResponse(
            payload={"suggestions": suggestions, "nextCursor": result.get("nextCursor")}
        )

    # Sessions and turns -------------------------------------------------------

    def _project_sessions(self, project_id: str, query: Mapping[str, str]) -> ServiceResponse:
        limit = bounded_int(query.get("limit"), "limit", 5, 1, 50)
        archived = query.get("archived", "false").lower() == "true"
        # CoFleet's primary surface is exactly the newest five active tasks.
        # Return that durable snapshot without touching app-server, then refresh
        # it once in the background. Cursor and archived pages remain canonical
        # live reads because they cannot share the first-page cursor safely.
        if limit == 5 and not archived and not query.get("cursor"):
            cached = self.database.get_session_catalog_cache(project_id)
            if cached is not None:
                self._schedule_session_catalog_refresh(project_id)
                return ServiceResponse(payload=cached)
            return ServiceResponse(
                payload=self._load_session_catalog_on_cache_miss(project_id)
            )

        project = self.database.get_project(project_id)
        params: Dict[str, Any] = {
            "cwd": project["canonicalPath"],
            "limit": limit,
            "sortKey": "recency_at",
            "sortDirection": "desc",
            "archived": archived,
        }
        if query.get("cursor"):
            params["cursor"] = query["cursor"]
        result = self._codex_thread_list(params)
        sessions = [
            self._normalize_session(row, project_id)
            for row in result.get("data", [])
            if isinstance(row, dict)
        ]
        return ServiceResponse(payload={"sessions": sessions, "nextCursor": result.get("nextCursor")})

    @staticmethod
    def _cache_text(value: Any, maximum_bytes: int) -> Optional[str]:
        if not isinstance(value, str):
            return None
        encoded = value.encode("utf-8", errors="replace")
        if len(encoded) <= maximum_bytes:
            return value
        return encoded[:maximum_bytes].decode("utf-8", errors="ignore") + "…"

    def _session_catalog_payload(
        self, project_id: str, result: Mapping[str, Any]
    ) -> Dict[str, Any]:
        sessions: List[Dict[str, Any]] = []
        raw_data = result.get("data", [])
        if not isinstance(raw_data, list):
            raw_data = []
        for row in raw_data:
            if len(sessions) >= 5:
                break
            if not isinstance(row, dict):
                continue
            session = self._normalize_session(row, project_id)
            session_id = self._cache_text(session.get("id"), 256)
            if not session_id or session_id != session.get("id"):
                continue
            sessions.append(
                {
                    "id": session_id,
                    "hostID": self._cache_text(session.get("hostID"), 256) or self.host_id,
                    "projectID": project_id,
                    "title": self._cache_text(session.get("title"), 2_000) or "Untitled task",
                    "cwd": self._cache_text(session.get("cwd"), 8_192),
                    "preview": self._cache_text(session.get("preview"), 12_000),
                    "createdAt": session.get("createdAt")
                    if isinstance(session.get("createdAt"), (str, int, float))
                    else None,
                    "updatedAt": session.get("updatedAt")
                    if isinstance(session.get("updatedAt"), (str, int, float))
                    else None,
                    "archived": False,
                    "model": self._cache_text(session.get("model"), 1_000),
                    "accessLevel": self._cache_text(session.get("accessLevel"), 128),
                    "reasoningEffort": self._cache_text(
                        session.get("reasoningEffort"), 128
                    ),
                    "serviceTier": self._cache_text(session.get("serviceTier"), 128),
                    "provider": "codex",
                }
            )
        cursor = result.get("nextCursor")
        if not isinstance(cursor, str) or len(cursor) > 4_096:
            cursor = None
        return {"sessions": sessions, "nextCursor": cursor}

    def _load_session_catalog(self, project_id: str) -> Dict[str, Any]:
        with self._session_catalog_lifecycle_lock:
            if self._closed.is_set():
                raise CodexUnavailable("CoFleet host is shutting down.")
            project = self.database.get_project(project_id)
        result = self._codex_thread_list(
            {
                "cwd": project["canonicalPath"],
                "limit": 5,
                "sortKey": "recency_at",
                "sortDirection": "desc",
                "archived": False,
            }
        )
        if not isinstance(result, dict):
            raise CodexUnavailable("Codex returned an invalid session catalog.")
        return self._session_catalog_payload(project_id, result)

    def _load_session_catalog_on_cache_miss(
        self, project_id: str
    ) -> Dict[str, Any]:
        deadline = time.monotonic() + self.config.rpc_timeout + 5.0
        while not self._closed.is_set():
            owns_refresh = False
            with self._session_catalog_condition:
                if project_id not in self._session_catalog_refreshing:
                    self._session_catalog_refreshing.add(project_id)
                    owns_refresh = True
                else:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise CodexUnavailable(
                            "Codex is still loading this project's task catalog."
                        )
                    self._session_catalog_condition.wait(timeout=remaining)

            if not owns_refresh:
                cached = self.database.get_session_catalog_cache(project_id)
                if cached is not None:
                    return cached
                continue

            try:
                payload = self._load_session_catalog(project_id)
                self._store_session_catalog(project_id, payload)
                return payload
            finally:
                with self._session_catalog_condition:
                    self._session_catalog_refreshing.discard(project_id)
                    followup = project_id in self._session_catalog_refresh_again
                    self._session_catalog_refresh_again.discard(project_id)
                    self._session_catalog_condition.notify_all()
                if followup and not self._closed.is_set():
                    self._schedule_session_catalog_refresh(project_id)
        raise CodexUnavailable("CoFleet host is shutting down.")

    def _store_session_catalog(
        self, project_id: str, payload: Dict[str, Any]
    ) -> bool:
        with self._session_catalog_lifecycle_lock:
            if self._closed.is_set():
                return False
            changed = self.database.put_session_catalog_cache(project_id, payload)
            for session in payload["sessions"]:
                self._track_session_id(session.get("id"))
            if changed:
                self.events.publish(
                    "session.catalogUpdated",
                    {
                        "projectID": project_id,
                        "currentSessionID": payload["sessions"][0]["id"]
                        if payload["sessions"]
                        else None,
                    },
                )
            return changed

    def _refresh_session_catalog(self, project_id: str) -> bool:
        payload = self._load_session_catalog(project_id)
        return self._store_session_catalog(project_id, payload)

    def _project_ids_for_session(self, session_id: str) -> List[str]:
        project_ids: List[str] = []
        settings = self.database.get_session_settings(session_id)
        if settings is not None:
            project_ids.append(settings["projectID"])
        for project_id in self.database.cached_project_ids_for_session(session_id):
            if project_id not in project_ids:
                project_ids.append(project_id)
        if project_ids:
            self._track_session_id(session_id)
        return project_ids

    def _track_session_id(self, session_id: Any) -> None:
        watcher = self._filesystem_activity_watcher
        if (
            watcher is not None
            and isinstance(session_id, str)
            and hasattr(watcher, "track")
        ):
            watcher.track(session_id)

    def _schedule_session_catalog_for_session(self, session_id: str) -> None:
        if not self._background_maintenance_enabled:
            return
        for project_id in self._project_ids_for_session(session_id):
            self._schedule_session_catalog_refresh(project_id, force_followup=True)

    def _project_ids_for_thread(self, thread: Mapping[str, Any]) -> List[str]:
        session_id = thread.get("id")
        project_ids = (
            self._project_ids_for_session(session_id)
            if isinstance(session_id, str) and session_id
            else []
        )
        cwd = thread.get("cwd")
        if not isinstance(cwd, str) or not cwd:
            return project_ids
        try:
            canonical_cwd = os.path.realpath(os.path.abspath(os.path.expanduser(cwd)))
        except (OSError, ValueError):
            return project_ids
        matches: List[Tuple[int, str]] = []
        for project in self.database.list_projects():
            root = project.get("canonicalPath")
            if not isinstance(root, str) or not root:
                continue
            canonical_root = os.path.realpath(root)
            try:
                belongs = os.path.commonpath((canonical_root, canonical_cwd)) == canonical_root
            except ValueError:
                belongs = False
            if belongs:
                matches.append((len(canonical_root), project["id"]))
        # A nested registered project is more specific than its parent.
        matches.sort(reverse=True)
        if matches and matches[0][1] not in project_ids:
            project_ids.insert(0, matches[0][1])
        return project_ids

    def _merge_session_catalog_thread(
        self, project_id: str, thread: Mapping[str, Any]
    ) -> bool:
        if thread.get("archived") is True:
            return False
        candidate = self._session_catalog_payload(
            project_id, {"data": [dict(thread)], "nextCursor": None}
        )["sessions"]
        if not candidate:
            return False
        current = self.database.get_session_catalog_cache(project_id) or {
            "sessions": [],
            "nextCursor": None,
        }
        row = candidate[0]
        sessions = [row]
        sessions.extend(
            session
            for session in current["sessions"]
            if session.get("id") != row["id"]
        )
        payload = {
            "sessions": sessions[:5],
            "nextCursor": current.get("nextCursor"),
        }
        return self._store_session_catalog(project_id, payload)

    @staticmethod
    def _activity_from_thread_status(
        status: Any,
    ) -> Tuple[str, Optional[str]]:
        if not isinstance(status, dict):
            return "idle", None
        kind = status.get("type")
        if kind == "active":
            flags = status.get("activeFlags")
            if isinstance(flags, list) and "waitingOnApproval" in flags:
                return "waitingForInteraction", "approval"
            if isinstance(flags, list) and "waitingOnUserInput" in flags:
                return "waitingForInteraction", "question"
            return "working", None
        if kind == "systemError":
            return "failed", None
        return "idle", None

    def _publish_project_activity(
        self,
        project_id: str,
        session_id: str,
        state: str,
        *,
        turn_id: Optional[str] = None,
        item_kind: Optional[str] = None,
        source: str = "codexAppServer",
    ) -> None:
        key = (project_id, session_id)
        fingerprint = (state, turn_id, item_kind)
        with self._external_activity_condition:
            if self._external_activity_states.get(key) == fingerprint:
                return
            self._external_activity_states[key] = fingerprint
        data: Dict[str, Any] = {
            "type": "project.activityChanged",
            "hostID": self.host_id,
            "projectID": project_id,
            "sessionID": session_id,
            "state": state,
            "observedAt": self._iso_time(now()),
            "source": source,
        }
        if turn_id:
            data["turnID"] = turn_id
        if item_kind:
            data["itemKind"] = item_kind
        self.events.publish("project.activityChanged", data)

    def _publish_thread_activity(
        self,
        thread: Mapping[str, Any],
        *,
        source: str = "codexAppServer",
    ) -> None:
        session_id = thread.get("id")
        if not isinstance(session_id, str) or not session_id:
            return
        project_ids = self._project_ids_for_thread(thread)
        for project_id in project_ids:
            self._merge_session_catalog_thread(project_id, thread)
        state, item_kind = self._activity_from_thread_status(thread.get("status"))
        for project_id in project_ids:
            self._publish_project_activity(
                project_id,
                session_id,
                state,
                item_kind=item_kind,
                source=source,
            )

    def _on_codex_filesystem_activity(self, session_id: str) -> None:
        if self._closed.is_set() or not isinstance(session_id, str) or not session_id:
            return
        # CoFleet's own app-server also writes rollouts. Its direct notification
        # stream is richer and avoids a redundant canonical read.
        native_at = self._native_activity_at.get(session_id)
        if native_at is not None and time.monotonic() - native_at < 2.0:
            return
        self._external_activity_last_seen[session_id] = time.monotonic()
        self._external_stale_followups[session_id] = 0
        for project_id in self._project_ids_for_session(session_id):
            self._publish_project_activity(
                project_id,
                session_id,
                "working",
                source="codexDesktop",
            )
        with self._external_activity_condition:
            self._external_activity_deadlines[session_id] = time.monotonic() + 0.45
            self._external_activity_attempts.setdefault(session_id, 0)
            self._external_activity_condition.notify_all()

    def _defer_stale_external_snapshot(self, session_id: str) -> bool:
        """Keep a Desktop task working while cross-process history is stale.

        A private app-server can temporarily expose only the previous interrupted
        turn while Codex Desktop owns the live turn.  A small exponential set of
        targeted reads waits for the canonical completed/failed turn without
        mistaking that stale snapshot for completion.
        """

        last_seen = self._external_activity_last_seen.get(session_id)
        if last_seen is None:
            return False
        elapsed = time.monotonic() - last_seen
        abort_after = 15.0
        if elapsed >= abort_after:
            self._external_activity_last_seen.pop(session_id, None)
            self._external_stale_followups.pop(session_id, None)
            for project_id in self._project_ids_for_session(session_id):
                self._publish_project_activity(
                    project_id,
                    session_id,
                    "idle",
                    source="codexDesktop",
                )
            return True
        followup = self._external_stale_followups.get(session_id, 0)
        delays = (0.75, 1.5, 3.0, 5.0)
        delay = delays[followup] if followup < len(delays) else abort_after - elapsed
        self._external_stale_followups[session_id] = followup + 1
        with self._external_activity_condition:
            deadline = time.monotonic() + max(0.1, min(delay, abort_after - elapsed))
            current = self._external_activity_deadlines.get(session_id)
            if current is None or deadline < current:
                self._external_activity_deadlines[session_id] = deadline
            self._external_activity_condition.notify_all()
        return True

    def _external_activity_loop(self) -> None:
        while not self._closed.is_set():
            due: List[str] = []
            with self._external_activity_condition:
                while not self._closed.is_set():
                    current = time.monotonic()
                    due = [
                        session_id
                        for session_id, deadline in self._external_activity_deadlines.items()
                        if deadline <= current and session_id not in self._external_activity_inflight
                    ]
                    if due:
                        for session_id in due:
                            self._external_activity_deadlines.pop(session_id, None)
                            self._external_activity_inflight.add(session_id)
                        break
                    deadlines = list(self._external_activity_deadlines.values())
                    timeout = max(0.05, min(deadlines) - current) if deadlines else 1.0
                    self._external_activity_condition.wait(timeout=timeout)
            for session_id in due:
                try:
                    self._external_activity_executor.submit(
                        self._external_activity_reconcile_worker, session_id
                    )
                except RuntimeError:
                    with self._external_activity_condition:
                        self._external_activity_inflight.discard(session_id)

    def _external_activity_reconcile_worker(self, session_id: str) -> None:
        retry = False
        try:
            native_at = self._native_activity_at.get(session_id)
            if native_at is None or time.monotonic() - native_at >= 2.0:
                self._reconcile_external_session(session_id)
        except Exception:
            with self._external_activity_condition:
                attempt = self._external_activity_attempts.get(session_id, 0) + 1
                self._external_activity_attempts[session_id] = attempt
                retry = attempt < 3 and not self._closed.is_set()
        else:
            with self._external_activity_condition:
                self._external_activity_attempts.pop(session_id, None)
        finally:
            with self._external_activity_condition:
                self._external_activity_inflight.discard(session_id)
                if retry:
                    self._external_activity_deadlines[session_id] = (
                        time.monotonic() + 0.5 * self._external_activity_attempts[session_id]
                    )
                self._external_activity_condition.notify_all()

    @staticmethod
    def _bounded_fingerprint_store(
        store: Dict[Any, str], key: Any, value: str, maximum: int
    ) -> bool:
        if store.get(key) == value:
            return False
        store[key] = value
        while len(store) > maximum:
            store.pop(next(iter(store)))
        return True

    def _reconcile_external_session(self, session_id: str) -> bool:
        """Read one canonical task after an opaque rollout metadata wakeup."""

        result = self.codex.request(
            "thread/read",
            {"threadId": session_id, "includeTurns": True},
            timeout=min(15.0, self.config.rpc_timeout),
        )
        thread = result.get("thread")
        if not isinstance(thread, dict) or thread.get("id") != session_id:
            return False
        project_ids = self._project_ids_for_thread(thread)
        if not project_ids:
            # Unknown/unregistered tasks stay private and generate no SSE data.
            return False

        turns = thread.get("turns")
        raw_turns = [turn for turn in turns if isinstance(turn, dict)] if isinstance(turns, list) else []
        if not raw_turns:
            if self._defer_stale_external_snapshot(session_id):
                return True
            self._publish_thread_activity(thread, source="codexDesktop")
            return True
        latest = raw_turns[-1]
        turn_id = latest.get("id")
        if not isinstance(turn_id, str) or not turn_id:
            if self._defer_stale_external_snapshot(session_id):
                return True
            self._publish_thread_activity(thread, source="codexDesktop")
            return True
        state = self._turn_state(latest.get("status"))
        if state == "interrupted" and self._defer_stale_external_snapshot(session_id):
            return True
        for project_id in project_ids:
            self._merge_session_catalog_thread(project_id, thread)
        turn_fingerprint = json_hash(latest)
        turn_key = (session_id, turn_id)
        # A filesystem wake is an invalidation signal, not evidence that every
        # item returned by the first canonical thread/read is newly live. Codex
        # can touch a rollout merely because Desktop opened an existing task.
        # Baseline that first snapshot atomically and only stream item changes
        # observed by a later read of the same turn.
        is_initial_turn_snapshot = turn_key not in self._external_turn_fingerprints
        turn_changed = self._bounded_fingerprint_store(
            self._external_turn_fingerprints,
            turn_key,
            turn_fingerprint,
            512,
        )
        terminal = state in ("completed", "failed", "interrupted")
        if turn_changed and not terminal:
            self._publish_turn(session_id, latest, source="codexDesktop")
        items = latest.get("items")
        published_item = False
        if isinstance(items, list):
            for item in [entry for entry in items if isinstance(entry, dict)][-64:]:
                item_id = item.get("id")
                if not isinstance(item_id, str) or not item_id:
                    continue
                if not self._bounded_fingerprint_store(
                    self._external_item_fingerprints,
                    (session_id, turn_id, item_id),
                    json_hash(item),
                    4_096,
                ):
                    continue
                if is_initial_turn_snapshot:
                    continue
                status = str(item.get("status", "")).lower()
                completed = status not in ("inprogress", "in_progress", "running", "streaming")
                self._publish_item(
                    session_id,
                    turn_id,
                    item,
                    forced_state="completed" if completed else "streaming",
                    timestamp_ms=None,
                    completed=completed,
                    source="codexDesktop",
                )
                published_item = True
        if turn_changed and terminal:
            self._publish_turn(session_id, latest, source="codexDesktop")
        if state in ("completed", "interrupted"):
            activity_state = "idle"
        elif state == "failed":
            activity_state = "failed"
        elif state == "waitingForInteraction":
            activity_state = "waitingForInteraction"
        else:
            activity_state = "working"
        if terminal or not published_item:
            for project_id in project_ids:
                self._publish_project_activity(
                    project_id,
                    session_id,
                    activity_state,
                    turn_id=turn_id,
                    source="codexDesktop",
                )
        if activity_state in ("idle", "failed"):
            self._external_activity_last_seen.pop(session_id, None)
            self._external_stale_followups.pop(session_id, None)
            with self._external_activity_condition:
                self._external_activity_deadlines.pop(session_id, None)
        return True

    def _create_session(self, body: Dict[str, Any]) -> ServiceResponse:
        project_id = require_string(body.get("projectID"), "projectID", 1, 128)
        project = self.database.get_project(project_id)
        access_level, profile = self._access(body.get("accessLevel", "ask_for_approval"))
        params: Dict[str, Any] = {
            "cwd": project["canonicalPath"],
            **profile,
            "config": {"features.default_mode_request_user_input": True},
        }
        self._copy_optional(body, params, (("model", "model"), ("serviceTier", "serviceTier")))
        result = self.codex.request("thread/start", params)
        thread = result.get("thread")
        if not isinstance(thread, dict) or not isinstance(thread.get("id"), str):
            raise CodexUnavailable("Codex did not return a session identifier.")
        session_id = thread["id"]
        self._mark_session_resumed(session_id)
        self.database.put_session_settings(
            session_id,
            project_id,
            access_level,
            body.get("model") if isinstance(body.get("model"), str) else None,
            body.get("reasoningEffort") if isinstance(body.get("reasoningEffort"), str) else None,
            body.get("serviceTier") if isinstance(body.get("serviceTier"), str) else None,
        )
        session = self._normalize_session(thread, project_id)
        self.events.publish("session.created", {"session": session})
        self._schedule_session_catalog_after_mutation(project_id)
        return ServiceResponse(status=201, payload={"session": session})

    def _dispatch_session(
        self,
        method: str,
        rest: List[str],
        query: Mapping[str, str],
        headers: Mapping[str, str],
        body: Dict[str, Any],
    ) -> DispatchResult:
        session_id = rest[0]
        self._track_session_id(session_id)
        if len(rest) == 2 and rest[1] == "transcript" and method == "GET":
            bounded_turns = self._transcript_tail.read_if_large(session_id)
            if bounded_turns is not None:
                result = self.codex.request(
                    "thread/read", {"threadId": session_id, "includeTurns": False}
                )
                thread = result.get("thread", {})
                if not isinstance(thread, dict):
                    raise APIError(502, "invalid_codex_response", "Codex returned an invalid transcript.")
                return ServiceResponse(
                    payload={
                        "session": self._normalize_session(thread),
                        "turns": bounded_turns,
                        "truncated": True,
                    }
                )
            result = self.codex.request("thread/read", {"threadId": session_id, "includeTurns": True})
            thread = result.get("thread", {})
            if not isinstance(thread, dict):
                raise APIError(502, "invalid_codex_response", "Codex returned an invalid transcript.")
            session = self._normalize_session(thread)
            turns = self._normalize_turns(thread.get("turns", []))
            return ServiceResponse(payload={"session": session, "turns": turns})
        if len(rest) == 2 and rest[1] == "events" and method == "GET":
            return self._sse_request(query, headers, session_id)
        if len(rest) == 1 and method == "PATCH":
            name = require_string(body.get("title"), "title", 1, 200)
            self.codex.request("thread/name/set", {"threadId": session_id, "name": name})
            self.events.publish("session.renamed", {"sessionID": session_id, "title": name})
            self._schedule_session_catalog_for_session(session_id)
            return ServiceResponse(payload={"sessionID": session_id, "title": name})
        if len(rest) == 2 and rest[1] in ("resume", "fork") and method == "POST":
            return self._resume_or_fork(session_id, rest[1], body)
        if len(rest) == 2 and rest[1] == "open-in-codex" and method == "POST":
            return self._open_session_in_codex(session_id)
        if len(rest) == 2 and rest[1] in ("archive", "unarchive") and method == "POST":
            rpc_method = "thread/archive" if rest[1] == "archive" else "thread/unarchive"
            self.codex.request(rpc_method, {"threadId": session_id})
            self.events.publish("session.%s" % rest[1], {"sessionID": session_id})
            self._schedule_session_catalog_for_session(session_id)
            return ServiceResponse(payload={"sessionID": session_id, "archived": rest[1] == "archive"})
        if len(rest) == 2 and rest[1] == "turns" and method == "POST":
            return self._start_turn(session_id, headers, body)
        if len(rest) == 4 and rest[1] == "turns" and rest[3] in ("steer", "interrupt") and method == "POST":
            turn_id = rest[2]
            if rest[3] == "interrupt":
                result = self.codex.request("turn/interrupt", {"threadId": session_id, "turnId": turn_id})
                self._publish_turn(
                    session_id,
                    {"id": turn_id, "status": "interrupted"},
                    forced_state="interrupted",
                )
                return ServiceResponse(payload={"turn": result.get("turn", {"id": turn_id})})
            input_items = self._turn_input(body)
            params = {
                "threadId": session_id,
                "expectedTurnId": turn_id,
                "clientUserMessageId": new_id("message"),
                "input": input_items,
            }
            result = self.codex.request("turn/steer", params)
            return ServiceResponse(payload={"turn": result.get("turn", {"id": turn_id})})
        raise APIError(404, "route_not_found", "That session endpoint does not exist.")

    def _open_session_in_codex(self, session_id: str) -> ServiceResponse:
        session_id = require_string(session_id, "sessionID", 1, 256)
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,255}", session_id):
            raise APIError(422, "invalid_session_id", "The Codex session identifier is invalid.")

        # This authenticated endpoint accepts only an opaque, tightly bounded task
        # identifier and constructs the codex:// URL itself. A synchronous
        # thread/read added no meaningful injection protection and made a UI tap
        # wait on the app-server for tens of seconds. Codex remains authoritative
        # when it resolves the deep link; nonexistent IDs simply do not open a task.
        self.desktop_opener(session_id)
        return ServiceResponse(payload={"sessionID": session_id, "opened": True})

    @staticmethod
    def _open_codex_thread(session_id: str) -> None:
        opener = shutil.which("open") if platform.system() == "Darwin" else None
        if opener is None:
            raise APIError(
                501,
                "codex_desktop_unavailable",
                "Codex Companion requires the ChatGPT desktop app on a macOS host.",
            )
        deep_link = "codex://threads/" + quote(session_id, safe="")
        try:
            subprocess.run(
                [opener, deep_link],
                check=True,
                timeout=5,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise APIError(
                503,
                "codex_desktop_open_failed",
                "The host could not open this task in the ChatGPT desktop app.",
            ) from error

    def _resume_or_fork(self, session_id: str, action: str, body: Dict[str, Any]) -> ServiceResponse:
        project_id = require_string(body.get("projectID"), "projectID", 1, 128)
        project = self.database.get_project(project_id)
        access_level, profile = self._access(body.get("accessLevel", "ask_for_approval"))
        params: Dict[str, Any] = {
            "threadId": session_id,
            "cwd": project["canonicalPath"],
            **profile,
            "config": {"features.default_mode_request_user_input": True},
        }
        if action == "resume":
            self._copy_optional(body, params, (("model", "model"),))
        result = self.codex.request("thread/%s" % action, params)
        thread = result.get("thread", {})
        result_id = thread.get("id", session_id) if isinstance(thread, dict) else session_id
        self._mark_session_resumed(result_id)
        self.database.put_session_settings(
            result_id,
            project_id,
            access_level,
            body.get("model") if isinstance(body.get("model"), str) else None,
            body.get("reasoningEffort") if isinstance(body.get("reasoningEffort"), str) else None,
            body.get("serviceTier") if isinstance(body.get("serviceTier"), str) else None,
        )
        session = self._normalize_session(thread if isinstance(thread, dict) else {"id": result_id}, project_id)
        self.events.publish("session.%s" % action, {"session": session})
        self._schedule_session_catalog_after_mutation(project_id)
        return ServiceResponse(payload={"session": session})

    def _start_turn(
        self, session_id: str, headers: Mapping[str, str], body: Dict[str, Any]
    ) -> ServiceResponse:
        key = headers.get("Idempotency-Key") or headers.get("idempotency-key")
        if not key:
            raise APIError(428, "idempotency_required", "Idempotency-Key is required for starting a turn.")
        key = require_string(key, "Idempotency-Key", 8, 128)
        scope = "turn:%s" % session_id
        digest = json_hash(body)
        cached = self.database.claim_idempotency(scope, key, digest)
        if cached is not None:
            return ServiceResponse(status=cached[0], payload=cached[1])
        try:
            settings = self.database.get_session_settings(session_id)
            turn_input = self._turn_input(body)
            project_id = self._turn_project_id(session_id, body, settings)
            params: Dict[str, Any] = {
                "threadId": session_id,
                "input": turn_input,
            }
            access_value = body.get("accessLevel") or (
                settings.get("accessLevel") if settings else "ask_for_approval"
            )
            _, profile = self._access(access_value)
            params.update(self._turn_access_profile(profile))
            model = body.get("model") or (settings.get("model") if settings else None)
            effort = body.get("reasoningEffort") or (settings.get("reasoningEffort") if settings else None)
            service_tier = body.get("serviceTier") or (settings.get("serviceTier") if settings else None)
            if model:
                params["model"] = model
            if effort:
                params["effort"] = effort
            if service_tier:
                params["serviceTier"] = service_tier
            project = self.database.get_project(project_id)
            self._ensure_session_resumed(
                session_id,
                project["canonicalPath"],
                profile,
                model,
            )
            try:
                result = self.codex.request("turn/start", params)
            except CodexRPCError as error:
                # A process can restart between resume and turn/start. Codex can
                # still list/read the task from disk, but the new app-server does
                # not accept a turn until that task is resumed into its process.
                if not self._is_missing_thread_error(error):
                    raise
                self._ensure_session_resumed(
                    session_id,
                    project["canonicalPath"],
                    profile,
                    model,
                    force=True,
                )
                result = self.codex.request("turn/start", params)
            turn = result.get("turn")
            if not isinstance(turn, dict) or not isinstance(turn.get("id"), str):
                raise APIError(502, "invalid_codex_response", "Codex did not return a turn identifier.")
            payload = {"turn": self._normalize_turn(turn)}
            self.database.put_session_settings(
                session_id,
                project_id,
                access_value,
                model,
                effort,
                service_tier,
            )
            self.database.complete_idempotency(scope, key, 201, payload)
            self._publish_turn(session_id, turn, forced_state="running")
            return ServiceResponse(status=201, payload=payload)
        except Exception:
            self.database.abandon_idempotency(scope, key)
            raise

    def _mark_session_resumed(self, session_id: str) -> None:
        generation = getattr(self.codex, "generation", None)
        if isinstance(session_id, str) and session_id and isinstance(generation, str):
            with self._session_resume_lock:
                self._resumed_session_generations[session_id] = generation

    def _ensure_session_resumed(
        self,
        session_id: str,
        canonical_path: str,
        profile: Mapping[str, str],
        model: Optional[str],
        force: bool = False,
    ) -> None:
        with self._session_resume_lock:
            generation = getattr(self.codex, "generation", None)
            if (
                not force
                and isinstance(generation, str)
                and self._resumed_session_generations.get(session_id) == generation
            ):
                return
            resume_params: Dict[str, Any] = {
                "threadId": session_id,
                "cwd": canonical_path,
                **profile,
                "config": {"features.default_mode_request_user_input": True},
            }
            if model:
                resume_params["model"] = model
            result = self.codex.request("thread/resume", resume_params)
            thread = result.get("thread")
            if not isinstance(thread, dict) or thread.get("id") != session_id:
                raise CodexUnavailable("Codex did not resume the selected task.")
            resumed_generation = getattr(self.codex, "generation", None)
            if isinstance(resumed_generation, str):
                self._resumed_session_generations[session_id] = resumed_generation

    @staticmethod
    def _is_missing_thread_error(error: CodexRPCError) -> bool:
        message = error.message.lower()
        return ("thread" in message and "not found" in message) or "unknown thread" in message

    def _turn_project_id(
        self,
        session_id: str,
        body: Mapping[str, Any],
        settings: Optional[Dict[str, Any]],
    ) -> str:
        supplied_value = body.get("projectID")
        supplied_id: Optional[str] = None
        supplied_project: Optional[Dict[str, Any]] = None
        if supplied_value is not None:
            supplied_id = require_string(supplied_value, "projectID", 1, 128)
            supplied_project = self.database.get_project(supplied_id)

        if settings is not None:
            saved_id = settings["projectID"]
            if supplied_id is not None and supplied_id != saved_id:
                raise APIError(
                    409,
                    "session_project_mismatch",
                    "The Codex session belongs to a different registered project.",
                )
            self.database.get_project(saved_id)
            return saved_id

        if supplied_id is None or supplied_project is None:
            raise APIError(
                422,
                "project_required",
                "projectID is required for the first turn of a discovered Codex session.",
            )

        result = self.codex.request(
            "thread/read", {"threadId": session_id, "includeTurns": False}
        )
        thread = result.get("thread")
        if not isinstance(thread, dict):
            raise APIError(
                502,
                "invalid_codex_response",
                "Codex did not return the discovered session.",
            )
        cwd = thread.get("cwd")
        try:
            canonical_cwd = str(canonical_directory(cwd))
        except APIError:
            raise APIError(
                409,
                "session_project_unverified",
                "The discovered Codex session working directory cannot be verified.",
            )
        if canonical_cwd != supplied_project["canonicalPath"]:
            raise APIError(
                409,
                "session_project_mismatch",
                "The Codex session does not belong to the selected project.",
            )
        return supplied_id

    @staticmethod
    def _turn_access_profile(profile: Mapping[str, str]) -> Dict[str, Any]:
        """Translate a CoFleet access profile to Codex turn/start params."""

        sandbox = profile.get("sandbox")
        sandbox_policy = TURN_SANDBOX_POLICIES.get(sandbox or "")
        if sandbox_policy is None:
            # This is an internal configuration error, not invalid client input.
            raise RuntimeError("Unsupported Codex sandbox mode: %r" % sandbox)
        return {
            "approvalPolicy": profile["approvalPolicy"],
            "approvalsReviewer": profile["approvalsReviewer"],
            "sandboxPolicy": dict(sandbox_policy),
        }

    def _turn_input(self, body: Dict[str, Any]) -> List[Dict[str, Any]]:
        raw_input = body.get("input")
        if isinstance(raw_input, str):
            text = require_string(raw_input, "input", 1, 200_000, allow_control=True)
            return [{"type": "text", "text": text}]
        if isinstance(raw_input, list):
            items: List[Dict[str, Any]] = []
            for raw in raw_input:
                if not isinstance(raw, dict):
                    raise APIError(422, "invalid_input", "Turn input entries must be objects.")
                kind = raw.get("type")
                if kind == "text":
                    text = require_string(raw.get("text"), "input.text", 1, 200_000, allow_control=True)
                    items.append({"type": "text", "text": text})
                elif kind == "image":
                    url = require_string(raw.get("url"), "input.url", 8, 2_000)
                    if not (url.startswith("https://") or url.startswith("http://")):
                        raise APIError(422, "invalid_image_url", "Remote images must use HTTP or HTTPS.")
                    items.append({"type": "image", "url": url})
                elif kind == "localImage":
                    path = require_string(raw.get("path"), "input.path", 1, 4096)
                    settings = body.get("projectID")
                    if not settings:
                        raise APIError(422, "project_required", "projectID is required for local images.")
                    project = self.database.get_project(settings)
                    items.append({"type": "localImage", "path": self._local_image(path, project)})
                else:
                    raise APIError(422, "unsupported_input", "Only text and image inputs are supported.")
            if not items:
                raise APIError(422, "invalid_input", "At least one input item is required.")
            return items
        message = body.get("message")
        if isinstance(message, str):
            return [{"type": "text", "text": require_string(message, "message", 1, 200_000, True)}]
        raise APIError(422, "invalid_input", "A non-empty turn input is required.")

    @staticmethod
    def _local_image(raw_path: str, project: Dict[str, Any]) -> str:
        try:
            path = pathlib.Path(raw_path).expanduser().resolve(strict=True)
            root = pathlib.Path(project["canonicalPath"])
            common = os.path.commonpath((str(root), str(path)))
            size = path.stat().st_size
        except (OSError, RuntimeError, ValueError):
            raise APIError(422, "invalid_local_image", "The local image cannot be resolved.")
        if common != str(root) or not path.is_file() or size > 20 * 1024 * 1024:
            raise APIError(422, "invalid_local_image", "Local images must be readable files inside the project.")
        return str(path)

    # Notes and todos ----------------------------------------------------------

    def _project_notes(
        self,
        project_id: str,
        style: str,
        method: str,
        headers: Mapping[str, str],
        body: Dict[str, Any],
    ) -> ServiceResponse:
        self.database.get_project(project_id)
        notes = self.database.list_notes(project_id)
        if method == "GET":
            if style == "note":
                note = notes[0] if notes else None
                response = ServiceResponse(payload={"note": note})
                if note:
                    response.headers["ETag"] = make_etag("note", note["id"], note["revision"])
                return response
            return ServiceResponse(payload={"notes": notes})
        if method == "POST" or (method == "PUT" and style == "note" and not notes):
            title = require_string(body.get("title", "Notes"), "title", 1, 200)
            markdown = self._markdown(body.get("markdown", ""))
            session_id = body.get("sessionID") if isinstance(body.get("sessionID"), str) else None
            note = self.database.create_note(project_id, session_id, title, markdown)
            self.events.publish("note.created", {"note": note})
            return ServiceResponse(
                status=201,
                payload={"note": note},
                headers={"ETag": make_etag("note", note["id"], note["revision"])},
            )
        if method == "PUT" and style == "note":
            note = notes[0]
            expected = parse_etag(self._header(headers, "If-Match"), "note", note["id"])
            title = require_string(body.get("title", note["title"]), "title", 1, 200)
            markdown = self._markdown(body.get("markdown", note["markdown"]))
            updated = self.database.update_note(note["id"], expected, title, markdown)
            self.events.publish("note.updated", {"note": updated})
            return ServiceResponse(
                payload={"note": updated},
                headers={"ETag": make_etag("note", updated["id"], updated["revision"])},
            )
        raise APIError(405, "method_not_allowed", "That method is not allowed for project notes.")

    def _dispatch_note(
        self,
        method: str,
        note_id: str,
        headers: Mapping[str, str],
        body: Dict[str, Any],
    ) -> ServiceResponse:
        note = self.database.get_note(note_id)
        if method == "GET":
            return ServiceResponse(
                payload={"note": note},
                headers={"ETag": make_etag("note", note_id, note["revision"])},
            )
        expected = parse_etag(self._header(headers, "If-Match"), "note", note_id)
        if method == "PATCH":
            title = require_string(body.get("title", note["title"]), "title", 1, 200)
            markdown = self._markdown(body.get("markdown", note["markdown"]))
            updated = self.database.update_note(note_id, expected, title, markdown)
            self.events.publish("note.updated", {"note": updated})
            return ServiceResponse(
                payload={"note": updated},
                headers={"ETag": make_etag("note", note_id, updated["revision"])},
            )
        if method == "DELETE":
            deleted = self.database.delete_note(note_id, expected)
            self.events.publish("note.removed", {"noteID": note_id})
            return ServiceResponse(payload={"note": deleted})
        raise APIError(405, "method_not_allowed", "That method is not allowed for notes.")

    def _project_todos(
        self, project_id: str, method: str, body: Dict[str, Any]
    ) -> ServiceResponse:
        self.database.get_project(project_id)
        if method == "GET":
            return ServiceResponse(payload={"todos": self.database.list_todos(project_id)})
        if method == "POST":
            text = require_string(body.get("text"), "text", 1, 2_000, allow_control=True)
            completed = body.get("completed", False)
            if type(completed) is not bool:
                raise APIError(422, "invalid_request", "completed must be a boolean.")
            position = body.get("position")
            if position is not None:
                position = bounded_int(position, "position", 0, 0, 1_000_000)
            session_id = body.get("sessionID") if isinstance(body.get("sessionID"), str) else None
            todo = self.database.create_todo(project_id, session_id, text, completed, position)
            self.events.publish("todo.created", {"todo": todo})
            return ServiceResponse(
                status=201,
                payload={"todo": todo},
                headers={"ETag": make_etag("todo", todo["id"], todo["revision"])},
            )
        raise APIError(405, "method_not_allowed", "That method is not allowed for project todos.")

    def _dispatch_todo(
        self,
        method: str,
        todo_id: str,
        headers: Mapping[str, str],
        body: Dict[str, Any],
    ) -> ServiceResponse:
        todo = self.database.get_todo(todo_id)
        if method == "GET":
            return ServiceResponse(
                payload={"todo": todo},
                headers={"ETag": make_etag("todo", todo_id, todo["revision"])},
            )
        expected = parse_etag(self._header(headers, "If-Match"), "todo", todo_id)
        if method == "PATCH":
            text = require_string(body.get("text", todo["text"]), "text", 1, 2_000, allow_control=True)
            completed = body.get("completed", todo["completed"])
            if type(completed) is not bool:
                raise APIError(422, "invalid_request", "completed must be a boolean.")
            position = bounded_int(body.get("position"), "position", todo["position"], 0, 1_000_000)
            updated = self.database.update_todo(todo_id, expected, text, completed, position)
            self.events.publish("todo.updated", {"todo": updated})
            return ServiceResponse(
                payload={"todo": updated},
                headers={"ETag": make_etag("todo", todo_id, updated["revision"])},
            )
        if method == "DELETE":
            deleted = self.database.delete_todo(todo_id, expected)
            self.events.publish("todo.removed", {"todoID": todo_id})
            return ServiceResponse(payload={"todo": deleted})
        raise APIError(405, "method_not_allowed", "That method is not allowed for todos.")

    @staticmethod
    def _markdown(value: Any) -> str:
        if not isinstance(value, str):
            raise APIError(422, "invalid_request", "markdown must be a string.")
        if len(value.encode("utf-8")) > 1_000_000:
            raise APIError(413, "note_too_large", "Notes must be at most 1 MB.")
        return value

    # Interactions -------------------------------------------------------------

    def _on_codex_interaction(
        self,
        process_generation: str,
        rpc_id: Any,
        method: str,
        params: Dict[str, Any],
    ) -> None:
        bounded = bounded_json_value(params)
        if not isinstance(bounded, dict):
            bounded = {"_cofleetTruncated": True}
        interaction = self.database.create_interaction(
            rpc_id,
            process_generation,
            method,
            bounded,
            self.config.interaction_ttl,
        )
        public = self._public_interaction(interaction)
        session_id = interaction.get("sessionID")
        project_ids = (
            self._project_ids_for_session(session_id)
            if isinstance(session_id, str) and session_id
            else []
        )
        pending_payload: Dict[str, Any] = {
            "type": "interaction.pending",
            "interaction": public,
        }
        if project_ids:
            pending_payload["projectID"] = project_ids[0]
        self.events.publish(
            "interaction.pending",
            pending_payload,
        )
        interaction_kind = (
            "question" if public.get("kind") == "question" else "approval"
        )
        if interaction.get("sessionID") and interaction.get("turnID"):
            self._publish_turn(
                interaction["sessionID"],
                {"id": interaction["turnID"], "status": "waitingForInteraction"},
                forced_state="waitingForInteraction",
            )
        for project_id in project_ids:
            self._publish_project_activity(
                project_id,
                session_id,
                "waitingForInteraction",
                turn_id=interaction.get("turnID"),
                item_kind=interaction_kind,
            )

    def _resolve_interaction(self, interaction_id: str, body: Dict[str, Any]) -> ServiceResponse:
        # Serialize app-server replies in addition to the durable SQLite claim.
        # The DB state is the source of truth across HTTP worker threads.
        with self._interaction_lock:
            generation = getattr(self.codex, "generation", None)
            interaction = self.database.claim_interaction(interaction_id, generation)
            try:
                result, stop = self._interaction_result(interaction, body)
                self.codex.respond(
                    interaction["_rpcID"],
                    result,
                    expected_generation=interaction["_generation"],
                )
                if stop and interaction.get("sessionID") and interaction.get("turnID"):
                    try:
                        self.codex.request(
                            "turn/interrupt",
                            {
                                "threadId": interaction["sessionID"],
                                "turnId": interaction["turnID"],
                            },
                        )
                    except Exception:
                        # The denial is already authoritative; an already-complete
                        # turn is a harmless interrupt race.
                        pass
                resolved = self.database.finish_interaction(interaction_id, result)
            except Exception:
                if getattr(self.codex, "generation", None) != interaction["_generation"]:
                    self.database.invalidate_pending_interactions(interaction["_generation"])
                else:
                    self.database.release_interaction(interaction_id)
                raise
        public = self._public_interaction(resolved)
        resolved_payload: Dict[str, Any] = {
            "type": "interaction.resolved",
            "interactionID": interaction_id,
            "sessionID": interaction.get("sessionID"),
        }
        project_ids = self._project_ids_for_session(interaction.get("sessionID") or "")
        if project_ids:
            resolved_payload["projectID"] = project_ids[0]
        self.events.publish("interaction.resolved", resolved_payload)
        if interaction.get("sessionID") and interaction.get("turnID"):
            self._publish_turn(
                interaction["sessionID"],
                {"id": interaction["turnID"], "status": "interrupted" if stop else "inProgress"},
                forced_state="interrupted" if stop else "running",
            )
        return ServiceResponse(payload={"interaction": public})

    @staticmethod
    def _interaction_result(
        interaction: Dict[str, Any], body: Dict[str, Any]
    ) -> Tuple[Dict[str, Any], bool]:
        method = interaction["method"]
        decision = body.get("decision")
        stop = decision == "denyAndStop"
        if method in (
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
        ):
            mapping = {
                "allowOnce": "accept",
                "allowForSession": "acceptForSession",
                "deny": "decline",
                "denyAndStop": "decline",
                "cancel": "cancel",
                # Native spellings are accepted for forward-compatible clients.
                "accept": "accept",
                "acceptForSession": "acceptForSession",
                "decline": "decline",
            }
            if decision not in mapping:
                raise APIError(422, "invalid_decision", "That approval decision is not supported.")
            return {"decision": mapping[decision]}, stop
        if method == "item/permissions/requestApproval":
            if decision not in ("allowOnce", "allowForSession", "deny", "denyAndStop"):
                raise APIError(422, "invalid_decision", "That permission decision is not supported.")
            granted = interaction["params"].get("permissions", {}) if decision.startswith("allow") else {}
            return {
                "permissions": granted,
                "scope": "session" if decision == "allowForSession" else "turn",
            }, stop
        if method == "item/tool/requestUserInput":
            answers = body.get("answers")
            if not isinstance(answers, dict):
                raise APIError(422, "invalid_answers", "Question answers must be an object.")
            raw_questions = interaction["params"].get("questions")
            expected_ids = {
                question.get("id")
                for question in raw_questions
                if isinstance(question, dict) and isinstance(question.get("id"), str)
            } if isinstance(raw_questions, list) else set()
            if expected_ids and set(answers) != expected_ids:
                raise APIError(
                    422,
                    "invalid_answers",
                    "Answers must be provided for each requested question and no others.",
                )
            normalized: Dict[str, Dict[str, List[str]]] = {}
            for key, value in answers.items():
                if not isinstance(key, str) or not key or len(key) > 256:
                    raise APIError(422, "invalid_answers", "A question identifier is invalid.")
                values = value if isinstance(value, list) else [value]
                if not values or not all(
                    isinstance(item, str) and 0 < len(item) <= 10_000 for item in values
                ):
                    raise APIError(422, "invalid_answers", "Question answers must contain strings.")
                normalized[key] = {"answers": values}
            return {"answers": normalized}, False
        if method == "mcpServer/elicitation/request":
            action = body.get("action", decision)
            if action not in ("accept", "decline", "cancel"):
                raise APIError(422, "invalid_decision", "That MCP elicitation action is invalid.")
            result: Dict[str, Any] = {"action": action}
            if action == "accept" and "content" in body:
                if not isinstance(body["content"], dict):
                    raise APIError(422, "invalid_content", "MCP elicitation content must be an object.")
                result["content"] = body["content"]
            return result, False
        raise APIError(422, "unsupported_interaction", "That interaction cannot be resolved by CoFleet.")

    def _public_interaction(self, interaction: Dict[str, Any]) -> Dict[str, Any]:
        """Project a Codex callback into the stable CoFleet interaction model."""

        method = interaction.get("method", "")
        params = interaction.get("params")
        if not isinstance(params, dict):
            params = {}
        kind = "mcpElicitation"
        title = "Codex needs input"
        detail_parts: List[str] = []
        choices = ["accept", "decline", "cancel"]
        questions: List[Dict[str, Any]] = []

        if method == "item/commandExecution/requestApproval":
            kind = "commandApproval"
            title = "Command approval"
            choices = ["allowOnce", "allowForSession", "deny", "denyAndStop"]
            command = params.get("command")
            if isinstance(command, str) and command:
                detail_parts.append(command[:20_000])
            cwd = params.get("cwd")
            if isinstance(cwd, str) and cwd:
                detail_parts.append("Working directory: %s" % cwd[:4_096])
        elif method == "item/fileChange/requestApproval":
            kind = "fileApproval"
            title = "File change approval"
            choices = ["allowOnce", "allowForSession", "deny", "denyAndStop"]
            grant_root = params.get("grantRoot")
            if isinstance(grant_root, str) and grant_root:
                detail_parts.append("Requested write root: %s" % grant_root[:4_096])
        elif method == "item/permissions/requestApproval":
            kind = "permissionApproval"
            title = "Permission approval"
            choices = ["allowOnce", "allowForSession", "deny", "denyAndStop"]
            cwd = params.get("cwd")
            if isinstance(cwd, str) and cwd:
                detail_parts.append("Working directory: %s" % cwd[:4_096])
            permissions = params.get("permissions")
            if isinstance(permissions, dict):
                labels = sorted(str(key) for key, value in permissions.items() if value)
                if labels:
                    detail_parts.append("Permissions: %s" % ", ".join(labels)[:4_096])
        elif method == "item/tool/requestUserInput":
            kind = "question"
            title = "Codex has a question"
            choices = ["submitAnswer"]
            raw_questions = params.get("questions")
            if isinstance(raw_questions, list):
                for index, raw in enumerate(raw_questions[:20]):
                    if not isinstance(raw, dict):
                        continue
                    question_id = raw.get("id")
                    prompt = raw.get("question")
                    if not isinstance(question_id, str) or not question_id or not isinstance(prompt, str):
                        continue
                    options: List[Dict[str, str]] = []
                    raw_options = raw.get("options")
                    if isinstance(raw_options, list):
                        for option in raw_options[:50]:
                            if not isinstance(option, dict) or not isinstance(option.get("label"), str):
                                continue
                            options.append(
                                {
                                    "label": option["label"][:500],
                                    "detail": option.get("description", "")[:2_000]
                                    if isinstance(option.get("description"), str)
                                    else None,
                                }
                            )
                    questions.append(
                        {
                            "id": question_id[:256],
                            "header": raw.get("header", "Question %d" % (index + 1))[:500]
                            if isinstance(raw.get("header"), str)
                            else "Question %d" % (index + 1),
                            "prompt": prompt[:10_000],
                            "options": options,
                            "allowsFreeform": bool(raw.get("isOther", False)) or not options,
                            "isSecret": bool(raw.get("isSecret", False)),
                        }
                    )
            if questions:
                detail_parts.append("Answer %d question%s." % (len(questions), "s" if len(questions) != 1 else ""))
        else:
            message = params.get("message")
            server_name = params.get("serverName")
            if isinstance(server_name, str) and server_name:
                title = "%s requests input" % server_name[:200]
            if isinstance(message, str) and message:
                detail_parts.append(message[:10_000])

        reason = params.get("reason")
        if isinstance(reason, str) and reason:
            detail_parts.append("Reason: %s" % reason[:10_000])
        state = interaction.get("state")
        if state == "resolving":
            state = "pending"
        if state not in ("pending", "resolved", "expired"):
            state = "pending"
        return {
            "id": str(interaction.get("id", "")),
            "hostID": self.host_id,
            "sessionID": interaction.get("sessionID") or "",
            "turnID": interaction.get("turnID") or "",
            "kind": kind,
            "state": state,
            "title": title,
            "detail": "\n".join(detail_parts) or "Review this request from Codex.",
            "choices": choices,
            "questions": questions,
            "expiresAt": self._iso_time(interaction.get("expiresAt")),
        }

    def run_maintenance_once(self) -> None:
        for interaction in self.database.expire_interactions():
            try:
                self.codex.reject(
                    interaction["_rpcID"],
                    "CoFleet approval timed out and was denied.",
                    expected_generation=interaction["_generation"],
                )
            except Exception:
                pass
            payload: Dict[str, Any] = {
                "type": "interaction.expired",
                "interactionID": interaction["id"],
                "sessionID": interaction.get("sessionID"),
            }
            project_ids = self._project_ids_for_session(interaction.get("sessionID") or "")
            if project_ids:
                payload["projectID"] = project_ids[0]
            self.events.publish("interaction.expired", payload)

    def _maintenance_loop(self) -> None:
        while not self._closed.wait(2.0):
            try:
                self.run_maintenance_once()
            except Exception:
                # Maintenance is best effort; normal HTTP/RPC activity remains
                # available even if one cleanup pass sees a transient failure.
                pass

    # Events and normalization -------------------------------------------------

    def _on_codex_notification(self, method: str, params: Dict[str, Any]) -> None:
        if method == "cofleet/codexUnavailable":
            generation = params.get("processGeneration")
            invalidated = self.database.invalidate_pending_interactions(
                generation if isinstance(generation, str) else None
            )
            for interaction in invalidated:
                payload: Dict[str, Any] = {
                    "type": "interaction.expired",
                    "interactionID": interaction["id"],
                    "sessionID": interaction.get("sessionID"),
                }
                project_ids = self._project_ids_for_session(
                    interaction.get("sessionID") or ""
                )
                if project_ids:
                    payload["projectID"] = project_ids[0]
                self.events.publish("interaction.expired", payload)
            self.events.publish(
                "stream.reset",
                {
                    "type": "stream.reset",
                    "reason": "codex_unavailable",
                    "invalidatedInteractions": len(invalidated),
                },
            )
            return

        if method == "thread/started":
            thread = params.get("thread")
            if isinstance(thread, dict):
                session_id = thread.get("id")
                if isinstance(session_id, str) and session_id:
                    self._native_activity_at[session_id] = time.monotonic()
                self._publish_thread_activity(thread)
            return

        session_id = params.get("threadId")
        if not isinstance(session_id, str) or not session_id:
            # Notifications without thread scope are intentionally not exposed
            # through the conversation stream.
            return
        self._native_activity_at[session_id] = time.monotonic()
        if method == "thread/status/changed":
            state, item_kind = self._activity_from_thread_status(params.get("status"))
            for project_id in self._project_ids_for_session(session_id):
                self._publish_project_activity(
                    project_id,
                    session_id,
                    state,
                    item_kind=item_kind,
                )
            return
        if method in ("turn/started", "turn/completed"):
            turn = params.get("turn")
            if isinstance(turn, dict):
                self._publish_turn(session_id, turn)
            if method == "turn/completed":
                self._schedule_session_catalog_for_session(session_id)
            return
        if method in ("item/started", "item/completed"):
            item = params.get("item")
            turn_id = params.get("turnId")
            if isinstance(item, dict) and isinstance(turn_id, str):
                timestamp_key = "startedAtMs" if method == "item/started" else "completedAtMs"
                self._publish_item(
                    session_id,
                    turn_id,
                    item,
                    forced_state="streaming" if method == "item/started" else "completed",
                    timestamp_ms=params.get(timestamp_key),
                    completed=method == "item/completed",
                )
            return

        delta_kind = {
            "item/agentMessage/delta": "assistantMessage",
            "item/reasoning/textDelta": "reasoning",
            "item/reasoning/summaryTextDelta": "reasoning",
            "item/commandExecution/outputDelta": "command",
            "item/fileChange/outputDelta": "fileChange",
            "item/plan/delta": "reasoning",
        }.get(method)
        if delta_kind is not None:
            self._publish_item_delta(session_id, params, delta_kind)
            return
        if method == "item/mcpToolCall/progress":
            progress = params.get("message")
            if isinstance(progress, str):
                copied = dict(params)
                copied["delta"] = progress
                self._publish_item_delta(session_id, copied, "tool")
        # Unknown/new app-server notifications are deliberately dropped. The
        # public event log remains provider-neutral and cannot leak raw params.

    @staticmethod
    def _iso_time(value: Any) -> str:
        try:
            timestamp = float(value)
        except (TypeError, ValueError):
            timestamp = now()
        return datetime.datetime.fromtimestamp(
            timestamp, datetime.timezone.utc
        ).isoformat(timespec="seconds").replace("+00:00", "Z")

    @staticmethod
    def _turn_state(status: Any) -> str:
        normalized = str(status or "").lower()
        if normalized in ("completed", "complete"):
            return "completed"
        if normalized in ("failed", "error", "errored"):
            return "failed"
        if normalized in ("interrupted", "cancelled", "canceled"):
            return "interrupted"
        if normalized in ("waiting", "waitingforinteraction", "waiting_for_interaction"):
            return "waitingForInteraction"
        if normalized == "queued":
            return "queued"
        return "running"

    def _publish_turn(
        self,
        session_id: str,
        turn: Dict[str, Any],
        forced_state: Optional[str] = None,
        source: str = "codexAppServer",
    ) -> None:
        turn_id = turn.get("id")
        if not isinstance(turn_id, str) or not turn_id:
            return
        key = (session_id, turn_id)
        started_at = turn.get("startedAt")
        with self._stream_lock:
            if not isinstance(started_at, (int, float)):
                started_at = self._turn_started_at.get(key, now())
            self._turn_started_at[key] = float(started_at)
        state = forced_state or self._turn_state(turn.get("status"))
        error = turn.get("error")
        if isinstance(error, dict):
            error = error.get("message") or error.get("code") or "Codex turn failed."
        elif error is not None and not isinstance(error, str):
            error = str(error)
        completed_at = turn.get("completedAt")
        if state in ("completed", "failed", "interrupted") and not isinstance(
            completed_at, (int, float)
        ):
            completed_at = now()
        model = {
            "id": turn_id,
            "hostID": self.host_id,
            "sessionID": session_id,
            "state": state,
            "startedAt": self._iso_time(started_at),
            "completedAt": self._iso_time(completed_at) if completed_at is not None else None,
            "errorMessage": error[:10_000] if isinstance(error, str) else None,
        }
        project_ids = self._project_ids_for_session(session_id)
        targets: List[Optional[str]] = project_ids or [None]
        for project_id in targets:
            payload: Dict[str, Any] = {
                "type": "turn.updated",
                "turn": model,
                "sessionID": session_id,
            }
            if project_id is not None:
                payload["projectID"] = project_id
            self.events.publish("turn.updated", payload)
        if state in ("completed", "interrupted"):
            activity_state = "idle"
        elif state == "failed":
            activity_state = "failed"
        elif state == "waitingForInteraction":
            activity_state = "waitingForInteraction"
        else:
            activity_state = "working"
        for project_id in project_ids:
            self._publish_project_activity(
                project_id,
                session_id,
                activity_state,
                turn_id=turn_id,
                source=source,
            )
        if state in ("completed", "failed", "interrupted"):
            with self._stream_lock:
                self._turn_started_at.pop(key, None)
                stale = [item_key for item_key in self._stream_items if item_key[:2] == key]
                for item_key in stale:
                    self._stream_items.pop(item_key, None)

    @staticmethod
    def _event_item_kind(item_type: str, role: str) -> str:
        if role == "user" or item_type == "userMessage":
            return "userMessage"
        if item_type == "agentMessage" or role == "assistant":
            return "assistantMessage"
        if item_type == "reasoning" or item_type == "plan":
            return "reasoning"
        if item_type == "commandExecution":
            return "command"
        if item_type == "fileChange":
            return "fileChange"
        if item_type in ("system", "contextCompaction"):
            return "system"
        return "tool"

    @staticmethod
    def _event_item_state(status: Any, forced_state: Optional[str]) -> str:
        if forced_state is not None:
            return forced_state
        normalized = str(status or "").lower()
        if normalized in ("inprogress", "running", "pending"):
            return "streaming"
        if normalized in ("failed", "error", "errored", "declined"):
            return "failed"
        return "completed"

    def _event_item_model(
        self,
        item: Dict[str, Any],
        turn_id: str,
        forced_state: Optional[str],
        timestamp_ms: Any,
    ) -> Dict[str, Any]:
        normalized = self._normalize_item(item, turn_id)
        item_type = normalized["type"]
        role = normalized["role"]
        kind = self._event_item_kind(item_type, role)
        text = normalized.get("text")
        title = normalized.get("title")
        detail = normalized.get("detail")
        if kind in ("command", "fileChange", "tool"):
            components = [value for value in (title, detail, text) if isinstance(value, str) and value]
            text = "\n\n".join(dict.fromkeys(components))
        elif not isinstance(text, str) or not text:
            text = detail if isinstance(detail, str) else title if isinstance(title, str) else ""
        try:
            created_at = float(timestamp_ms) / 1_000.0
        except (TypeError, ValueError):
            created_at = now()
        return {
            "id": normalized["id"],
            "turnID": turn_id,
            "kind": kind,
            "state": self._event_item_state(normalized.get("status"), forced_state),
            "text": self._bounded_stream_text(text),
            "createdAt": self._iso_time(created_at),
        }

    def _bounded_stream_text(self, value: str) -> str:
        maximum_bytes = min(200_000, max(1_024, self.config.event_payload_limit - 4_096))
        encoded = value.encode("utf-8", errors="replace")
        if len(encoded) <= maximum_bytes:
            return value
        suffix = "\n\n[Output truncated by CoFleet]"
        budget = maximum_bytes - len(suffix.encode("utf-8"))
        return encoded[:budget].decode("utf-8", errors="ignore") + suffix

    def _publish_item(
        self,
        session_id: str,
        turn_id: str,
        item: Dict[str, Any],
        forced_state: Optional[str],
        timestamp_ms: Any,
        completed: bool,
        source: str = "codexAppServer",
    ) -> None:
        model = self._event_item_model(item, turn_id, forced_state, timestamp_ms)
        key = (session_id, turn_id, model["id"])
        with self._stream_lock:
            if completed:
                self._stream_items.pop(key, None)
            else:
                cached = dict(model)
                cached["_hasDelta"] = False
                self._stream_items[key] = cached
        project_ids = self._project_ids_for_session(session_id)
        targets: List[Optional[str]] = project_ids or [None]
        for project_id in targets:
            payload: Dict[str, Any] = {
                "type": "turn.item",
                "item": model,
                "sessionID": session_id,
            }
            if project_id is not None:
                payload["projectID"] = project_id
            self.events.publish("turn.item", payload)
        for project_id in project_ids:
            self._publish_project_activity(
                project_id,
                session_id,
                "working",
                turn_id=turn_id,
                item_kind=model["kind"],
                source=source,
            )

    def _publish_item_delta(
        self, session_id: str, params: Dict[str, Any], kind: str
    ) -> None:
        turn_id = params.get("turnId")
        item_id = params.get("itemId")
        delta = params.get("delta")
        if not all(isinstance(value, str) for value in (turn_id, item_id, delta)):
            return
        key = (session_id, turn_id, item_id)
        with self._stream_lock:
            model = dict(
                self._stream_items.get(
                    key,
                    {
                        "id": item_id,
                        "turnID": turn_id,
                        "kind": kind,
                        "state": "streaming",
                        "text": "",
                        "createdAt": self._iso_time(now()),
                        "_hasDelta": False,
                    },
                )
            )
            prefix = model.get("text", "")
            if kind in ("command", "fileChange", "tool") and prefix and not model.get("_hasDelta"):
                prefix += "\n\n"
            model["text"] = self._bounded_stream_text(prefix + delta)
            model["state"] = "streaming"
            model["kind"] = kind
            model["_hasDelta"] = True
            self._stream_items[key] = model
            public = {key_name: value for key_name, value in model.items() if not key_name.startswith("_")}
        project_ids = self._project_ids_for_session(session_id)
        targets: List[Optional[str]] = project_ids or [None]
        for project_id in targets:
            payload: Dict[str, Any] = {
                "type": "turn.item",
                "item": public,
                "sessionID": session_id,
            }
            if project_id is not None:
                payload["projectID"] = project_id
            self.events.publish("turn.item", payload)
        for project_id in project_ids:
            self._publish_project_activity(
                project_id,
                session_id,
                "working",
                turn_id=turn_id,
                item_kind=kind,
            )

    def _sse_request(
        self,
        query: Mapping[str, str],
        headers: Mapping[str, str],
        session_id: Optional[str],
    ) -> SSERequest:
        raw = self._header(headers, "Last-Event-ID") or query.get("after", "0")
        try:
            after_id = int(raw)
        except (TypeError, ValueError):
            raise APIError(422, "invalid_event_id", "Last-Event-ID must be a non-negative integer.")
        if after_id < 0:
            raise APIError(422, "invalid_event_id", "Last-Event-ID must be a non-negative integer.")
        return SSERequest(
            after_id=after_id,
            once=query.get("once", "false").lower() == "true",
            session_id=session_id,
        )

    @staticmethod
    def event_matches_session(event: Dict[str, Any], session_id: Optional[str]) -> bool:
        event_type = event.get("type")
        if event_type == "codex.event" or event_type in (
            "codex.unavailable",
            "interaction.requested",
            "turn.started",
            "turn.interrupted",
        ):
            # Never replay provider-native events left by an older development
            # database. The caller emits only an opaque cursor checkpoint.
            return False
        if session_id is None:
            return True
        data = event.get("data", {})
        if not isinstance(data, dict):
            return False
        if data.get("type") == "stream.reset":
            return True
        if data.get("sessionID") == session_id or data.get("threadId") == session_id:
            return True
        params = data.get("params")
        if isinstance(params, dict) and params.get("threadId") == session_id:
            return True
        interaction = data.get("interaction")
        return isinstance(interaction, dict) and interaction.get("sessionID") == session_id

    @staticmethod
    def _normalize_models(result: Dict[str, Any]) -> List[Dict[str, Any]]:
        models: List[Dict[str, Any]] = []
        for row in result.get("data", []):
            if not isinstance(row, dict) or row.get("hidden") is True:
                continue
            model_id = row.get("model", row.get("id"))
            if not isinstance(model_id, str):
                continue
            efforts = []
            for effort in row.get("supportedReasoningEfforts", []):
                if isinstance(effort, dict) and isinstance(effort.get("reasoningEffort"), str):
                    efforts.append(effort["reasoningEffort"])
                elif isinstance(effort, str):
                    efforts.append(effort)
            tiers = []
            for tier in row.get("serviceTiers", []):
                if isinstance(tier, dict) and isinstance(tier.get("id"), str):
                    tiers.append(tier["id"])
                elif isinstance(tier, str):
                    tiers.append(tier)
            models.append(
                {
                    "id": model_id,
                    "displayName": row.get("displayName", model_id),
                    "isDefault": bool(row.get("isDefault", False)),
                    "inputModalities": row.get("inputModalities", ["text"]),
                    "reasoningEfforts": efforts,
                    "serviceTiers": tiers,
                    "contextWindow": row.get("contextWindow"),
                }
            )
        return models

    def _normalize_session(
        self, thread: Dict[str, Any], project_id: Optional[str] = None
    ) -> Dict[str, Any]:
        session_id = thread.get("id")
        if not isinstance(session_id, str):
            session_id = ""
        title = thread.get("name") or thread.get("title") or thread.get("preview") or "Untitled task"
        if not isinstance(title, str):
            title = "Untitled task"
        settings = self.database.get_session_settings(session_id) if session_id else None
        return {
            "id": session_id,
            "hostID": self.host_id,
            "projectID": project_id or (settings.get("projectID") if settings else None),
            "title": title[:500],
            "cwd": thread.get("cwd"),
            "preview": thread.get("preview"),
            "createdAt": thread.get("createdAt"),
            "updatedAt": thread.get("updatedAt"),
            "archived": bool(thread.get("archived", False)),
            "model": thread.get("model") or (settings.get("model") if settings else None),
            "accessLevel": settings.get("accessLevel") if settings else None,
            "reasoningEffort": settings.get("reasoningEffort") if settings else None,
            "serviceTier": settings.get("serviceTier") if settings else None,
            "provider": "codex",
        }

    def _normalize_turns(self, raw_turns: Any) -> List[Dict[str, Any]]:
        if not isinstance(raw_turns, list):
            return []
        return [self._normalize_turn(turn) for turn in raw_turns if isinstance(turn, dict)]

    def _normalize_turn(self, turn: Dict[str, Any]) -> Dict[str, Any]:
        turn_id = turn.get("id", "")
        items = turn.get("items", [])
        normalized_items = [
            self._normalize_item(item, str(turn_id)) for item in items if isinstance(item, dict)
        ] if isinstance(items, list) else []
        return {
            "id": turn_id,
            "status": turn.get("status"),
            "error": turn.get("error"),
            "items": normalized_items,
        }

    @staticmethod
    def _normalize_item(item: Dict[str, Any], turn_id: str) -> Dict[str, Any]:
        item_type = str(item.get("type", "unknown"))
        text = item.get("text")
        if not isinstance(text, str):
            content = item.get("content")
            pieces: List[str] = []
            if isinstance(content, list):
                for part in content:
                    if isinstance(part, dict):
                        value = part.get("text", part.get("inputText", part.get("outputText")))
                        if isinstance(value, str):
                            pieces.append(value)
                    elif isinstance(part, str):
                        pieces.append(part)
            text = "\n".join(pieces) if pieces else None
        role = item.get("role")
        if not isinstance(role, str):
            role = "assistant" if item_type in ("agentMessage", "reasoning") else (
                "user" if item_type == "userMessage" else "tool"
            )
        detail = item.get("aggregatedOutput") or item.get("output") or item.get("summary")
        if isinstance(detail, (dict, list)):
            detail = str(detail)
        return {
            "id": str(item.get("id") or ("item_" + json_hash(item)[:24])),
            "turnID": turn_id,
            "type": item_type,
            "role": role,
            "text": text,
            "status": item.get("status"),
            "title": item.get("name") or item.get("command") or item.get("tool"),
            "detail": detail if isinstance(detail, str) else None,
        }

    # Source control -----------------------------------------------------------

    def _project_with_source_control(self, project: Dict[str, Any]) -> Dict[str, Any]:
        enriched = dict(project)
        enriched["currentSessionID"] = self.database.cached_current_session_id(project["id"])
        enriched["sourceControl"] = self.source_control(project["id"])
        return enriched

    def source_control(self, project_id: str) -> Dict[str, Any]:
        project = self.database.get_project(project_id)
        root = project["canonicalPath"]
        repository_kind, repository_root = self._repository_root(root)
        cache_key = "%s:%s" % (repository_kind or "none", repository_root)
        timestamp = time.monotonic()
        with self._source_lock:
            cached = self._source_cache.get(cache_key)
            if cached and cached[0] > timestamp:
                return cached[1]
        if repository_kind == "git":
            result = self._git_status(repository_root)
        elif repository_kind == "plastic":
            result = self._plastic_status(repository_root)
        else:
            result = {
                "kind": "none",
                "state": "unavailable",
                "branch": None,
                "detail": "No Git or Plastic workspace found",
            }
        result["observedAt"] = now()
        with self._source_lock:
            self._source_cache[cache_key] = (timestamp + 15.0, result)
        return result

    @staticmethod
    def _repository_root(root: str) -> Tuple[Optional[str], str]:
        current = pathlib.Path(root)
        for candidate in (current, *current.parents):
            if (candidate / ".git").exists():
                return "git", str(candidate)
            if (candidate / ".plastic").exists():
                return "plastic", str(candidate)
        return None, root

    @staticmethod
    def _run_bounded(
        command: List[str],
        *,
        cwd: Optional[str] = None,
        environment: Optional[Dict[str, str]] = None,
        timeout: float = 5.0,
        maximum_output_bytes: int = 128_000,
    ) -> Optional[Tuple[int, str]]:
        """Run without a shell while bounding runtime and captured output."""

        try:
            process = subprocess.Popen(
                command,
                cwd=cwd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                env=environment,
            )
        except OSError:
            return None
        assert process.stdout is not None
        output = bytearray()
        overflow = threading.Event()

        def read_output() -> None:
            try:
                while True:
                    remaining = maximum_output_bytes + 1 - len(output)
                    if remaining <= 0:
                        overflow.set()
                        try:
                            process.kill()
                        except OSError:
                            pass
                        return
                    chunk = process.stdout.read(min(8_192, remaining))
                    if not chunk:
                        return
                    output.extend(chunk)
                    if len(output) > maximum_output_bytes:
                        overflow.set()
                        try:
                            process.kill()
                        except OSError:
                            pass
                        return
            except OSError:
                return

        reader = threading.Thread(target=read_output, daemon=True)
        reader.start()
        try:
            return_code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                process.kill()
            except OSError:
                pass
            process.wait()
            reader.join(timeout=0.5)
            process.stdout.close()
            return None
        reader.join(timeout=0.5)
        process.stdout.close()
        if reader.is_alive() or overflow.is_set():
            return None
        return return_code, output.decode("utf-8", errors="replace")

    @classmethod
    def _git_status(cls, root: str) -> Dict[str, Any]:
        git = shutil.which("git", path="/usr/bin:/bin")
        if git is None:
            return {"kind": "git", "state": "unavailable", "branch": None, "detail": "git unavailable"}
        environment = {
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_ASKPASS": "/usr/bin/false",
            "SSH_ASKPASS": "/usr/bin/false",
            "GIT_EXTERNAL_DIFF": "/usr/bin/false",
        }
        command = [
            git,
            "--no-pager",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.untrackedCache=false",
            "-c",
            "core.preloadIndex=false",
            "-c",
            "core.hooksPath=/var/empty/cofleet-hooks",
            "-c",
            "diff.external=",
            "-C",
            root,
            "status",
            "--porcelain=v1",
            "--branch",
            "--untracked-files=normal",
        ]
        completed = cls._run_bounded(command, environment=environment)
        if completed is None:
            return {"kind": "git", "state": "unavailable", "branch": None, "detail": "status unavailable"}
        return_code, output = completed
        lines = output.splitlines()
        if return_code != 0 or not lines:
            return {"kind": "git", "state": "unavailable", "branch": None, "detail": "status unavailable"}
        header = lines[0][3:] if lines[0].startswith("## ") else ""
        branch_text = header.split("...")[0]
        if branch_text.startswith("No commits yet on "):
            branch_text = branch_text[len("No commits yet on ") :]
        elif branch_text.startswith("Initial commit on "):
            branch_text = branch_text[len("Initial commit on ") :]
        branch = branch_text.split(" ")[0] or None
        ahead = "[ahead " in header
        changes = lines[1:] if lines[0].startswith("## ") else lines
        staged = any(line and line[0] not in (" ", "?") for line in changes)
        dirty = bool(changes)
        state = "unpushed" if ahead else ("staged" if staged else ("dirty" if dirty else "clean"))
        result = {"kind": "git", "state": state, "branch": branch, "detail": header or None}
        pull_request = cls._github_pull_request_status(root, git, branch, header, environment)
        if pull_request is not None:
            result.update(pull_request)
        return result

    @classmethod
    def _github_pull_request_status(
        cls,
        root: str,
        git: str,
        branch: Optional[str],
        header: str,
        git_environment: Dict[str, str],
    ) -> Optional[Dict[str, Any]]:
        if branch is None or len(branch) > 255 or any(ord(character) < 32 for character in branch):
            return None
        upstream = header.split("...", 1)[1].split(" ", 1)[0] if "..." in header else ""
        remote_name = upstream.split("/", 1)[0] if "/" in upstream else "origin"
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", remote_name):
            return None
        remote = cls._run_bounded(
            [
                git,
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.hooksPath=/var/empty/cofleet-hooks",
                "-C",
                root,
                "config",
                "--get",
                "remote.%s.url" % remote_name,
            ],
            environment=git_environment,
            timeout=1.0,
            maximum_output_bytes=4_096,
        )
        if remote is None or remote[0] != 0:
            return None
        remote_url = remote[1].strip()
        match = re.fullmatch(
            r"(?:https?://github\.com/|ssh://git@github\.com/|git@github\.com:)"
            r"([A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100})(?:\.git)?/?",
            remote_url,
            flags=re.IGNORECASE,
        )
        if match is None:
            return None
        repository = match.group(1)
        if repository.lower().endswith(".git"):
            repository = repository[:-4]
        gh = shutil.which(
            "gh",
            path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        )
        if gh is None:
            return None
        gh_environment = {
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": os.path.expanduser("~"),
            "LANG": "C",
            "LC_ALL": "C",
            "GH_PROMPT_DISABLED": "1",
            "GH_PAGER": "cat",
            "NO_COLOR": "1",
        }
        for variable in ("GH_TOKEN", "GITHUB_TOKEN", "XDG_CONFIG_HOME"):
            if os.environ.get(variable):
                gh_environment[variable] = os.environ[variable]
        response = cls._run_bounded(
            [
                gh,
                "pr",
                "list",
                "--repo",
                repository,
                "--head",
                branch,
                "--state",
                "open",
                "--limit",
                "1",
                "--json",
                "isDraft,state,url,number",
            ],
            cwd="/",
            environment=gh_environment,
            timeout=2.0,
            maximum_output_bytes=16_384,
        )
        if response is None or response[0] != 0:
            return None
        try:
            items = json.loads(response[1])
        except (TypeError, ValueError):
            return None
        if not isinstance(items, list) or not items or not isinstance(items[0], dict):
            return None
        item = items[0]
        number = item.get("number")
        label = "Draft" if item.get("isDraft") is True else "Open"
        return {
            "state": "draftPullRequest" if item.get("isDraft") is True else "openPullRequest",
            "detail": "%s pull request%s" % (label, " #%s" % number if isinstance(number, int) else ""),
        }

    @classmethod
    def _plastic_status(cls, root: str) -> Dict[str, Any]:
        executable_path = "/opt/homebrew/bin:/usr/local/bin:/Applications/PlasticSCM.app/Contents/MacOS:/usr/bin:/bin"
        cm = shutil.which("cm", path=executable_path)
        if cm is None:
            return {"kind": "plastic", "state": "unavailable", "branch": None, "detail": "Plastic unavailable"}
        completed = cls._run_bounded(
            [cm, "status", "--machinereadable", "--fieldseparator=|"],
            cwd=root,
            environment={
                "PATH": executable_path,
                "HOME": os.path.expanduser("~"),
                "LANG": "C",
                "LC_ALL": "C",
            },
        )
        if completed is None:
            return {"kind": "plastic", "state": "unavailable", "branch": None, "detail": "status unavailable"}
        return_code, output = completed
        lines = [line for line in output.splitlines() if line.strip()]
        state = "clean" if return_code == 0 and not lines else (
            "dirty" if return_code == 0 else "unavailable"
        )
        return {"kind": "plastic", "state": state, "branch": None, "detail": None}

    # Helpers ------------------------------------------------------------------

    @staticmethod
    def _access(value: Any) -> Tuple[str, Dict[str, str]]:
        if not isinstance(value, str) or value not in ACCESS_PROFILES:
            raise APIError(422, "invalid_access_level", "The requested access level is invalid.")
        return value, dict(ACCESS_PROFILES[value])

    @staticmethod
    def _copy_optional(
        source: Mapping[str, Any], destination: Dict[str, Any], fields: Tuple[Tuple[str, str], ...]
    ) -> None:
        for source_key, destination_key in fields:
            value = source.get(source_key)
            if isinstance(value, str) and value:
                destination[destination_key] = value

    @staticmethod
    def _header(headers: Mapping[str, str], name: str) -> Optional[str]:
        target = name.casefold()
        for key, value in headers.items():
            if key.casefold() == target:
                return value
        return None
