import contextlib
import io
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

from cofleet_host.cli import main as cli_main
from cofleet_host.database import Database
from cofleet_host.errors import APIError
from cofleet_host.service import CoFleetHostService
from cofleet_host.tailscale import PrivateServeConfigurationError, verify_private_serve
from cofleet_host.util import canonical_json

from helpers import ServiceFixture


class SecurityHardeningTests(unittest.TestCase):
    def test_private_serve_verification_requires_matching_proxy_and_funnel_off(self) -> None:
        private = {
            "TCP": {"443": {"HTTPS": True}},
            "Web": {
                "example.ts.net:443": {
                    "Handlers": {"/": {"Proxy": "http://127.0.0.1:47831"}}
                }
            },
            "AllowFunnel": {"example.ts.net:443": False},
        }
        completed = subprocess.CompletedProcess([], 0, json.dumps(private), "")
        with mock.patch("cofleet_host.tailscale.subprocess.run", return_value=completed):
            result = verify_private_serve(47831, "/usr/bin/tailscale")
        self.assertTrue(result["verified"])
        private["AllowFunnel"]["example.ts.net:443"] = True
        completed = subprocess.CompletedProcess([], 0, json.dumps(private), "")
        with mock.patch("cofleet_host.tailscale.subprocess.run", return_value=completed):
            with self.assertRaises(PrivateServeConfigurationError):
                verify_private_serve(47831, "/usr/bin/tailscale")

    def test_private_serve_verification_rejects_wrong_backend(self) -> None:
        wrong = {"Web": {"example.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:9999"}}}}}
        completed = subprocess.CompletedProcess([], 0, json.dumps(wrong), "")
        with mock.patch("cofleet_host.tailscale.subprocess.run", return_value=completed):
            with self.assertRaises(PrivateServeConfigurationError):
                verify_private_serve(47831, "/usr/bin/tailscale")

    def test_cli_refuses_root_without_explicit_dangerous_override(self) -> None:
        with mock.patch("cofleet_host.cli.os.geteuid", return_value=0):
            with mock.patch("cofleet_host.cli.CoFleetHostService") as service:
                self.assertEqual(cli_main(["serve"]), 2)
                service.assert_not_called()

    def test_admin_cli_commands_preserve_live_pending_interactions(self) -> None:
        fixture = ServiceFixture()
        try:
            device, _ = fixture.pair()
            pending = fixture.service.database.create_interaction(
                "rpc-live",
                fixture.codex.generation,
                "item/fileChange/requestApproval",
                {"threadId": "thread-1", "turnId": "turn-1"},
                300,
            )
            commands = (["pair"], ["devices"], ["revoke", device["id"]])
            for command in commands:
                with contextlib.redirect_stdout(io.StringIO()):
                    result = cli_main(
                        ["--data-dir", str(fixture.config.data_dir), *command]
                    )
                self.assertEqual(result, 0)
                self.assertEqual(
                    fixture.service.database.get_interaction(pending["id"])["state"],
                    "pending",
                )
            events, _ = fixture.service.database.events_after(0, 200)
            self.assertNotIn("interaction.invalidated", [event["type"] for event in events])
        finally:
            fixture.close()

    def test_event_payload_storage_and_replay_are_byte_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Database(
                pathlib.Path(temporary) / "events.sqlite3",
                event_limit=20,
                event_payload_limit=256,
                event_storage_limit=600,
                event_replay_limit=10,
                event_replay_bytes=300,
            )
            try:
                first = database.append_event("codex.event", {"raw": "x" * 10_000})
                self.assertTrue(first["data"]["_cofleetTruncated"])
                for index in range(10):
                    database.append_event("codex.event", {"index": index, "value": "y" * 80})
                events, _ = database.events_after(0, 1_000)
                self.assertLessEqual(len(events), 10)
                self.assertLessEqual(
                    sum(len(canonical_json(event["data"]).encode("utf-8")) for event in events),
                    300,
                )
            finally:
                database.close()

    def test_codex_stream_projection_is_bounded_and_never_persists_raw_payload(self) -> None:
        fixture = ServiceFixture(event_payload_limit=32 * 1024, event_storage_limit=64 * 1024)
        try:
            fixture.service._on_codex_notification(
                "item/commandExecution/outputDelta",
                {
                    "threadId": "thread-1",
                    "turnId": "turn-1",
                    "itemId": "item-1",
                    "delta": "secret-output-" + "x" * 1_000_000,
                    "providerOnlyField": [{"text": "do-not-expose"}] * 1_000,
                },
            )
            events, _ = fixture.service.events.replay(0)
            event = next(item for item in events if item["type"] == "turn.item")
            self.assertEqual(event["data"]["type"], "turn.item")
            self.assertNotIn("providerOnlyField", canonical_json(event))
            self.assertNotIn("method", event["data"])
            self.assertIn("Output truncated by CoFleet", event["data"]["item"]["text"])
            self.assertLessEqual(len(canonical_json(event["data"]).encode("utf-8")), 32 * 1024)
        finally:
            fixture.close()

    def test_stale_interaction_generation_cannot_reply_to_new_process(self) -> None:
        fixture = ServiceFixture()
        try:
            fixture.codex.interaction_handler(
                fixture.codex.generation,
                "rpc-old",
                "item/fileChange/requestApproval",
                {"threadId": "thread-1", "turnId": "turn-1"},
            )
            interaction = fixture.service.database.list_interactions()[0]
            fixture.codex.generation = "fake-generation-2"
            with self.assertRaises(APIError) as caught:
                fixture.service._resolve_interaction(
                    interaction["id"], {"decision": "allowOnce"}
                )
            self.assertEqual(caught.exception.status, 410)
            self.assertFalse(fixture.codex.responded)
        finally:
            fixture.close()

    def test_full_to_ask_turn_sends_complete_sandbox_regression(self) -> None:
        fixture = ServiceFixture()
        try:
            project = fixture.project()
            fixture.codex.responses["thread/start"] = {"thread": {"id": "thread-1"}}
            device, _ = fixture.pair()
            fixture.service.dispatch(
                "POST",
                "/v1/sessions",
                {},
                {},
                {"projectID": project["id"], "accessLevel": "full_access"},
                device,
            )
            fixture.codex.responses["turn/start"] = {"turn": {"id": "turn-1"}}
            fixture.service.dispatch(
                "POST",
                "/v1/sessions/thread-1/turns",
                {},
                {"Idempotency-Key": "ask-regression-1"},
                {"message": "safe", "accessLevel": "ask_for_approval"},
                device,
            )
            params = next(
                params for method, params in reversed(fixture.codex.requests) if method == "turn/start"
            )
            self.assertEqual(params["approvalPolicy"], "untrusted")
            self.assertEqual(params["approvalsReviewer"], "user")
            self.assertEqual(
                params["sandboxPolicy"],
                {"type": "workspaceWrite", "networkAccess": False, "writableRoots": []},
            )
            self.assertNotIn("sandbox", params)
            settings = fixture.service.database.get_session_settings("thread-1")
            self.assertEqual(settings["accessLevel"], "ask_for_approval")
        finally:
            fixture.close()

    @unittest.skipUnless(pathlib.Path("/usr/bin/git").exists(), "system Git required")
    def test_git_status_disables_repo_controlled_fsmonitor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "repo"
            root.mkdir()
            subprocess.run(["/usr/bin/git", "init", "-q", str(root)], check=True)
            sentinel = pathlib.Path(temporary) / "fsmonitor-ran"
            monitor = root / "monitor.sh"
            monitor.write_text("#!/bin/sh\necho ran >> '%s'\nexit 1\n" % sentinel, encoding="utf-8")
            monitor.chmod(0o700)
            subprocess.run(
                ["/usr/bin/git", "-C", str(root), "config", "core.fsmonitor", str(monitor)],
                check=True,
            )
            status = CoFleetHostService._git_status(str(root))
            self.assertIn(status["state"], ("clean", "dirty", "staged", "unpushed"))
            self.assertFalse(sentinel.exists())


if __name__ == "__main__":
    unittest.main()
