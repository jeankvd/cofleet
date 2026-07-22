import json
import pathlib
import tempfile
import unittest

from cofleet_host.transcript import CodexRolloutTranscriptTail


class TranscriptTailTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.session_id = "019f52f6-50b0-7ba2-8665-e3a9ab849750"
        directory = self.root / "sessions" / "2026" / "07" / "21"
        directory.mkdir(parents=True)
        self.path = directory / ("rollout-example-" + self.session_id + ".jsonl")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_large_rollout_returns_only_latest_conversation_pair(self) -> None:
        rows = [
            self._message("user", "Old question"),
            self._message("assistant", "Old answer", phase="final_answer"),
            {"type": "response_item", "payload": {"type": "custom_tool_call_output", "output": "private tool output"}},
            self._message("user", "Fresh question"),
            self._message("assistant", "Still working", phase="commentary"),
            self._message("assistant", "Fresh answer", phase="final_answer"),
        ]
        self.path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")

        reader = CodexRolloutTranscriptTail(
            self.root,
            large_rollout_threshold=1,
            maximum_tail_bytes=64 * 1024,
        )
        turns = reader.read_if_large(self.session_id)

        self.assertIsNotNone(turns)
        items = turns[0]["items"]
        self.assertEqual([item["role"] for item in items], ["user", "assistant"])
        self.assertEqual([item["text"] for item in items], ["Fresh question", "Fresh answer"])
        self.assertNotIn("private tool output", json.dumps(turns))

    def test_small_rollout_defers_to_app_server(self) -> None:
        self.path.write_text(json.dumps(self._message("user", "Question")) + "\n", encoding="utf-8")
        reader = CodexRolloutTranscriptTail(self.root, large_rollout_threshold=1_000_000)
        self.assertIsNone(reader.read_if_large(self.session_id))

    def test_symlinked_rollout_is_not_read(self) -> None:
        target = self.root / "outside.jsonl"
        target.write_text(json.dumps(self._message("user", "Question")), encoding="utf-8")
        self.path.symlink_to(target)
        reader = CodexRolloutTranscriptTail(self.root, large_rollout_threshold=1)
        self.assertIsNone(reader.read_if_large(self.session_id))

    @staticmethod
    def _message(role: str, text: str, phase=None):
        payload = {
            "type": "message",
            "role": role,
            "id": role + "-id-" + text.replace(" ", "-"),
            "content": [
                {"type": "input_text" if role == "user" else "output_text", "text": text}
            ],
        }
        if phase is not None:
            payload["phase"] = phase
        return {"type": "response_item", "payload": payload}


if __name__ == "__main__":
    unittest.main()
