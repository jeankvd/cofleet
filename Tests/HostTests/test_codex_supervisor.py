import pathlib
import stat
import sys
import tempfile
import textwrap
import threading
import time
import unittest

from cofleet_host.codex import CodexAppServerSupervisor
from cofleet_host.errors import CodexUnavailable


FAKE_SERVER = r'''
import json
import sys
import time

for line in sys.stdin:
    envelope = json.loads(line)
    method = envelope.get("method")
    if "id" not in envelope:
        continue
    request_id = envelope["id"]
    if method == "initialize":
        result = {"serverInfo": {"name": "fake"}}
    elif method == "ping":
        result = {"pong": envelope.get("params", {}).get("value")}
    elif method == "notify":
        print(json.dumps({"method": "turn/completed", "params": {"threadId": "t1"}}), flush=True)
        result = {"ok": True}
    elif method == "interaction":
        print(json.dumps({"id": "rpc-approval", "method": "item/commandExecution/requestApproval", "params": {"threadId": "t1", "turnId": "x"}}), flush=True)
        result = {"ok": True}
    elif method == "slow":
        time.sleep(0.5)
        result = {"ok": True}
    else:
        result = {}
    print(json.dumps({"id": request_id, "result": result}), flush=True)
'''


class CodexSupervisorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.script = pathlib.Path(self.temporary.name) / "fake_app_server.py"
        self.script.write_text(textwrap.dedent(FAKE_SERVER), encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_initializes_once_routes_notifications_and_interactions(self) -> None:
        notifications = []
        interactions = []
        signal = threading.Event()

        def on_notification(method, params):
            notifications.append((method, params))
            signal.set()

        def on_interaction(generation, rpc_id, method, params):
            interactions.append((generation, rpc_id, method, params))
            signal.set()

        supervisor = CodexAppServerSupervisor(
            (sys.executable, str(self.script)),
            timeout=2,
            notification_handler=on_notification,
            interaction_handler=on_interaction,
        )
        try:
            self.assertEqual(supervisor.request("ping", {"value": 7})["pong"], 7)
            supervisor.request("notify")
            self.assertTrue(signal.wait(1))
            supervisor.request("interaction")
            deadline = time.time() + 1
            while not interactions and time.time() < deadline:
                time.sleep(0.01)
            self.assertEqual(notifications[0][0], "turn/completed")
            self.assertTrue(interactions[0][0].startswith("codexgen_"))
            self.assertEqual(interactions[0][1], "rpc-approval")
            supervisor.respond(
                "rpc-approval",
                {"decision": "decline"},
                expected_generation=interactions[0][0],
            )
            with self.assertRaises(CodexUnavailable):
                supervisor.respond(
                    "rpc-approval",
                    {"decision": "accept"},
                    expected_generation="old-generation",
                )
        finally:
            supervisor.close()

    def test_missing_executable_is_reported_without_shell_fallback(self) -> None:
        supervisor = CodexAppServerSupervisor(("definitely-not-a-real-codex-binary", "app-server"))
        try:
            self.assertFalse(supervisor.available())
            with self.assertRaises(CodexUnavailable):
                supervisor.request("ping")
        finally:
            supervisor.close()

    def test_concurrent_rpc_limit_fails_closed_when_capacity_is_full(self) -> None:
        supervisor = CodexAppServerSupervisor(
            (sys.executable, str(self.script)), timeout=2, max_concurrent_requests=1
        )
        failure = []

        def slow_request():
            try:
                supervisor.request("slow")
            except Exception as error:
                failure.append(error)

        worker = threading.Thread(target=slow_request)
        try:
            worker.start()
            time.sleep(0.1)
            with self.assertRaises(CodexUnavailable):
                supervisor.request("ping", timeout=0.05)
            worker.join(2)
            self.assertFalse(failure)
        finally:
            supervisor.close()


if __name__ == "__main__":
    unittest.main()
