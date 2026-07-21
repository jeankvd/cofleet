import json
import pathlib
import unittest

from cofleet_host.errors import APIError

from helpers import ServiceFixture


class EventProjectionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = ServiceFixture()
        self.service = self.fixture.service
        self.codex = self.fixture.codex
        self.device, _ = self.fixture.pair()

    def tearDown(self) -> None:
        self.fixture.close()

    def events(self):
        return self.service.events.replay(0)[0]

    def test_turn_items_are_provider_neutral_snapshot_upserts(self) -> None:
        self.service._on_codex_notification(
            "turn/started",
            {
                "threadId": "thread-1",
                "turn": {
                    "id": "turn-1",
                    "status": "inProgress",
                    "startedAt": 1_700_000_000,
                    "items": [],
                },
            },
        )
        self.service._on_codex_notification(
            "item/started",
            {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "startedAtMs": 1_700_000_001_000,
                "item": {"id": "message-1", "type": "agentMessage", "text": ""},
            },
        )
        for delta in ("Hel", "lo"):
            self.service._on_codex_notification(
                "item/agentMessage/delta",
                {
                    "threadId": "thread-1",
                    "turnId": "turn-1",
                    "itemId": "message-1",
                    "delta": delta,
                },
            )
        self.service._on_codex_notification(
            "item/completed",
            {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "completedAtMs": 1_700_000_002_000,
                "item": {"id": "message-1", "type": "agentMessage", "text": "Hello"},
            },
        )
        self.service._on_codex_notification(
            "turn/completed",
            {
                "threadId": "thread-1",
                "turn": {
                    "id": "turn-1",
                    "status": "completed",
                    "startedAt": 1_700_000_000,
                    "completedAt": 1_700_000_002,
                    "items": [],
                },
            },
        )

        events = self.events()
        projected_types = [event["type"] for event in events]
        self.assertNotIn("codex.event", projected_types)
        turn_events = [event["data"]["turn"] for event in events if event["type"] == "turn.updated"]
        self.assertEqual(turn_events[0]["hostID"], self.service.host_id)
        self.assertEqual(turn_events[0]["sessionID"], "thread-1")
        self.assertEqual(turn_events[0]["state"], "running")
        self.assertEqual(turn_events[-1]["state"], "completed")
        snapshots = [event["data"]["item"] for event in events if event["type"] == "turn.item"]
        self.assertEqual([item["text"] for item in snapshots], ["", "Hel", "Hello", "Hello"])
        self.assertTrue(all(item["kind"] == "assistantMessage" for item in snapshots))
        self.assertEqual(snapshots[-1]["state"], "completed")
        self.assertEqual(snapshots[-1]["createdAt"], "2023-11-14T22:13:22Z")

    def test_raw_codex_item_matches_cross_language_sse_contract_fixture(self) -> None:
        self.service._on_codex_notification(
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
        projected = [event for event in self.events() if event["type"] == "turn.item"][-1]
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
        self.assertEqual(projected["type"], fixture["event"])
        self.assertEqual(projected["data"], fixture["data"])
        self.assertNotIn("providerPrivate", json.dumps(projected))

    def test_reasoning_command_and_tool_activity_are_typed(self) -> None:
        cases = (
            ("item/reasoning/textDelta", "reasoning", "Thinking"),
            ("item/commandExecution/outputDelta", "command", "command output"),
            ("item/mcpToolCall/progress", "tool", "tool progress"),
        )
        for index, (method, kind, text) in enumerate(cases):
            params = {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "item-%d" % index,
            }
            params["message" if method.endswith("progress") else "delta"] = text
            self.service._on_codex_notification(method, params)
        items = [event["data"]["item"] for event in self.events() if event["type"] == "turn.item"]
        self.assertEqual([(item["kind"], item["text"]) for item in items], [(c[1], c[2]) for c in cases])

    def test_unknown_codex_notification_is_not_persisted(self) -> None:
        before = self.events()
        self.service._on_codex_notification(
            "future/providerPrivateEvent",
            {"threadId": "thread-1", "secret": "must-not-cross-the-facade"},
        )
        self.assertEqual(self.events(), before)

    def test_question_interaction_projects_options_and_resolves_all_answers(self) -> None:
        self.codex.interaction_handler(
            self.codex.generation,
            "rpc-question",
            "item/tool/requestUserInput",
            {
                "threadId": "thread-1",
                "turnId": "turn-1",
                "itemId": "item-1",
                "questions": [
                    {
                        "id": "target",
                        "header": "Target",
                        "question": "Which target?",
                        "options": [
                            {"label": "Simulator", "description": "Use a simulator."},
                            {"label": "Device", "description": "Use a device."},
                        ],
                    },
                    {
                        "id": "note",
                        "header": "Note",
                        "question": "Anything else?",
                        "options": None,
                        "isOther": True,
                    },
                ],
            },
        )
        interaction = self.service.database.list_interactions()[0]
        pending = next(event for event in self.events() if event["type"] == "interaction.pending")
        model = pending["data"]["interaction"]
        self.assertEqual(model["kind"], "question")
        self.assertEqual(model["hostID"], self.service.host_id)
        self.assertNotIn("params", model)
        self.assertNotIn("method", model)
        self.assertEqual(model["questions"][0]["options"][1]["label"], "Device")
        self.assertTrue(model["questions"][1]["allowsFreeform"])

        with self.assertRaises(APIError) as incomplete:
            self.service._resolve_interaction(
                interaction["id"],
                {"decision": "submitAnswer", "answers": {"target": ["Device"]}},
            )
        self.assertEqual(incomplete.exception.status, 422)
        self.service._resolve_interaction(
            interaction["id"],
            {
                "decision": "submitAnswer",
                "answers": {"target": ["Device"], "note": ["Run the focused tests."]},
            },
        )
        self.assertEqual(
            self.codex.responded[-1],
            (
                "rpc-question",
                {
                    "answers": {
                        "target": {"answers": ["Device"]},
                        "note": {"answers": ["Run the focused tests."]},
                    }
                },
            ),
        )
        self.assertTrue(any(event["type"] == "interaction.resolved" for event in self.events()))
        with self.assertRaises(APIError) as duplicate:
            self.service._resolve_interaction(
                interaction["id"],
                {
                    "decision": "submitAnswer",
                    "answers": {"target": ["Simulator"], "note": ["Again"]},
                },
            )
        self.assertEqual(duplicate.exception.status, 409)

    def test_expiry_and_codex_restart_emit_stable_events(self) -> None:
        expired = self.service.database.create_interaction(
            "rpc-expired",
            self.codex.generation,
            "item/fileChange/requestApproval",
            {"threadId": "thread-1", "turnId": "turn-1"},
            -1,
        )
        self.service.run_maintenance_once()
        event = next(event for event in self.events() if event["type"] == "interaction.expired")
        self.assertEqual(
            event["data"],
            {
                "type": "interaction.expired",
                "interactionID": expired["id"],
                "sessionID": "thread-1",
            },
        )
        self.service._on_codex_notification(
            "cofleet/codexUnavailable", {"processGeneration": self.codex.generation, "raw": "hidden"}
        )
        reset = [event for event in self.events() if event["type"] == "stream.reset"][-1]
        self.assertEqual(reset["data"]["type"], "stream.reset")
        self.assertNotIn("raw", reset["data"])
        self.assertTrue(self.service.event_matches_session(reset, "thread-any"))


if __name__ == "__main__":
    unittest.main()
