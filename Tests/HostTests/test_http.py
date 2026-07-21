import http.client
import json
import pathlib
import socket
import threading
import time
import unittest

from cofleet_host.http import make_server

from helpers import ServiceFixture


class HTTPTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = ServiceFixture()
        self.device, self.token = self.fixture.pair()
        self.server = make_server(self.fixture.service)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.fixture.close()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        data = None if body is None else json.dumps(body).encode("utf-8")
        merged = dict(headers or {})
        if data is not None:
            merged["Content-Type"] = "application/json"
        connection.request(method, path, body=data, headers=merged)
        response = connection.getresponse()
        payload = response.read()
        result_headers = dict(response.getheaders())
        connection.close()
        return response.status, result_headers, payload

    def test_health_is_open_but_host_requires_bearer_auth(self) -> None:
        status, headers, payload = self.request("GET", "/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(payload)["service"], "cofleet-host")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        status, _, _ = self.request("GET", "/v1/host")
        self.assertEqual(status, 401)
        status, _, payload = self.request(
            "GET", "/v1/host", headers={"Authorization": "Bearer " + self.token}
        )
        self.assertEqual(status, 200)
        self.assertIn("host", json.loads(payload))

    def test_spoofable_funnel_marker_is_not_treated_as_a_security_boundary(self) -> None:
        status, _, payload = self.request(
            "GET",
            "/v1/host",
            headers={
                "Authorization": "Bearer " + self.token,
                "Tailscale-Funnel-Request": "true",
            },
        )
        self.assertEqual(status, 200)
        self.assertIn("host", json.loads(payload))

    def test_sse_once_replays_durable_event(self) -> None:
        self.fixture.service.events.publish("test.event", {"value": 1})
        status, headers, payload = self.request(
            "GET",
            "/v1/events?once=true",
            headers={"Authorization": "Bearer " + self.token, "Last-Event-ID": "0"},
        )
        self.assertEqual(status, 200)
        self.assertTrue(headers["Content-Type"].startswith("text/event-stream"))
        self.assertIn(b"event: test.event", payload)
        self.assertIn(b'"value":1', payload)

    def test_session_sse_checkpoints_filtered_host_events(self) -> None:
        existing, _ = self.fixture.service.events.replay(0)
        after = int(existing[-1]["id"]) if existing else 0
        projected = self.fixture.service.events.publish(
            "turn.updated",
            {
                "type": "turn.updated",
                "sessionID": "thread-other",
                "turn": {"id": "turn-other"},
            },
        )
        status, _, payload = self.request(
            "GET",
            "/v1/sessions/thread-wanted/events?once=true",
            headers={
                "Authorization": "Bearer " + self.token,
                "Last-Event-ID": str(after),
            },
        )
        self.assertEqual(status, 200)
        self.assertIn(("id: %d" % projected["id"]).encode("ascii"), payload)
        self.assertIn(b"event: checkpoint", payload)
        self.assertNotIn(b"turn-other", payload)

    def test_raw_codex_notification_reaches_sse_as_cross_language_fixture(self) -> None:
        existing, _ = self.fixture.service.events.replay(0)
        after = int(existing[-1]["id"]) if existing else 0
        self.fixture.service._on_codex_notification(
            "item/started",
            {
                "threadId": "thread-sample",
                "turnId": "turn-sample",
                "startedAtMs": 1_700_000_001_000,
                "item": {
                    "id": "message-sample",
                    "type": "agentMessage",
                    "text": "Hello from Codex.",
                    "providerPrivate": "not exposed",
                },
            },
        )
        status, _, payload = self.request(
            "GET",
            "/v1/sessions/thread-sample/events?once=true",
            headers={
                "Authorization": "Bearer " + self.token,
                "Last-Event-ID": str(after),
            },
        )
        self.assertEqual(status, 200)
        lines = payload.decode("utf-8").splitlines()
        event_name = next(line[7:] for line in lines if line.startswith("event: "))
        data = json.loads(next(line[6:] for line in lines if line.startswith("data: ")))
        fixture_path = (
            pathlib.Path(__file__).parents[2]
            / "Packages"
            / "CoFleetKit"
            / "Tests"
            / "CoFleetKitTests"
            / "Fixtures"
            / "codex-item-started-projection.json"
        )
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        self.assertEqual(event_name, fixture["event"])
        self.assertEqual(data, fixture["data"])
        self.assertNotIn("providerPrivate", payload.decode("utf-8"))

    def test_error_responses_close_connection(self) -> None:
        status, headers, _ = self.request("GET", "/v1/host")
        self.assertEqual(status, 401)
        self.assertEqual(headers["Connection"], "close")

    def test_live_sse_ends_after_token_revocation(self) -> None:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.request(
            "GET",
            "/v1/events",
            headers={"Authorization": "Bearer " + self.token},
        )
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        started = time.monotonic()
        self.fixture.service.database.revoke_device(self.device["id"])
        replayed = response.read()
        self.assertNotIn(b"auth.revoked", replayed)
        self.assertLess(time.monotonic() - started, 2.5)
        connection.close()


class HardenedHTTPTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = ServiceFixture(
            max_active_http_handlers=4,
            max_active_sse_streams=1,
            http_read_timeout=1.0,
            sse_auth_recheck_interval=0.25,
        )
        self.device, self.token = self.fixture.pair()
        self.server = make_server(self.fixture.service)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.fixture.close()

    def test_second_sse_is_rejected_when_stream_capacity_is_full(self) -> None:
        first = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        first.request("GET", "/v1/events", headers={"Authorization": "Bearer " + self.token})
        first_response = first.getresponse()
        self.assertEqual(first_response.status, 200)
        second = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        second.request(
            "GET",
            "/v1/events?once=true",
            headers={"Authorization": "Bearer " + self.token},
        )
        second_response = second.getresponse()
        self.assertEqual(second_response.status, 503)
        second_response.read()
        self.fixture.service.database.revoke_device(self.device["id"])
        first_response.read()
        first.close()
        second.close()

    def test_handler_capacity_returns_503_without_spawning_an_unbounded_thread(self) -> None:
        acquired = 0
        while self.server.handler_slots.acquire(blocking=False):
            acquired += 1
        try:
            connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
            connection.request("GET", "/v1/health")
            response = connection.getresponse()
            self.assertEqual(response.status, 503)
            self.assertEqual(response.getheader("Connection"), "close")
            response.read()
            connection.close()
        finally:
            for _ in range(acquired):
                self.server.handler_slots.release()

    def test_partial_request_body_hits_read_deadline_and_closes(self) -> None:
        connection = socket.create_connection(("127.0.0.1", self.port), timeout=3)
        try:
            connection.sendall(
                b"POST /v1/pairings/redeem HTTP/1.1\r\n"
                b"Host: localhost\r\nContent-Type: application/json\r\n"
                b"Content-Length: 20\r\n\r\n{"
            )
            response = b""
            while b"408 Request Timeout" not in response and len(response) < 4096:
                chunk = connection.recv(4096)
                if not chunk:
                    break
                response += chunk
            self.assertIn(b"408 Request Timeout", response)
            self.assertIn(b"Connection: close", response)
        finally:
            connection.close()


class PrivateServeIdentityHTTPTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = ServiceFixture(require_private_tailscale=True)
        _, self.token = self.fixture.pair()
        self.server = make_server(self.fixture.service)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.fixture.close()

    def _request(self, headers):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.request("GET", "/v1/host", headers=headers)
        response = connection.getresponse()
        payload = response.read()
        status = response.status
        connection.close()
        return status, payload

    def test_private_mode_requires_serve_identity_headers(self) -> None:
        status, _ = self._request({"Authorization": "Bearer " + self.token})
        self.assertEqual(status, 403)
        status, payload = self._request(
            {
                "Authorization": "Bearer " + self.token,
                "Tailscale-User-Login": "person@example.test",
                "Tailscale-User-Name": "Example Person",
            }
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(payload)["host"]["transport"], "tailscale-serve")


if __name__ == "__main__":
    unittest.main()
