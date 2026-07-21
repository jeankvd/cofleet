import importlib.util
import io
import pathlib
import unittest
from contextlib import redirect_stderr
from typing import Any, Dict, Optional
from unittest import mock


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]


def load_script(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, REPOSITORY_ROOT / "Scripts" / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load smoke script")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


LIVE = load_script("cofleet_smoke_live", "smoke-live-codex.py")
TAILNET = load_script("cofleet_smoke_tailnet", "smoke-tailnet.py")


class FakeLocalClient:
    def __init__(self) -> None:
        self.requests = []

    def request(self, method, path, body=None, headers=None, accept="application/json"):
        self.requests.append((method, path, body, headers, accept))
        if path == "/health":
            payload = {"ok": True, "service": "cofleet-host", "version": "test"}
        elif path == "/host":
            payload = {
                "host": {
                    "id": "host-private-value",
                    "transport": "loopback",
                    "homePath": "/private/example/path",
                }
            }
        elif path == "/account":
            payload = {
                "account": {
                    "account": {
                        "email": "private-account@example.invalid",
                        "type": "chatgpt",
                    }
                }
            }
        elif path == "/models":
            payload = {
                "models": [
                    {"id": "model-private-name", "isDefault": True},
                    {"id": "model-other"},
                ]
            }
        elif path == "/permission-profiles":
            payload = {"permissionProfiles": [{}, {}, {}]}
        elif path == "/projects/suggestions?limit=5":
            payload = {
                "suggestions": [
                    {"name": "Private Project Title", "rootPath": "/private/project"}
                ]
            }
        elif method == "POST" and path == "/projects":
            payload = {"project": {"id": "project-private-id", "canonicalPath": body["rootPath"]}}
        elif path == "/projects/project-private-id/sessions?limit=5":
            payload = {
                "sessions": [
                    {"id": "thread-private-id", "title": "Private Task Title"}
                ],
                "nextCursor": "private-cursor",
            }
        elif method == "POST" and path == "/sessions/session-private-id/archive":
            payload = {"sessionID": "session-private-id", "archived": True}
        else:
            return LIVE.HTTPResult(404, b"{}", {})
        import json

        return LIVE.HTTPResult(
            201 if method == "POST" and path == "/projects" else 200,
            json.dumps(payload).encode("utf-8"),
            {"Content-Type": "application/json"},
        )


class FakeHarness:
    def __init__(self, _codex: str, _timeout: float) -> None:
        self.client = FakeLocalClient()
        self.workspace = pathlib.Path("/synthetic/smoke-workspace")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return None


class LiveSmokeTests(unittest.TestCase):
    def test_read_only_is_default_and_live_modes_require_literal_confirmation(self) -> None:
        self.assertEqual(LIVE.parse_options([]).mode, "read-only")
        self.assertEqual(LIVE.parse_options(["--read-only"]).mode, "read-only")
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                LIVE.parse_options(["--safe-turn"])
            with self.assertRaises(SystemExit):
                LIVE.parse_options(["--approval-probes"])
            with self.assertRaises(SystemExit):
                LIVE.parse_options(["--confirm-live-usage"])
        self.assertEqual(
            LIVE.parse_options(["--safe-turn", "--confirm-live-usage"]).mode,
            "safe-turn",
        )
        self.assertEqual(
            LIVE.parse_options(["--approval-probes", "--confirm-live-usage"]).mode,
            "approval-probes",
        )

    def test_read_only_output_contains_counts_but_no_provider_or_workspace_values(self) -> None:
        client = FakeLocalClient()
        output = []
        project_id, model = LIVE.run_read_only_checks(
            client, pathlib.Path("/synthetic/workspace"), output.append
        )
        self.assertEqual(project_id, "project-private-id")
        self.assertEqual(model, "model-private-name")
        rendered = "\n".join(output)
        self.assertIn("models=2", rendered)
        self.assertIn("session_page_items=1", rendered)
        for private_value in (
            "private-account",
            "Private Project Title",
            "Private Task Title",
            "model-private-name",
            "/synthetic/workspace",
            "thread-private-id",
            "private-cursor",
        ):
            self.assertNotIn(private_value, rendered)

    def test_live_session_is_archived_when_a_later_probe_fails(self) -> None:
        harnesses = []

        def factory(codex, timeout):
            harness = FakeHarness(codex, timeout)
            harnesses.append(harness)
            return harness

        def failing_turn(client, project_id, model, timeout, approvals, emit, tracker):
            tracker.append("session-private-id")
            raise LIVE.SmokeError("synthetic_probe_failed")

        output = []
        options = LIVE.LiveOptions("safe-turn", "codex", 30.0)
        with mock.patch.object(LIVE, "run_safe_turn", side_effect=failing_turn):
            with self.assertRaises(LIVE.SmokeError) as caught:
                LIVE.run_live_smoke(options, harness_factory=factory, emit=output.append)
        self.assertEqual(caught.exception.code, "synthetic_probe_failed")
        paths = [(method, path) for method, path, *_ in harnesses[0].client.requests]
        self.assertIn(("POST", "/sessions/session-private-id/archive"), paths)
        self.assertIn("[cofleet-smoke] archive_cleanup=ok", output)

    def test_public_failure_output_does_not_echo_exception_detail(self) -> None:
        secret = "private-response-body-and-path"
        stderr = io.StringIO()
        with mock.patch.object(
            LIVE, "run_live_smoke", side_effect=RuntimeError(secret)
        ), redirect_stderr(stderr):
            result = LIVE.main(["--read-only"])
        self.assertEqual(result, 1)
        self.assertIn("unexpected_error", stderr.getvalue())
        self.assertNotIn(secret, stderr.getvalue())


class FakeTailnetBackend:
    def __init__(self, name: str, code: str, token: str, fail_models: bool = False) -> None:
        self.name = name
        self.code = code
        self.token = token
        self.device_id = "device-" + name
        self.host_id = "host-" + name
        self.revoked = False
        self.fail_models = fail_models

    def response(
        self,
        token: Optional[str],
        method: str,
        path: str,
        body: Optional[Dict[str, Any]],
    ):
        import json

        def result(status: int, payload: Dict[str, Any]):
            return TAILNET.HTTPResult(
                status,
                json.dumps(payload).encode("utf-8"),
                {"Content-Type": "application/json"},
            )

        if method == "GET" and path == "/health":
            return result(200, {"ok": True, "service": "cofleet-host", "version": "test"})
        if method == "POST" and path == "/pairings/redeem":
            if body is None or body.get("code") != self.code:
                return result(410, {"error": {"code": "gone"}})
            return result(
                201,
                {
                    "token": self.token,
                    "device": {"id": self.device_id},
                    "host": {"id": self.host_id},
                },
            )
        if token != self.token or self.revoked:
            return result(401, {"error": {"code": "invalid_token"}})
        if method == "DELETE" and path == "/devices/" + self.device_id:
            self.revoked = True
            return result(200, {"device": {"id": self.device_id}})
        if path == "/host":
            return result(
                200,
                {
                    "host": {
                        "id": self.host_id,
                        "displayName": "Private Host Name",
                        "transport": "tailscale-serve",
                        "publicExposureAllowed": False,
                        "codexAvailable": True,
                    }
                },
            )
        if path == "/account":
            return result(
                200,
                {"account": {"account": {"email": "private-account@example.invalid"}}},
            )
        if path == "/models":
            if self.fail_models:
                return result(503, {"error": {"message": "private response detail"}})
            return result(200, {"models": [{"id": "private-model"}]})
        if path == "/projects":
            return result(200, {"projects": [{"name": "Private Project"}]})
        if path == "/permission-profiles":
            return result(200, {"permissionProfiles": [{}, {}, {}]})
        return result(404, {"error": {"code": "not_found"}})


class FakeTailnetClient:
    def __init__(self, backend: FakeTailnetBackend, token: Optional[str]) -> None:
        self.backend = backend
        self.token = token

    def request(self, method, path, body=None):
        return self.backend.response(self.token, method, path, body)


class TailnetSmokeTests(unittest.TestCase):
    def test_only_private_https_tsnet_origins_are_accepted(self) -> None:
        accepted = "https://alpha.synthetic-tailnet.ts.net"
        self.assertEqual(TAILNET.validate_tailnet_url(accepted + "/"), accepted)
        for rejected in (
            "http://alpha.synthetic-tailnet.ts.net",
            "https://203.0.113.1",
            "https://public.example.invalid",
            "https://user@alpha.synthetic-tailnet.ts.net",
            "https://alpha.synthetic-tailnet.ts.net/private/path",
            "https://alpha.synthetic-tailnet.ts.net:8443",
        ):
            with self.assertRaises(TAILNET.SmokeError):
                TAILNET.validate_tailnet_url(rejected)

    def _factory(self, backends):
        def make(base_url, token):
            normalized = TAILNET.validate_tailnet_url(base_url)
            return FakeTailnetClient(backends[normalized], token)

        return make

    def test_pairing_tokens_are_isolated_redacted_and_revoked(self) -> None:
        host_a = "https://alpha.synthetic-tailnet.ts.net"
        host_b = "https://beta.synthetic-tailnet.ts.net"
        backend_a = FakeTailnetBackend("a", "CODE-A", "token-a-" + "x" * 40)
        backend_b = FakeTailnetBackend("b", "CODE-B", "token-b-" + "y" * 40)
        backends = {host_a: backend_a, host_b: backend_b}
        codes = iter(("CODE-A", "CODE-B"))
        output = []
        TAILNET.run_tailnet_smoke(
            host_a,
            host_b,
            code_reader=lambda _prompt: next(codes),
            client_factory=self._factory(backends),
            emit=output.append,
        )
        self.assertTrue(backend_a.revoked)
        self.assertTrue(backend_b.revoked)
        rendered = "\n".join(output)
        self.assertIn("token_isolation=ok", rendered)
        for private_value in (
            "CODE-A",
            "CODE-B",
            backend_a.token,
            backend_b.token,
            host_a,
            host_b,
            "Private Host Name",
            "Private Project",
            "private-model",
        ):
            self.assertNotIn(private_value, rendered)

    def test_both_temporary_devices_are_revoked_when_verification_fails(self) -> None:
        host_a = "https://alpha.synthetic-tailnet.ts.net"
        host_b = "https://beta.synthetic-tailnet.ts.net"
        backend_a = FakeTailnetBackend("a", "CODE-A", "token-a-" + "x" * 40)
        backend_b = FakeTailnetBackend(
            "b", "CODE-B", "token-b-" + "y" * 40, fail_models=True
        )
        backends = {host_a: backend_a, host_b: backend_b}
        codes = iter(("CODE-A", "CODE-B"))
        with self.assertRaises(TAILNET.SmokeError):
            TAILNET.run_tailnet_smoke(
                host_a,
                host_b,
                code_reader=lambda _prompt: next(codes),
                client_factory=self._factory(backends),
                emit=lambda _line: None,
            )
        self.assertTrue(backend_a.revoked)
        self.assertTrue(backend_b.revoked)


if __name__ == "__main__":
    unittest.main()
