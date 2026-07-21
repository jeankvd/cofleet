import pathlib
import tempfile
import unittest

from cofleet_host.database import Database
from cofleet_host.errors import APIError
from cofleet_host.util import random_token


class DatabaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.database = Database(pathlib.Path(self.temporary.name) / "host.sqlite3", event_limit=3)

    def tearDown(self) -> None:
        self.database.close()
        self.temporary.cleanup()

    def test_pairing_is_one_use_and_tokens_are_not_returned_from_device_list(self) -> None:
        self.database.create_pairing("ABCDEFGH23", 9_999_999_999, None)
        token = random_token()
        device = self.database.redeem_pairing("ABCDEFGH23", "Phone", token)
        self.assertEqual(self.database.authenticate(token)["id"], device["id"])
        self.assertNotIn("token", self.database.list_devices()[0])
        with self.assertRaises(APIError) as caught:
            self.database.redeem_pairing("ABCDEFGH23", "Other", random_token())
        self.assertEqual(caught.exception.status, 410)

    def test_rotation_invalidates_old_token_and_revoke_invalidates_new_token(self) -> None:
        self.database.create_pairing("ABCDEFGH24", 9_999_999_999, None)
        old = random_token()
        device = self.database.redeem_pairing("ABCDEFGH24", "Mac", old)
        new = random_token()
        self.database.rotate_device(device["id"], new)
        self.assertIsNone(self.database.authenticate(old))
        self.assertIsNotNone(self.database.authenticate(new))
        self.database.revoke_device(device["id"])
        self.assertIsNone(self.database.authenticate(new))

    def test_project_deduplicates_canonical_path_and_removal_does_not_delete_folder(self) -> None:
        root = pathlib.Path(self.temporary.name) / "Project"
        root.mkdir()
        project = self.database.create_project("Project", str(root), str(root.resolve()))
        with self.assertRaises(APIError) as caught:
            self.database.create_project("Duplicate", str(root), str(root.resolve()))
        self.assertEqual(caught.exception.code, "duplicate_project")
        self.database.remove_project(project["id"])
        self.assertTrue(root.is_dir())

    def test_note_and_todo_revisions_detect_conflicts(self) -> None:
        root = pathlib.Path(self.temporary.name) / "Project"
        root.mkdir()
        project = self.database.create_project("Project", str(root), str(root))
        note = self.database.create_note(project["id"], None, "Notes", "one")
        updated = self.database.update_note(note["id"], 1, "Notes", "two")
        self.assertEqual(updated["revision"], 2)
        with self.assertRaises(APIError) as caught:
            self.database.update_note(note["id"], 1, "Notes", "stale")
        self.assertEqual(caught.exception.status, 412)
        first = self.database.create_todo(project["id"], None, "A", False, None)
        second = self.database.create_todo(project["id"], None, "B", False, None)
        self.assertEqual([first["position"], second["position"]], [0, 1])
        changed = self.database.update_todo(second["id"], 1, "B", True, 0)
        self.assertTrue(changed["completed"])

    def test_event_ring_requires_reset_for_expired_cursor(self) -> None:
        for index in range(5):
            self.database.append_event("test", {"index": index})
        events, reset = self.database.events_after(1)
        self.assertTrue(reset)
        self.assertEqual([item["data"]["index"] for item in events], [2, 3, 4])

    def test_idempotency_replays_identical_request_and_rejects_changed_request(self) -> None:
        self.assertIsNone(self.database.claim_idempotency("turn:x", "abcdefgh", "aaa"))
        self.database.complete_idempotency("turn:x", "abcdefgh", 201, {"turn": {"id": "1"}})
        cached = self.database.claim_idempotency("turn:x", "abcdefgh", "aaa")
        self.assertEqual(cached, (201, {"turn": {"id": "1"}}))
        with self.assertRaises(APIError) as caught:
            self.database.claim_idempotency("turn:x", "abcdefgh", "bbb")
        self.assertEqual(caught.exception.code, "idempotency_conflict")

    def test_interaction_claim_is_exactly_once_and_expiry_is_gone(self) -> None:
        interaction = self.database.create_interaction(
            7, "generation-1", "item/fileChange/requestApproval", {}, 60
        )
        claimed = self.database.claim_interaction(interaction["id"], "generation-1")
        self.assertEqual(claimed["state"], "resolving")
        with self.assertRaises(APIError) as caught:
            self.database.claim_interaction(interaction["id"], "generation-2")
        self.assertEqual(caught.exception.status, 409)
        self.database.finish_interaction(interaction["id"], {"decision": "decline"})
        with self.assertRaises(APIError) as resolved:
            self.database.claim_interaction(interaction["id"], "generation-2")
        self.assertEqual(resolved.exception.status, 409)
        expired = self.database.create_interaction(
            8, "generation-1", "item/fileChange/requestApproval", {}, -1
        )
        with self.assertRaises(APIError) as expired_error:
            self.database.claim_interaction(expired["id"], "generation-1")
        self.assertEqual(expired_error.exception.status, 410)


if __name__ == "__main__":
    unittest.main()
