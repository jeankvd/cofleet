"""Threaded loopback HTTP/1.1 transport for the CoFleet v1 API."""

import json
import socket
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, Mapping, Optional, Tuple, Type
from urllib.parse import parse_qs, unquote, urlsplit

from .errors import APIError
from .service import CoFleetHostService, SSERequest, ServiceResponse
from .util import canonical_json


class CoFleetHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address, handler_class, max_handlers: int, max_sse: int):
        self.handler_slots = threading.BoundedSemaphore(max_handlers)
        self.sse_slots = threading.BoundedSemaphore(max_sse)
        super().__init__(server_address, handler_class)

    def process_request(self, request, client_address):
        if not self.handler_slots.acquire(blocking=False):
            try:
                body = b'{"error":{"code":"server_busy","message":"Too many active requests."}}\n'
                request.sendall(
                    b"HTTP/1.1 503 Service Unavailable\r\n"
                    b"Content-Type: application/json; charset=utf-8\r\n"
                    + ("Content-Length: %d\r\n" % len(body)).encode("ascii")
                    + b"Connection: close\r\nCache-Control: no-store\r\n\r\n"
                    + body
                )
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.handler_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.handler_slots.release()


def handler_for(service: CoFleetHostService) -> Type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "CoFleetHost/1"
        sys_version = ""

        def setup(self) -> None:
            super().setup()
            self.connection.settimeout(service.config.http_read_timeout)

        def do_GET(self) -> None:  # noqa: N802 - stdlib hook name
            self._handle()

        def do_POST(self) -> None:  # noqa: N802
            self._handle()

        def do_PUT(self) -> None:  # noqa: N802
            self._handle()

        def do_PATCH(self) -> None:  # noqa: N802
            self._handle()

        def do_DELETE(self) -> None:  # noqa: N802
            self._handle()

        def do_OPTIONS(self) -> None:  # noqa: N802
            # The API is not a browser cross-origin surface. Do not advertise
            # permissive CORS; native clients send ordinary authenticated HTTP.
            self._send_error(APIError(405, "method_not_allowed", "OPTIONS is not supported."))

        def _handle(self) -> None:
            try:
                self._enforce_transport()
                split = urlsplit(self.path)
                if len(split.path) > 4096:
                    raise APIError(414, "uri_too_long", "The request URI is too long.")
                path = unquote(split.path, errors="strict")
                try:
                    parsed_query = parse_qs(
                        split.query,
                        keep_blank_values=True,
                        strict_parsing=False,
                        max_num_fields=50,
                    )
                except ValueError:
                    raise APIError(422, "invalid_query", "The query string is invalid.")
                query = {key: values[-1] for key, values in parsed_query.items() if values}
                body = self._read_json_body()
                open_route = (
                    (self.command == "GET" and path == "/v1/health")
                    or (self.command == "POST" and path == "/v1/pairings/redeem")
                )
                device = None if open_route else service.authenticate(self.headers.get("Authorization"))
                result = service.dispatch(
                    self.command,
                    path,
                    query,
                    dict(self.headers.items()),
                    body,
                    device,
                )
                if isinstance(result, SSERequest):
                    self._send_sse(result, self.headers.get("Authorization"))
                else:
                    self._send_response(result)
            except APIError as error:
                self._send_error(error)
            except (BrokenPipeError, ConnectionResetError):
                return
            except socket.timeout:
                self._send_error(APIError(408, "request_timeout", "The request timed out."))
            except UnicodeError:
                self._send_error(APIError(400, "invalid_uri", "The request URI is not valid UTF-8."))
            except Exception:
                # No traceback or exception text crosses the authenticated API;
                # it can contain local paths or subprocess details.
                self._send_error(APIError(500, "internal_error", "The host could not complete the request."))

        def _read_json_body(self) -> Dict[str, Any]:
            transfer_encoding = self.headers.get("Transfer-Encoding")
            if transfer_encoding:
                raise APIError(400, "unsupported_transfer", "Chunked request bodies are not supported.")
            raw_length = self.headers.get("Content-Length")
            if raw_length is None:
                return {}
            try:
                length = int(raw_length)
            except ValueError:
                raise APIError(400, "invalid_content_length", "Content-Length is invalid.")
            if length < 0 or length > service.config.request_body_limit:
                raise APIError(413, "request_too_large", "The request body is too large.")
            if length == 0:
                return {}
            if self.command in ("GET", "DELETE"):
                raise APIError(400, "unexpected_body", "This endpoint does not accept a request body.")
            content_type = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
            if content_type != "application/json":
                raise APIError(415, "unsupported_media_type", "Use application/json.")
            data = self.rfile.read(length)
            if len(data) != length:
                raise APIError(400, "incomplete_body", "The request body ended early.")
            try:
                value = json.loads(data.decode("utf-8"))
            except (UnicodeError, json.JSONDecodeError):
                raise APIError(400, "invalid_json", "The request body is not valid UTF-8 JSON.")
            if not isinstance(value, dict):
                raise APIError(422, "invalid_request", "The JSON request body must be an object.")
            return value

        def _enforce_transport(self) -> None:
            if not service.config.require_private_tailscale:
                return
            # Tailscale documents that Serve adds identity headers and strips
            # spoofed inbound copies, while Funnel traffic has no identity.
            # This check is paired with a startup inspection of AllowFunnel.
            login = self.headers.get("Tailscale-User-Login", "")
            name = self.headers.get("Tailscale-User-Name", "")
            if (
                not login
                or not name
                or len(login) > 320
                or len(name) > 320
                or any(ord(character) < 32 for character in login + name)
            ):
                raise APIError(
                    403,
                    "private_serve_identity_required",
                    "This deployment accepts authenticated Tailscale Serve traffic only.",
                )

        def _send_response(self, response: ServiceResponse) -> None:
            if response.body is not None:
                data = response.body
            else:
                data = (canonical_json(response.payload or {}) + "\n").encode("utf-8")
            self.send_response(response.status)
            self.send_header("Content-Type", response.content_type)
            self.send_header("Content-Length", str(len(data)))
            self._security_headers()
            for key, value in response.headers.items():
                self.send_header(key, value)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        def _send_error(self, error: APIError) -> None:
            data = (canonical_json(error.as_payload()) + "\n").encode("utf-8")
            try:
                self.send_response(error.status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Connection", "close")
                if error.status == 401:
                    self.send_header("WWW-Authenticate", 'Bearer realm="cofleet-host"')
                if error.status == 429:
                    self.send_header("Retry-After", "60")
                self._security_headers()
                self.end_headers()
                self.wfile.write(data)
                self.close_connection = True
            except (BrokenPipeError, ConnectionResetError):
                return

        def _send_sse(self, request: SSERequest, authorization: Optional[str]) -> None:
            server = self.server
            if not isinstance(server, CoFleetHTTPServer) or not server.sse_slots.acquire(blocking=False):
                raise APIError(503, "sse_capacity", "Too many active event streams.")
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-cache, no-transform")
                self.send_header("Connection", "close")
                self.send_header("X-Accel-Buffering", "no")
                self._security_headers(cache_control=False)
                self.end_headers()
                cursor = request.after_id
                last_sent_cursor = request.after_id
                sent_reset = False
                last_heartbeat = time.monotonic()
                while True:
                    if not service.stream_token_is_active(authorization):
                        self.close_connection = True
                        return
                    events, reset_required = service.events.replay(cursor)
                    if reset_required and not sent_reset:
                        self._write_sse(
                            None,
                            "resetRequired",
                            {"reason": "event_cursor_expired", "hostID": service.host_id},
                        )
                        sent_reset = True
                    for event in events:
                        cursor = max(cursor, int(event["id"]))
                        if not service.event_matches_session(event, request.session_id):
                            continue
                        self._write_sse(event["id"], event["type"], event["data"])
                        last_sent_cursor = int(event["id"])
                    if cursor > last_sent_cursor:
                        # A session stream may scan host events belonging to a
                        # different task. A payload-free checkpoint prevents a
                        # reconnect from rescanning them forever.
                        self._write_sse(cursor, "checkpoint", {"type": "checkpoint"})
                        last_sent_cursor = cursor
                    self.wfile.flush()
                    if request.once:
                        return
                    current = time.monotonic()
                    if current - last_heartbeat >= 15.0:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
                        last_heartbeat = current
                    service.events.wait(service.config.sse_auth_recheck_interval)
            finally:
                server.sse_slots.release()

        def _write_sse(
            self, event_id: Optional[int], event_type: str, data: Dict[str, Any]
        ) -> None:
            if event_id is not None:
                self.wfile.write(("id: %d\n" % event_id).encode("ascii"))
            safe_type = "".join(character for character in event_type if character not in "\r\n")
            self.wfile.write(("event: %s\n" % safe_type).encode("utf-8"))
            payload = canonical_json(data).replace("\n", "\\n")
            self.wfile.write(("data: %s\n\n" % payload).encode("utf-8"))

        def _security_headers(self, cache_control: bool = True) -> None:
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
            if cache_control:
                self.send_header("Cache-Control", "no-store")

        def log_message(self, format: str, *args: object) -> None:
            # Paths can contain private project names and query strings can carry
            # cursors. Operators should use structured service events instead.
            return

    return Handler


def make_server(service: CoFleetHostService) -> CoFleetHTTPServer:
    return CoFleetHTTPServer(
        (service.config.bind_host, service.config.port),
        handler_for(service),
        service.config.max_active_http_handlers,
        service.config.max_active_sse_streams,
    )
