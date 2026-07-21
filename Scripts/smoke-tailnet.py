#!/usr/bin/env python3
"""Opt-in, non-mutating two-host Tailnet smoke for CoFleet Host.

The script deliberately accepts pairing codes through ``getpass`` rather than
arguments or environment variables. Redeemed bearer tokens remain in memory
and the temporary paired devices are revoked before the process exits.
"""

import argparse
import getpass
import ipaddress
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple


MAX_RESPONSE_BYTES = 2 * 1024 * 1024
DEFAULT_TIMEOUT_SECONDS = 20.0


class SmokeError(Exception):
    """Failure whose code is safe to print without provider response data."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


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


class TailnetClient:
    """Small bounded HTTPS client that never follows credentialed redirects."""

    def __init__(
        self,
        base_url: str,
        token: Optional[str] = None,
        timeout: float = DEFAULT_TIMEOUT_SECONDS,
    ) -> None:
        self.base_url = validate_tailnet_url(base_url) + "/v1"
        self.token = token
        self.timeout = timeout
        context = ssl.create_default_context()
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=context), _NoRedirect()
        )

    def request(
        self,
        method: str,
        path: str,
        body: Optional[Dict[str, Any]] = None,
    ) -> HTTPResult:
        if not path.startswith("/") or path.startswith("//"):
            raise SmokeError("invalid_request_path")
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        data = None
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self.base_url + path,
            data=data,
            headers=headers,
            method=method,
        )
        try:
            response = self._opener.open(request, timeout=self.timeout)
        except urllib.error.HTTPError as error:
            response = error
        except (OSError, urllib.error.URLError, TimeoutError):
            raise SmokeError("host_unreachable")
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


def validate_tailnet_url(value: str) -> str:
    """Return a normalized private Tailscale Serve origin or fail closed."""

    try:
        split = urllib.parse.urlsplit(value)
        hostname = split.hostname or ""
        port = split.port
    except ValueError:
        raise SmokeError("invalid_private_host_url")
    if (
        split.scheme.lower() != "https"
        or not hostname
        or split.username is not None
        or split.password is not None
        or split.query
        or split.fragment
        or split.path not in ("", "/")
        or port not in (None, 443)
    ):
        raise SmokeError("invalid_private_host_url")
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        pass
    else:
        raise SmokeError("invalid_private_host_url")
    normalized_host = hostname.rstrip(".").lower()
    if not normalized_host.endswith(".ts.net"):
        raise SmokeError("invalid_private_host_url")
    return "https://" + normalized_host


def _expect_json(
    client: TailnetClient,
    method: str,
    path: str,
    expected_status: int,
    body: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    response = client.request(method, path, body)
    if response.status != expected_status:
        raise SmokeError("unexpected_http_status")
    return response.json_object()


def _pair(
    base_url: str,
    code: str,
    label: str,
    client_factory: Callable[[str, Optional[str]], TailnetClient],
) -> Tuple[TailnetClient, str, str, Dict[str, Any]]:
    open_client = client_factory(base_url, None)
    health = _expect_json(open_client, "GET", "/health", 200)
    if health.get("ok") is not True or health.get("service") != "cofleet-host":
        raise SmokeError("invalid_health_response")
    paired = _expect_json(
        open_client,
        "POST",
        "/pairings/redeem",
        201,
        {"code": code, "deviceName": "CoFleet Tailnet Smoke " + label},
    )
    token = paired.get("token")
    device = paired.get("device")
    host = paired.get("host")
    if (
        not isinstance(token, str)
        or len(token) < 32
        or not isinstance(device, dict)
        or not isinstance(device.get("id"), str)
        or not isinstance(host, dict)
    ):
        raise SmokeError("invalid_pairing_response")
    return client_factory(base_url, token), token, device["id"], host


def _verify_host(client: TailnetClient, paired_host: Dict[str, Any]) -> Tuple[str, int, int]:
    payload = _expect_json(client, "GET", "/host", 200)
    host = payload.get("host")
    if not isinstance(host, dict) or host.get("id") != paired_host.get("id"):
        raise SmokeError("host_identity_mismatch")
    host_id = host.get("id")
    if (
        not isinstance(host_id, str)
        or not host_id
        or host.get("transport") != "tailscale-serve"
        or host.get("publicExposureAllowed") is not False
        or host.get("codexAvailable") is not True
    ):
        raise SmokeError("host_not_private_ready")

    account = _expect_json(client, "GET", "/account", 200).get("account")
    if not isinstance(account, dict) or not isinstance(account.get("account"), dict):
        raise SmokeError("codex_not_authenticated")
    models = _expect_json(client, "GET", "/models", 200).get("models")
    projects = _expect_json(client, "GET", "/projects", 200).get("projects")
    profiles = _expect_json(client, "GET", "/permission-profiles", 200).get(
        "permissionProfiles"
    )
    if not isinstance(models, list) or not models or not isinstance(projects, list):
        raise SmokeError("invalid_catalog_response")
    if not isinstance(profiles, list) or len(profiles) != 3:
        raise SmokeError("invalid_permission_profiles")
    return host_id, len(models), len(projects)


def run_tailnet_smoke(
    host_a_url: str,
    host_b_url: str,
    code_reader: Callable[[str], str] = getpass.getpass,
    client_factory: Callable[[str, Optional[str]], TailnetClient] = TailnetClient,
    emit: Callable[[str], None] = print,
) -> None:
    """Pair, verify isolation, and revoke two temporary smoke devices."""

    host_a_url = validate_tailnet_url(host_a_url)
    host_b_url = validate_tailnet_url(host_b_url)
    if host_a_url == host_b_url:
        raise SmokeError("hosts_must_be_distinct")
    code_a = code_reader("Host A one-use pairing code: ").strip()
    code_b = code_reader("Host B one-use pairing code: ").strip()
    if not code_a or not code_b:
        raise SmokeError("pairing_code_required")

    clients: List[Tuple[TailnetClient, str]] = []
    primary_error: Optional[BaseException] = None
    try:
        client_a, token_a, device_a, paired_a = _pair(
            host_a_url, code_a, "A", client_factory
        )
        clients.append((client_a, device_a))
        client_b, token_b, device_b, paired_b = _pair(
            host_b_url, code_b, "B", client_factory
        )
        clients.append((client_b, device_b))

        host_a_id, models_a, projects_a = _verify_host(client_a, paired_a)
        host_b_id, models_b, projects_b = _verify_host(client_b, paired_b)
        if host_a_id == host_b_id:
            raise SmokeError("host_ids_must_be_distinct")

        cross_a = client_factory(host_b_url, token_a).request("GET", "/host")
        cross_b = client_factory(host_a_url, token_b).request("GET", "/host")
        if cross_a.status != 401 or cross_b.status != 401:
            raise SmokeError("cross_host_token_accepted")

        emit("[cofleet-smoke] host_a=private")
        emit("[cofleet-smoke] host_b=private")
        emit("[cofleet-smoke] models_a=%d" % models_a)
        emit("[cofleet-smoke] models_b=%d" % models_b)
        emit("[cofleet-smoke] projects_a=%d" % projects_a)
        emit("[cofleet-smoke] projects_b=%d" % projects_b)
        emit("[cofleet-smoke] token_isolation=ok")
    except BaseException as error:
        primary_error = error
        raise
    finally:
        cleanup_failed = False
        for client, device_id in reversed(clients):
            quoted = urllib.parse.quote(device_id, safe="")
            try:
                revoked = client.request("DELETE", "/devices/" + quoted)
                after = client.request("GET", "/host")
                if revoked.status != 200 or after.status != 401:
                    cleanup_failed = True
            except Exception:
                cleanup_failed = True
        # Drop the last long-lived references before returning. Python strings
        # cannot be zeroed, but no credential is persisted or printed.
        clients.clear()
        if cleanup_failed and primary_error is None:
            raise SmokeError("temporary_device_revocation_failed")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run an opt-in, read-only two-host CoFleet Tailnet smoke."
    )
    parser.add_argument("--host-a", required=True, help="Private HTTPS Tailscale Serve origin")
    parser.add_argument(
        "--host-b", required=True, help="Second private HTTPS Tailscale Serve origin"
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        run_tailnet_smoke(arguments.host_a, arguments.host_b)
    except SmokeError as error:
        print("[cofleet-smoke] failed=" + error.code, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("[cofleet-smoke] failed=cancelled", file=sys.stderr)
        return 130
    except Exception:
        print("[cofleet-smoke] failed=unexpected_error", file=sys.stderr)
        return 1
    print("[cofleet-smoke] tailnet_smoke=passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
