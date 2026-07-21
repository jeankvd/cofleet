#!/usr/bin/env python3
"""Opt-in local Codex smoke through CoFleet's real REST/SSE facade.

Read-only mode is the default and creates no Codex task or turn. Live modes
require the literal ``--confirm-live-usage`` flag because they consume Codex
usage and leave one clearly named archived smoke task in canonical history.
"""

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[1]
HOST_PACKAGE = REPOSITORY_ROOT / "Services" / "CoFleetHost"
if str(HOST_PACKAGE) not in sys.path:
    sys.path.insert(0, str(HOST_PACKAGE))

from cofleet_host.config import HostConfig  # noqa: E402
from cofleet_host.http import make_server  # noqa: E402
from cofleet_host.service import CoFleetHostService  # noqa: E402


MAX_RESPONSE_BYTES = 2 * 1024 * 1024
DEFAULT_HTTP_TIMEOUT = 65.0
DEFAULT_TURN_TIMEOUT = 180.0
TERMINAL_TURN_STATES = {"completed", "failed", "interrupted"}


class SmokeError(Exception):
    """Failure whose fixed code is safe for public logs."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class LiveOptions:
    mode: str
    codex: str
    timeout: float


@dataclass(frozen=True)
class HTTPResult:
    status: int
    body: bytes
    headers: Mapping[str, str]

    def json_object(self) -> Dict[str, Any]:
        try:
            value = json.loads(self.body.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            raise SmokeError("invalid_json_response")
        if not isinstance(value, dict):
            raise SmokeError("invalid_json_response")
        return value


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return None


class LocalClient:
    def __init__(self, base_url: str, token: Optional[str], timeout: float) -> None:
        split = urllib.parse.urlsplit(base_url)
        if split.scheme != "http" or split.hostname not in ("127.0.0.1", "::1"):
            raise SmokeError("local_transport_required")
        self.base_url = base_url.rstrip("/") + "/v1"
        self.token = token
        self.timeout = timeout
        self._opener = urllib.request.build_opener(_NoRedirect())

    def request(
        self,
        method: str,
        path: str,
        body: Optional[Dict[str, Any]] = None,
        headers: Optional[Mapping[str, str]] = None,
        accept: str = "application/json",
    ) -> HTTPResult:
        if not path.startswith("/") or path.startswith("//"):
            raise SmokeError("invalid_request_path")
        merged = {"Accept": accept}
        if self.token:
            merged["Authorization"] = "Bearer " + self.token
        if headers:
            merged.update(headers)
        data = None
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode("utf-8")
            merged["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self.base_url + path,
            data=data,
            headers=merged,
            method=method,
        )
        try:
            response = self._opener.open(request, timeout=self.timeout)
        except urllib.error.HTTPError as error:
            response = error
        except (OSError, urllib.error.URLError, TimeoutError):
            raise SmokeError("local_host_unreachable")
        try:
            raw_length = response.headers.get("Content-Length")
            if raw_length is not None:
                try:
                    if int(raw_length) > MAX_RESPONSE_BYTES:
                        raise SmokeError("response_too_large")
                except ValueError:
                    raise SmokeError("invalid_response_length")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if len(payload) > MAX_RESPONSE_BYTES:
                raise SmokeError("response_too_large")
            return HTTPResult(int(response.status), payload, dict(response.headers.items()))
        finally:
            response.close()


class LocalHostHarness:
    """Temporary CoFleet state around the user's already-authenticated Codex."""

    def __init__(self, codex: str, timeout: float) -> None:
        self.codex = resolve_executable(codex)
        self.timeout = timeout
        self.temporary: Optional[tempfile.TemporaryDirectory[str]] = None
        self.service: Optional[CoFleetHostService] = None
        self.server = None
        self.thread: Optional[threading.Thread] = None
        self.workspace: Optional[pathlib.Path] = None
        self.client: Optional[LocalClient] = None

    def __enter__(self) -> "LocalHostHarness":
        login = subprocess.run(
            [self.codex, "login", "status"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )
        if login.returncode != 0:
            raise SmokeError("codex_login_required")

        self.temporary = tempfile.TemporaryDirectory(prefix="cofleet-live-smoke-")
        root = pathlib.Path(self.temporary.name)
        self.workspace = root / "workspace"
        self.workspace.mkdir()
        config = HostConfig(
            data_dir=root / "state",
            bind_host="127.0.0.1",
            port=0,
            display_name="CoFleet Smoke",
            home=root,
            codex_command=(self.codex, "app-server"),
            rpc_timeout=min(max(self.timeout, 30.0), 300.0),
        ).validate()
        try:
            self.service = CoFleetHostService(config)
            self.server = make_server(self.service)
            self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
            self.thread.start()
            address, port = self.server.server_address[:2]
            open_client = LocalClient("http://%s:%d" % (address, port), None, self.timeout)
            pairing = self.service.create_pairing_code("local-smoke")
            redeemed = expect_json(
                open_client,
                "POST",
                "/pairings/redeem",
                201,
                {"code": pairing["code"], "deviceName": "CoFleet Local Smoke"},
            )
            token = redeemed.get("token")
            if not isinstance(token, str) or len(token) < 32:
                raise SmokeError("invalid_pairing_response")
            self.client = LocalClient("http://%s:%d" % (address, port), token, self.timeout)
            return self
        except Exception:
            self.close()
            raise

    def close(self) -> None:
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
            self.server = None
        if self.service is not None:
            self.service.close()
            self.service = None
        if self.thread is not None:
            self.thread.join(timeout=2.0)
            self.thread = None
        self.client = None
        if self.temporary is not None:
            self.temporary.cleanup()
            self.temporary = None

    def __exit__(self, exc_type, exc_value, traceback) -> None:  # type: ignore[no-untyped-def]
        self.close()


def resolve_executable(value: str) -> str:
    if os.path.sep in value:
        path = os.path.abspath(os.path.expanduser(value))
        if not os.path.isfile(path) or not os.access(path, os.X_OK):
            raise SmokeError("codex_not_found")
        return path
    found = shutil.which(value)
    if found is None:
        raise SmokeError("codex_not_found")
    return found


def expect_json(
    client: LocalClient,
    method: str,
    path: str,
    expected_status: int,
    body: Optional[Dict[str, Any]] = None,
    headers: Optional[Mapping[str, str]] = None,
) -> Dict[str, Any]:
    response = client.request(method, path, body, headers)
    if response.status != expected_status:
        raise SmokeError("unexpected_http_status")
    return response.json_object()


def _quote(value: str) -> str:
    return urllib.parse.quote(value, safe="")


def _synthetic_title() -> str:
    return "CoFleet live smoke " + uuid.uuid4().hex[:12]


def _default_model(models: List[Any]) -> str:
    rows = [row for row in models if isinstance(row, dict) and isinstance(row.get("id"), str)]
    if not rows:
        raise SmokeError("no_codex_models")
    selected = next((row for row in rows if row.get("isDefault") is True), rows[0])
    return selected["id"]


def run_read_only_checks(
    client: LocalClient,
    workspace: pathlib.Path,
    emit: Callable[[str], None],
) -> Tuple[str, str]:
    health = expect_json(client, "GET", "/health", 200)
    if health.get("ok") is not True or health.get("service") != "cofleet-host":
        raise SmokeError("invalid_health_response")
    host = expect_json(client, "GET", "/host", 200).get("host")
    if not isinstance(host, dict) or host.get("transport") != "loopback":
        raise SmokeError("invalid_local_host_response")
    account = expect_json(client, "GET", "/account", 200).get("account")
    if not isinstance(account, dict) or not isinstance(account.get("account"), dict):
        raise SmokeError("codex_not_authenticated")
    models = expect_json(client, "GET", "/models", 200).get("models")
    profiles = expect_json(client, "GET", "/permission-profiles", 200).get(
        "permissionProfiles"
    )
    suggestions = expect_json(client, "GET", "/projects/suggestions?limit=5", 200).get(
        "suggestions"
    )
    if not isinstance(models, list) or not isinstance(profiles, list) or len(profiles) != 3:
        raise SmokeError("invalid_runtime_catalog")
    if not isinstance(suggestions, list) or len(suggestions) > 5:
        raise SmokeError("invalid_project_suggestions")

    registered = expect_json(
        client,
        "POST",
        "/projects",
        201,
        {"rootPath": str(workspace), "name": "CoFleet Smoke"},
    ).get("project")
    if not isinstance(registered, dict) or not isinstance(registered.get("id"), str):
        raise SmokeError("invalid_project_registration")
    project_id = registered["id"]
    sessions = expect_json(
        client,
        "GET",
        "/projects/%s/sessions?limit=5" % _quote(project_id),
        200,
    ).get("sessions")
    if not isinstance(sessions, list) or len(sessions) > 5:
        raise SmokeError("invalid_session_page")

    model = _default_model(models)
    emit("[cofleet-smoke] health=ok")
    emit("[cofleet-smoke] account=authenticated")
    emit("[cofleet-smoke] models=%d" % len(models))
    emit("[cofleet-smoke] project_suggestions=%d" % len(suggestions))
    emit("[cofleet-smoke] session_page_items=%d" % len(sessions))
    return project_id, model


def parse_sse(payload: bytes) -> List[Tuple[Optional[int], str, Dict[str, Any]]]:
    try:
        text = payload.decode("utf-8")
    except UnicodeError:
        raise SmokeError("invalid_sse_response")
    events: List[Tuple[Optional[int], str, Dict[str, Any]]] = []
    for block in text.replace("\r\n", "\n").split("\n\n"):
        if not block or block.startswith(":"):
            continue
        event_id: Optional[int] = None
        event_name = "message"
        data_lines: List[str] = []
        for line in block.splitlines():
            if line.startswith("id: "):
                try:
                    event_id = int(line[4:])
                except ValueError:
                    raise SmokeError("invalid_sse_response")
            elif line.startswith("event: "):
                event_name = line[7:]
            elif line.startswith("data: "):
                data_lines.append(line[6:])
        if not data_lines:
            continue
        try:
            data = json.loads("\n".join(data_lines))
        except json.JSONDecodeError:
            raise SmokeError("invalid_sse_response")
        if not isinstance(data, dict):
            raise SmokeError("invalid_sse_response")
        events.append((event_id, event_name, data))
    return events


def _sse_once(
    client: LocalClient, session_id: str, cursor: int
) -> List[Tuple[Optional[int], str, Dict[str, Any]]]:
    response = client.request(
        "GET",
        "/sessions/%s/events?once=true" % _quote(session_id),
        headers={"Last-Event-ID": str(cursor)},
        accept="text/event-stream",
    )
    if response.status != 200:
        raise SmokeError("sse_stream_failed")
    content_type = response.headers.get("Content-Type", "")
    if not content_type.startswith("text/event-stream"):
        raise SmokeError("sse_stream_failed")
    return parse_sse(response.body)


def wait_for_turn(
    client: LocalClient,
    session_id: str,
    turn_id: str,
    timeout: float,
    require_item_event: bool = True,
) -> str:
    deadline = time.monotonic() + timeout
    cursor = 0
    saw_turn_event = False
    saw_item_event = False
    last_transcript_poll = 0.0
    state: Optional[str] = None
    while time.monotonic() < deadline:
        for event_id, event_name, data in _sse_once(client, session_id, cursor):
            if event_id is not None:
                cursor = max(cursor, event_id)
            if event_name == "turn.updated" and data.get("type") == "turn.updated":
                turn = data.get("turn")
                if isinstance(turn, dict) and turn.get("id") == turn_id:
                    saw_turn_event = True
                    if isinstance(turn.get("state"), str):
                        state = turn["state"]
            if event_name == "turn.item" and data.get("type") == "turn.item":
                item = data.get("item")
                if isinstance(item, dict) and item.get("turnID") == turn_id:
                    saw_item_event = True

        now = time.monotonic()
        if now - last_transcript_poll >= 2.0:
            transcript = expect_json(
                client, "GET", "/sessions/%s/transcript" % _quote(session_id), 200
            )
            turns = transcript.get("turns")
            if isinstance(turns, list):
                for turn in turns:
                    if isinstance(turn, dict) and turn.get("id") == turn_id:
                        raw_status = str(turn.get("status") or "").lower()
                        if raw_status in (
                            "completed",
                            "failed",
                            "interrupted",
                            "cancelled",
                            "canceled",
                        ):
                            state = (
                                "interrupted"
                                if raw_status in ("cancelled", "canceled")
                                else raw_status
                            )
            last_transcript_poll = now
        if state in TERMINAL_TURN_STATES:
            if not saw_turn_event or (require_item_event and not saw_item_event):
                raise SmokeError("stream_events_missing")
            return state
        time.sleep(0.25)
    raise SmokeError("turn_timeout")


def _start_turn(
    client: LocalClient,
    session_id: str,
    model: str,
    message: str,
) -> str:
    response = expect_json(
        client,
        "POST",
        "/sessions/%s/turns" % _quote(session_id),
        201,
        {"message": message, "accessLevel": "ask_for_approval", "model": model},
        {"Idempotency-Key": "smoke-" + uuid.uuid4().hex},
    )
    turn = response.get("turn")
    if not isinstance(turn, dict) or not isinstance(turn.get("id"), str):
        raise SmokeError("turn_start_failed")
    return turn["id"]


def _wait_for_interaction(
    client: LocalClient,
    session_id: str,
    turn_id: str,
    timeout: float,
) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        interactions = expect_json(client, "GET", "/interactions?state=pending", 200).get(
            "interactions"
        )
        if not isinstance(interactions, list):
            raise SmokeError("invalid_interaction_response")
        for interaction in interactions:
            if (
                isinstance(interaction, dict)
                and interaction.get("sessionID") == session_id
                and interaction.get("turnID") == turn_id
                and interaction.get("kind") == "commandApproval"
                and isinstance(interaction.get("id"), str)
            ):
                return interaction["id"]
        time.sleep(0.25)
    raise SmokeError("approval_not_requested")


def _resolve_interaction(client: LocalClient, interaction_id: str, decision: str) -> None:
    resolved = expect_json(
        client,
        "POST",
        "/interactions/%s/resolve" % _quote(interaction_id),
        200,
        {"decision": decision},
    ).get("interaction")
    if not isinstance(resolved, dict) or resolved.get("state") != "resolved":
        raise SmokeError("interaction_resolution_failed")


def run_safe_turn(
    client: LocalClient,
    project_id: str,
    model: str,
    timeout: float,
    approval_probes: bool,
    emit: Callable[[str], None],
    session_tracker: Optional[List[str]] = None,
) -> str:
    created = expect_json(
        client,
        "POST",
        "/sessions",
        201,
        {"projectID": project_id, "accessLevel": "ask_for_approval", "model": model},
    ).get("session")
    if not isinstance(created, dict) or not isinstance(created.get("id"), str):
        raise SmokeError("session_start_failed")
    session_id = created["id"]
    if session_tracker is not None:
        session_tracker.append(session_id)
    expect_json(
        client,
        "PATCH",
        "/sessions/%s" % _quote(session_id),
        200,
        {"title": _synthetic_title()},
    )

    turn_id = _start_turn(
        client,
        session_id,
        model,
        "Reply with exactly COFLEET_SMOKE_OK. Do not use tools.",
    )
    if wait_for_turn(client, session_id, turn_id, timeout) != "completed":
        raise SmokeError("safe_turn_failed")
    transcript = expect_json(
        client, "GET", "/sessions/%s/transcript" % _quote(session_id), 200
    )
    turns = transcript.get("turns")
    assistant_replied = False
    if isinstance(turns, list):
        for turn in turns:
            if not isinstance(turn, dict) or turn.get("id") != turn_id:
                continue
            items = turn.get("items")
            if not isinstance(items, list):
                continue
            assistant_replied = any(
                isinstance(item, dict)
                and item.get("role") == "assistant"
                and isinstance(item.get("text"), str)
                and "COFLEET_SMOKE_OK" in item["text"]
                for item in items
            )
    if not assistant_replied:
        raise SmokeError("safe_turn_response_mismatch")
    expect_json(
        client,
        "POST",
        "/sessions/%s/resume" % _quote(session_id),
        200,
        {"projectID": project_id, "accessLevel": "ask_for_approval", "model": model},
    )
    emit("[cofleet-smoke] safe_turn=ok")
    emit("[cofleet-smoke] stream_replay=ok")
    emit("[cofleet-smoke] transcript_restore=ok")
    emit("[cofleet-smoke] resume=ok")

    if approval_probes:
        command_prompt = (
            "Run exactly `python3 -I -S -c 'print(42)'` once, then report its output. "
            "Do not use any other tool."
        )
        denied_turn = _start_turn(client, session_id, model, command_prompt)
        denied_interaction = _wait_for_interaction(
            client, session_id, denied_turn, min(timeout, 90.0)
        )
        _resolve_interaction(client, denied_interaction, "denyAndStop")
        denied_state = wait_for_turn(
            client, session_id, denied_turn, min(timeout, 90.0), require_item_event=False
        )
        if denied_state != "interrupted":
            raise SmokeError("approval_deny_failed")

        allowed_turn = _start_turn(client, session_id, model, command_prompt)
        allowed_interaction = _wait_for_interaction(
            client, session_id, allowed_turn, min(timeout, 90.0)
        )
        _resolve_interaction(client, allowed_interaction, "allowOnce")
        if wait_for_turn(client, session_id, allowed_turn, timeout) != "completed":
            raise SmokeError("approval_allow_failed")

        interrupt_prompt = (
            "Run exactly `python3 -I -S -c 'import time; time.sleep(30)'` once. "
            "Do not use any other tool."
        )
        interrupted_turn = _start_turn(client, session_id, model, interrupt_prompt)
        interrupted_interaction = _wait_for_interaction(
            client, session_id, interrupted_turn, min(timeout, 90.0)
        )
        _resolve_interaction(client, interrupted_interaction, "allowOnce")
        time.sleep(0.5)
        expect_json(
            client,
            "POST",
            "/sessions/%s/turns/%s/interrupt"
            % (_quote(session_id), _quote(interrupted_turn)),
            200,
        )
        interrupted_state = wait_for_turn(
            client,
            session_id,
            interrupted_turn,
            min(timeout, 90.0),
            require_item_event=False,
        )
        if interrupted_state != "interrupted":
            raise SmokeError("turn_interrupt_failed")
        emit("[cofleet-smoke] approval_deny=ok")
        emit("[cofleet-smoke] approval_allow=ok")
        emit("[cofleet-smoke] interrupt=ok")
    return session_id


def run_live_smoke(
    options: LiveOptions,
    harness_factory: Callable[[str, float], LocalHostHarness] = LocalHostHarness,
    emit: Callable[[str], None] = print,
) -> None:
    with harness_factory(options.codex, options.timeout) as harness:
        if harness.client is None or harness.workspace is None:
            raise SmokeError("local_harness_failed")
        project_id, model = run_read_only_checks(harness.client, harness.workspace, emit)
        if options.mode == "read-only":
            emit("[cofleet-smoke] mode=read_only")
            return

        session_tracker: List[str] = []
        primary_error: Optional[BaseException] = None
        try:
            run_safe_turn(
                harness.client,
                project_id,
                model,
                options.timeout,
                options.mode == "approval-probes",
                emit,
                session_tracker,
            )
        except BaseException as error:
            primary_error = error
            raise
        finally:
            cleanup_failed = False
            if session_tracker:
                try:
                    response = harness.client.request(
                        "POST", "/sessions/%s/archive" % _quote(session_tracker[-1])
                    )
                    cleanup_failed = response.status != 200
                except Exception:
                    cleanup_failed = True
            # If creation failed after Codex allocated a thread but before the
            # response returned, no public identifier exists to archive. This
            # is reported as the primary session-start failure without guessing
            # at or scanning private task history.
            if cleanup_failed:
                emit("[cofleet-smoke] archive_cleanup=failed")
                if primary_error is None:
                    raise SmokeError("live_session_archive_failed")
            elif session_tracker:
                emit("[cofleet-smoke] archive_cleanup=ok")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run an opt-in local CoFleet/Codex integration smoke."
    )
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument(
        "--read-only",
        dest="mode",
        action="store_const",
        const="read-only",
        help="No task or turn creation (default)",
    )
    modes.add_argument(
        "--safe-turn",
        dest="mode",
        action="store_const",
        const="safe-turn",
        help="Create, stream, resume, and archive one synthetic task",
    )
    modes.add_argument(
        "--approval-probes",
        dest="mode",
        action="store_const",
        const="approval-probes",
        help="Also exercise command deny/allow and turn interruption",
    )
    parser.set_defaults(mode="read-only")
    parser.add_argument(
        "--confirm-live-usage",
        action="store_true",
        help="Required literal acknowledgement for usage-consuming modes",
    )
    parser.add_argument("--codex", default="codex", help="Codex CLI executable")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TURN_TIMEOUT)
    return parser


def parse_options(argv: Optional[Sequence[str]] = None) -> LiveOptions:
    parser = _parser()
    arguments = parser.parse_args(argv)
    if not (10.0 <= arguments.timeout <= 600.0):
        parser.error("--timeout must be between 10 and 600 seconds")
    if arguments.mode != "read-only" and not arguments.confirm_live_usage:
        parser.error("live modes require the literal --confirm-live-usage flag")
    if arguments.mode == "read-only" and arguments.confirm_live_usage:
        parser.error("--confirm-live-usage is only valid with a live mode")
    return LiveOptions(arguments.mode, arguments.codex, arguments.timeout)


def main(argv: Optional[Sequence[str]] = None) -> int:
    options = parse_options(argv)
    try:
        run_live_smoke(options)
    except SmokeError as error:
        print("[cofleet-smoke] failed=" + error.code, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("[cofleet-smoke] failed=cancelled", file=sys.stderr)
        return 130
    except Exception:
        print("[cofleet-smoke] failed=unexpected_error", file=sys.stderr)
        return 1
    print("[cofleet-smoke] live_codex_smoke=passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
