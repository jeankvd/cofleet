import pathlib
import unittest

from cofleet_host.errors import APIError
from cofleet_host.service import ACCESS_PROFILES, SSERequest
from cofleet_host.util import make_etag

from helpers import ServiceFixture


class ServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = ServiceFixture()
        self.service = self.fixture.service
        self.codex = self.fixture.codex
        self.device, self.token = self.fixture.pair()
        self.project = self.fixture.project()

    def tearDown(self) -> None:
        self.fixture.close()

    def dispatch(self, method, path, body=None, query=None, headers=None):
        return self.service.dispatch(
            method, path, query or {}, headers or {}, body or {}, self.device
        )

    def test_host_models_and_access_profiles_are_provider_native(self) -> None:
        self.codex.responses["model/list"] = {
            "data": [
                {
                    "model": "gpt-example",
                    "displayName": "GPT Example",
                    "isDefault": True,
                    "supportedReasoningEfforts": [{"reasoningEffort": "high"}],
                    "serviceTiers": [{"id": "priority"}],
                }
            ]
        }
        host = self.dispatch("GET", "/v1/host").payload["host"]
        self.assertEqual(host["transport"], "loopback")
        self.assertFalse(host["publicExposureAllowed"])
        models = self.dispatch("GET", "/v1/models").payload["models"]
        self.assertEqual(models[0]["id"], "gpt-example")
        profiles = self.dispatch("GET", "/v1/permission-profiles").payload["permissionProfiles"]
        by_id = {item["id"]: item for item in profiles}
        self.assertEqual(by_id["ask_for_approval"]["approvalPolicy"], "untrusted")
        self.assertEqual(by_id["approve_for_me"]["approvalsReviewer"], "auto_review")
        self.assertEqual(by_id["full_access"]["sandbox"], "danger-full-access")

    def test_account_login_only_uses_official_chatgpt_flows(self) -> None:
        self.codex.responses["account/read"] = {"account": {"type": "chatgpt"}}
        account = self.dispatch("GET", "/v1/account").payload
        self.assertEqual(account["account"]["account"]["type"], "chatgpt")
        self.codex.responses["account/login/start"] = {
            "type": "chatgptDeviceCode",
            "loginId": "login-1",
            "userCode": "ABCD-EFGH",
            "verificationUrl": "https://example.invalid/device",
        }
        response = self.dispatch(
            "POST", "/v1/account/login", {"type": "chatgptDeviceCode"}
        ).payload
        self.assertEqual(response["login"]["loginId"], "login-1")
        with self.assertRaises(APIError):
            self.dispatch("POST", "/v1/account/login", {"type": "apiKey"})

    def test_account_limits_are_read_without_consuming_reset_credits(self) -> None:
        self.codex.responses["account/rateLimits/read"] = {
            "rateLimits": {
                "limitId": "codex",
                "primary": {"usedPercent": 12, "resetsAt": 2_000_000_000},
            },
            "rateLimitResetCredits": {"availableCount": 1, "credits": None},
        }
        response = self.dispatch("GET", "/v1/account/limits").payload["limits"]
        self.assertEqual(response["rateLimits"]["primary"]["usedPercent"], 12)
        self.assertEqual(self.codex.requests[-1], ("account/rateLimits/read", {}))
        self.assertNotIn(
            "account/rateLimits/resetCredits/consume",
            [method for method, _ in self.codex.requests],
        )

    def test_thread_list_is_five_item_paginated_without_transcript_reads(self) -> None:
        self.codex.responses["thread/list"] = {
            "data": [{"id": "thread-1", "name": "Latest", "cwd": self.project["canonicalPath"]}],
            "nextCursor": "codex-next",
        }
        response = self.dispatch(
            "GET",
            "/v1/projects/%s/sessions" % self.project["id"],
            query={"limit": "5", "cursor": "codex-cursor"},
        ).payload
        self.assertEqual(response["nextCursor"], "codex-next")
        method, params = self.codex.requests[-1]
        self.assertEqual(method, "thread/list")
        self.assertEqual(params["limit"], 5)
        self.assertEqual(params["cursor"], "codex-cursor")
        self.assertNotIn("thread/read", [item[0] for item in self.codex.requests])

    def test_session_and_turn_apply_access_mapping_and_idempotency(self) -> None:
        self.codex.responses["thread/start"] = {"thread": {"id": "thread-1", "name": "New"}}
        created = self.dispatch(
            "POST",
            "/v1/sessions",
            {
                "projectID": self.project["id"],
                "accessLevel": "approve_for_me",
                "model": "gpt-example",
                "reasoningEffort": "high",
            },
        )
        self.assertEqual(created.status, 201)
        start_params = self.codex.requests[-1][1]
        self.assertEqual(start_params["approvalPolicy"], "on-request")
        self.assertEqual(start_params["approvalsReviewer"], "auto_review")
        self.assertEqual(start_params["sandbox"], "workspace-write")
        self.assertNotIn("sandboxPolicy", start_params)
        self.codex.responses["turn/start"] = {"turn": {"id": "turn-1", "status": "inProgress"}}
        body = {"message": "hello"}
        first = self.dispatch(
            "POST",
            "/v1/sessions/thread-1/turns",
            body,
            headers={"Idempotency-Key": "request-123"},
        )
        second = self.dispatch(
            "POST",
            "/v1/sessions/thread-1/turns",
            body,
            headers={"Idempotency-Key": "request-123"},
        )
        self.assertEqual(first.payload, second.payload)
        self.assertEqual([item[0] for item in self.codex.requests].count("turn/start"), 1)
        turn_params = self.codex.requests[-1][1]
        self.assertEqual(turn_params["approvalPolicy"], "on-request")
        self.assertEqual(turn_params["approvalsReviewer"], "auto_review")
        self.assertEqual(
            turn_params["sandboxPolicy"],
            {"type": "workspaceWrite", "networkAccess": False, "writableRoots": []},
        )
        self.assertNotIn("sandbox", turn_params)

    def test_turn_access_profiles_replace_full_access_with_exact_protocol_shape(self) -> None:
        self.codex.responses["thread/start"] = {"thread": {"id": "thread-1", "name": "New"}}
        self.dispatch(
            "POST",
            "/v1/sessions",
            {"projectID": self.project["id"], "accessLevel": "full_access"},
        )
        thread_params = self.codex.requests[-1][1]
        self.assertEqual(thread_params["sandbox"], "danger-full-access")
        self.assertNotIn("sandboxPolicy", thread_params)

        self.codex.responses["turn/start"] = {"turn": {"id": "turn-1", "status": "inProgress"}}
        cases = (
            (
                "ask_for_approval",
                {
                    "approvalPolicy": "untrusted",
                    "approvalsReviewer": "user",
                    "sandboxPolicy": {
                        "type": "workspaceWrite",
                        "networkAccess": False,
                        "writableRoots": [],
                    },
                },
            ),
            (
                "full_access",
                {
                    "approvalPolicy": "never",
                    "approvalsReviewer": "user",
                    "sandboxPolicy": {"type": "dangerFullAccess"},
                },
            ),
            (
                "approve_for_me",
                {
                    "approvalPolicy": "on-request",
                    "approvalsReviewer": "auto_review",
                    "sandboxPolicy": {
                        "type": "workspaceWrite",
                        "networkAccess": False,
                        "writableRoots": [],
                    },
                },
            ),
        )
        for index, (access_level, expected_profile) in enumerate(cases):
            message = "profile %s" % access_level
            self.dispatch(
                "POST",
                "/v1/sessions/thread-1/turns",
                {"message": message, "accessLevel": access_level},
                headers={"Idempotency-Key": "profile-request-%d" % index},
            )
            method, params = self.codex.requests[-1]
            self.assertEqual(method, "turn/start")
            self.assertEqual(
                params,
                {
                    "threadId": "thread-1",
                    "input": [{"type": "text", "text": message}],
                    **expected_profile,
                },
            )
            self.assertNotIn("sandbox", params)

        settings = self.service.database.get_session_settings("thread-1")
        self.assertEqual(settings["accessLevel"], "approve_for_me")

    def test_discovered_session_turn_validates_project_and_persists_settings(self) -> None:
        other_project = self.fixture.project("Other")
        self.codex.responses["thread/read"] = {
            "thread": {
                "id": "thread-imported",
                "cwd": self.project["canonicalPath"],
            }
        }
        self.codex.responses["turn/start"] = {
            "turn": {"id": "turn-imported", "status": "inProgress"}
        }

        request_count = len(self.codex.requests)
        with self.assertRaises(APIError) as missing:
            self.dispatch(
                "POST",
                "/v1/sessions/thread-imported/turns",
                {"message": "missing project"},
                headers={"Idempotency-Key": "import-missing-project"},
            )
        self.assertEqual(missing.exception.status, 422)
        self.assertEqual(missing.exception.code, "project_required")
        self.assertEqual(len(self.codex.requests), request_count)

        with self.assertRaises(APIError) as mismatch:
            self.dispatch(
                "POST",
                "/v1/sessions/thread-imported/turns",
                {"message": "wrong project", "projectID": other_project["id"]},
                headers={"Idempotency-Key": "import-wrong-project"},
            )
        self.assertEqual(mismatch.exception.status, 409)
        self.assertEqual(mismatch.exception.code, "session_project_mismatch")
        self.assertEqual(
            self.codex.requests[-1],
            ("thread/read", {"threadId": "thread-imported", "includeTurns": False}),
        )
        self.assertIsNone(self.service.database.get_session_settings("thread-imported"))

        response = self.dispatch(
            "POST",
            "/v1/sessions/thread-imported/turns",
            {
                "message": "owned project",
                "projectID": self.project["id"],
                "accessLevel": "approve_for_me",
                "model": "gpt-example",
                "reasoningEffort": "high",
                "serviceTier": "priority",
            },
            headers={"Idempotency-Key": "import-owned-project"},
        )
        self.assertEqual(response.status, 201)
        self.assertEqual(
            self.codex.requests[-2],
            ("thread/read", {"threadId": "thread-imported", "includeTurns": False}),
        )
        self.assertEqual(
            self.codex.requests[-1],
            (
                "turn/start",
                {
                    "threadId": "thread-imported",
                    "input": [{"type": "text", "text": "owned project"}],
                    "approvalPolicy": "on-request",
                    "approvalsReviewer": "auto_review",
                    "sandboxPolicy": {
                        "type": "workspaceWrite",
                        "networkAccess": False,
                        "writableRoots": [],
                    },
                    "model": "gpt-example",
                    "effort": "high",
                    "serviceTier": "priority",
                },
            ),
        )
        settings = self.service.database.get_session_settings("thread-imported")
        self.assertEqual(settings["projectID"], self.project["id"])
        self.assertEqual(settings["accessLevel"], "approve_for_me")
        self.assertEqual(settings["model"], "gpt-example")
        self.assertEqual(settings["reasoningEffort"], "high")
        self.assertEqual(settings["serviceTier"], "priority")

        request_count = len(self.codex.requests)
        with self.assertRaises(APIError) as reassignment:
            self.dispatch(
                "POST",
                "/v1/sessions/thread-imported/turns",
                {"message": "reassign", "projectID": other_project["id"]},
                headers={"Idempotency-Key": "import-reassign-project"},
            )
        self.assertEqual(reassignment.exception.status, 409)
        self.assertEqual(reassignment.exception.code, "session_project_mismatch")
        self.assertEqual(len(self.codex.requests), request_count)

    def test_transcript_flattens_codex_turn_items(self) -> None:
        self.codex.responses["thread/read"] = {
            "thread": {
                "id": "thread-1",
                "name": "Example",
                "turns": [
                    {
                        "id": "turn-1",
                        "status": "completed",
                        "items": [
                            {"id": "u1", "type": "userMessage", "content": [{"text": "Hi"}]},
                            {"id": "a1", "type": "agentMessage", "text": "Hello"},
                        ],
                    }
                ],
            }
        }
        result = self.dispatch("GET", "/v1/sessions/thread-1/transcript").payload
        self.assertEqual(result["turns"][0]["items"][0]["role"], "user")
        self.assertEqual(result["turns"][0]["items"][1]["text"], "Hello")

    def test_notes_and_todos_require_revisions(self) -> None:
        note_response = self.dispatch(
            "POST",
            "/v1/projects/%s/notes" % self.project["id"],
            {"title": "Plan", "markdown": "**Hello**"},
        )
        note = note_response.payload["note"]
        self.assertIn("ETag", note_response.headers)
        with self.assertRaises(APIError) as missing:
            self.dispatch("PATCH", "/v1/notes/%s" % note["id"], {"markdown": "new"})
        self.assertEqual(missing.exception.status, 428)
        updated = self.dispatch(
            "PATCH",
            "/v1/notes/%s" % note["id"],
            {"markdown": "new"},
            headers={"If-Match": note_response.headers["ETag"]},
        ).payload["note"]
        self.assertEqual(updated["revision"], 2)
        todo = self.dispatch(
            "POST",
            "/v1/projects/%s/todos" % self.project["id"],
            {"text": "Ship it"},
        ).payload["todo"]
        todo_etag = make_etag("todo", todo["id"], todo["revision"])
        changed = self.dispatch(
            "PATCH",
            "/v1/todos/%s" % todo["id"],
            {"completed": True},
            headers={"If-Match": todo_etag},
        ).payload["todo"]
        self.assertTrue(changed["completed"])
        with self.assertRaises(APIError) as unsupported_put:
            self.dispatch(
                "PUT",
                "/v1/todos/%s" % todo["id"],
                {"completed": False},
                headers={"If-Match": make_etag("todo", todo["id"], changed["revision"])},
            )
        self.assertEqual(unsupported_put.exception.status, 405)

    def test_interaction_resolution_is_exactly_once_and_deny_stop_interrupts(self) -> None:
        self.codex.interaction_handler(
            self.codex.generation,
            "rpc-1",
            "item/commandExecution/requestApproval",
            {"threadId": "thread-1", "turnId": "turn-1", "command": "safe example"},
        )
        interaction = self.service.database.list_interactions()[0]
        result = self.dispatch(
            "POST",
            "/v1/interactions/%s/resolve" % interaction["id"],
            {"decision": "denyAndStop"},
        )
        self.assertEqual(result.payload["interaction"]["state"], "resolved")
        self.assertEqual(self.codex.responded[0], ("rpc-1", {"decision": "decline"}))
        self.assertIn("turn/interrupt", [item[0] for item in self.codex.requests])
        with self.assertRaises(APIError) as duplicate:
            self.dispatch(
                "POST",
                "/v1/interactions/%s/resolve" % interaction["id"],
                {"decision": "deny"},
            )
        self.assertEqual(duplicate.exception.status, 409)

    def test_expired_interaction_is_denied_and_sse_accepts_last_event_id(self) -> None:
        expired = self.service.database.create_interaction(
            99,
            self.codex.generation,
            "item/fileChange/requestApproval",
            {"threadId": "thread-1"},
            -1,
        )
        self.service.run_maintenance_once()
        self.assertEqual(self.codex.rejected[0][0], 99)
        with self.assertRaises(APIError) as caught:
            self.dispatch(
                "POST",
                "/v1/interactions/%s/resolve" % expired["id"],
                {"decision": "allowOnce"},
            )
        self.assertEqual(caught.exception.status, 410)
        request = self.dispatch(
            "GET", "/v1/events", query={"once": "true"}, headers={"Last-Event-ID": "1"}
        )
        self.assertIsInstance(request, SSERequest)
        self.assertEqual(request.after_id, 1)


if __name__ == "__main__":
    unittest.main()
