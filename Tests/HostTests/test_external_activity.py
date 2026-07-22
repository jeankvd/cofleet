import os
import pathlib
import select
import tempfile
import threading
import time
import unittest

from cofleet_host.activity import CodexFilesystemActivityWatcher, rollout_session_id
from cofleet_host.config import HostConfig
from cofleet_host.errors import CodexRPCError
from cofleet_host.service import (
    CoFleetHostService,
    CURRENT_CODEX_SOURCE_KINDS,
    LEGACY_CODEX_SOURCE_KINDS,
)

from helpers import FakeCodex, ServiceFixture


THREAD_ID = "019f7777-1111-7222-8333-444444444444"


def wait_until(predicate, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


class FakeWatcher:
    def __init__(self, _roots, callback):
        self.callback = callback
        self.closed = False

    def close(self):
        self.closed = True


class ExternalActivityTests(unittest.TestCase):
    def setUp(self):
        self.fixtures = []

    def tearDown(self):
        for fixture in reversed(self.fixtures):
            fixture.close()

    def fixture(self):
        fixture = ServiceFixture()
        self.fixtures.append(fixture)
        return fixture

    @staticmethod
    def thread(project, status="inProgress", text="Working"):
        return {
            "id": THREAD_ID,
            "name": "External Codex task",
            "cwd": project["canonicalPath"],
            "status": {"type": "notLoaded"},
            "updatedAt": 10,
            "turns": [
                {
                    "id": "turn-external",
                    "status": status,
                    "startedAt": 1,
                    "completedAt": 2 if status == "completed" else None,
                    "items": [
                        {
                            "id": "message-external",
                            "type": "agentMessage",
                            "text": text,
                            "status": "completed" if status == "completed" else "inProgress",
                        }
                    ],
                }
            ],
        }

    def test_rollout_watcher_uses_metadata_and_stops_cleanly(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "sessions"
            root.mkdir()
            observed = []
            watcher = CodexFilesystemActivityWatcher(
                (root,),
                observed.append,
                scan_interval=0.05,
                max_files=8,
                use_native=False,
            )
            try:
                time.sleep(0.1)
                day = root / "2026" / "07" / "21"
                day.mkdir(parents=True)
                rollout = day / ("rollout-2026-07-21T00-00-00-" + THREAD_ID + ".jsonl")
                rollout.write_text("opaque", encoding="utf-8")
                self.assertTrue(wait_until(lambda: observed == [THREAD_ID]))
                rollout.write_text("opaque-more", encoding="utf-8")
                self.assertTrue(wait_until(lambda: len(observed) >= 2))
            finally:
                watcher.close()
            count = len(observed)
            rollout.write_text("after-close", encoding="utf-8")
            time.sleep(0.15)
            self.assertEqual(len(observed), count)
            self.assertEqual(rollout_session_id(rollout), THREAD_ID)

    def test_native_watch_targets_have_a_hard_fd_cap_and_keep_priority_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = pathlib.Path(temporary)
            root = parent / "sessions"
            root.mkdir()
            invalidation = parent / "state_5.sqlite-wal"
            invalidation.write_text("opaque", encoding="utf-8")

            rollouts = []
            now = time.time_ns()
            for index in range(48):
                day = root / "2026" / f"{index // 24 + 1:02d}" / f"{index % 24 + 1:02d}"
                day.mkdir(parents=True, exist_ok=True)
                session_id = f"{index:08x}-1111-7222-8333-{index:012x}"
                rollout = day / f"rollout-2026-07-21T00-00-00-{session_id}.jsonl"
                rollout.write_text("opaque", encoding="utf-8")
                modified = now - ((48 - index) * 1_000_000_000)
                os.utime(rollout, ns=(modified, modified))
                rollouts.append((session_id, rollout))

            watcher = CodexFilesystemActivityWatcher(
                (root,),
                lambda _session_id: None,
                scan_interval=10,
                max_files=256,
                max_native_descriptors=32,
                use_native=False,
            )
            try:
                oldest_id, oldest_rollout = rollouts[0]
                newest_rollout = rollouts[-1][1]
                watcher.track(oldest_id)
                directories, files = watcher._candidate_paths()
                targets = watcher._bounded_native_targets(directories, files)
            finally:
                watcher.close()

            target_paths = {path for path, _kind in targets}
            self.assertLessEqual(len(targets), 32)
            self.assertLess(watcher.max_native_descriptors + 1, 96)
            self.assertIn(parent, target_paths)
            self.assertIn(root, target_paths)
            self.assertIn(invalidation, target_paths)
            self.assertIn(oldest_rollout, target_paths)
            self.assertIn(oldest_rollout.parent, target_paths)
            self.assertIn(newest_rollout, target_paths)
            self.assertIn(newest_rollout.parent, target_paths)

    @unittest.skipUnless(hasattr(select, "kqueue"), "kqueue is unavailable")
    def test_native_watcher_observes_append_without_scanning_contents(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "sessions"
            root.mkdir()
            rollout = root / ("rollout-2026-07-21T00-00-00-" + THREAD_ID + ".jsonl")
            rollout.write_text("opaque", encoding="utf-8")
            observed = []
            watcher = CodexFilesystemActivityWatcher(
                (root,),
                observed.append,
                scan_interval=0.05,
                max_files=8,
                use_native=True,
            )
            try:
                time.sleep(0.1)
                with rollout.open("a", encoding="utf-8") as stream:
                    stream.write("-append")
                    stream.flush()
                self.assertTrue(wait_until(lambda: THREAD_ID in observed))
                self.assertTrue(watcher.native)
            finally:
                watcher.close()

    def test_unknown_desktop_task_maps_by_canonical_cwd_and_reconciles(self):
        fixture = self.fixture()
        project = fixture.project()
        fixture.codex.responses["thread/read"] = {
            "thread": self.thread(project),
        }

        self.assertTrue(fixture.service._reconcile_external_session(THREAD_ID))

        events = fixture.service.events.replay(0)[0]
        catalog = [event for event in events if event["type"] == "session.catalogUpdated"]
        self.assertEqual(catalog[-1]["data"]["currentSessionID"], THREAD_ID)
        turn = [event for event in events if event["type"] == "turn.updated"][-1]
        self.assertEqual(turn["data"]["projectID"], project["id"])
        # Opening an existing Desktop task baselines its canonical snapshot.
        # Historical items must not replay one by one through Progress.
        self.assertFalse(any(event["type"] == "turn.item" for event in events))
        activity = [event for event in events if event["type"] == "project.activityChanged"]
        self.assertEqual(activity[-1]["data"]["state"], "working")
        self.assertEqual(activity[-1]["data"]["source"], "codexDesktop")

        fixture.codex.responses["thread/read"] = {
            "thread": self.thread(project, status="completed", text="Finished"),
        }
        self.assertTrue(fixture.service._reconcile_external_session(THREAD_ID))
        events = fixture.service.events.replay(0)[0]
        activity = [event for event in events if event["type"] == "project.activityChanged"]
        self.assertEqual(activity[-1]["data"]["state"], "idle")
        items = [event for event in events if event["type"] == "turn.item"]
        self.assertEqual(items[-1]["data"]["item"]["text"], "Finished")
        self.assertNotIn("thread/list", [method for method, _ in fixture.codex.requests])

    def test_completed_desktop_snapshot_is_atomic_on_first_observation(self):
        fixture = self.fixture()
        project = fixture.project()
        fixture.codex.responses["thread/read"] = {
            "thread": self.thread(project, status="completed", text="Already finished"),
        }

        self.assertTrue(fixture.service._reconcile_external_session(THREAD_ID))

        events = fixture.service.events.replay(0)[0]
        self.assertTrue(any(event["type"] == "session.catalogUpdated" for event in events))
        self.assertFalse(any(event["type"] == "turn.item" for event in events))
        activity = [event for event in events if event["type"] == "project.activityChanged"]
        self.assertEqual(activity[-1]["data"]["state"], "idle")
        self.assertEqual(activity[-1]["data"]["source"], "codexDesktop")

    def test_stale_interrupted_snapshot_stays_working_until_completed_advances(self):
        fixture = self.fixture()
        project = fixture.project()
        fixture.service.database.put_session_catalog_cache(
            project["id"],
            {
                "sessions": [
                    {
                        "id": THREAD_ID,
                        "hostID": fixture.service.host_id,
                        "projectID": project["id"],
                        "title": "Known stale task",
                        "archived": False,
                        "provider": "codex",
                    }
                ],
                "nextCursor": None,
            },
        )
        stale = self.thread(project, status="interrupted", text="Older interruption")
        fixture.codex.responses["thread/read"] = {"thread": stale}

        fixture.service._on_codex_filesystem_activity(THREAD_ID)
        self.assertTrue(fixture.service._reconcile_external_session(THREAD_ID))

        events = fixture.service.events.replay(0)[0]
        activity = [event for event in events if event["type"] == "project.activityChanged"]
        self.assertEqual(activity[-1]["data"]["state"], "working")
        self.assertFalse(any(event["type"] == "turn.updated" for event in events))
        self.assertFalse(any(event["type"] == "turn.item" for event in events))
        self.assertFalse(any(event["type"] == "session.catalogUpdated" for event in events))

        fixture.codex.responses["thread/read"] = {
            "thread": self.thread(project, status="completed", text="Actual reply"),
        }
        self.assertTrue(fixture.service._reconcile_external_session(THREAD_ID))
        events = fixture.service.events.replay(0)[0]
        activity = [event for event in events if event["type"] == "project.activityChanged"]
        self.assertEqual(activity[-1]["data"]["state"], "idle")
        self.assertTrue(any(event["type"] == "session.catalogUpdated" for event in events))
        self.assertFalse(any(event["type"] == "turn.item" for event in events))

    def test_unregistered_unknown_task_never_crosses_host_event_stream(self):
        fixture = self.fixture()
        outside = fixture.root / "Unregistered"
        outside.mkdir()
        fixture.codex.responses["thread/read"] = {
            "thread": {
                "id": THREAD_ID,
                "cwd": str(outside),
                "turns": [],
            }
        }

        self.assertFalse(fixture.service._reconcile_external_session(THREAD_ID))
        exposed = {
            "session.catalogUpdated",
            "turn.updated",
            "turn.item",
            "project.activityChanged",
        }
        self.assertFalse(
            any(event["type"] in exposed for event in fixture.service.events.replay(0)[0])
        )
        self.assertEqual(
            [method for method, _ in fixture.codex.requests],
            ["thread/read"],
        )

    def test_filesystem_burst_debounces_one_targeted_read_and_shutdown(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = pathlib.Path(temporary.name)
        home = root / "home"
        home.mkdir()
        codex = FakeCodex()
        watcher_holder = []

        def watcher_factory(roots, callback):
            watcher = FakeWatcher(roots, callback)
            watcher_holder.append(watcher)
            return watcher

        service = CoFleetHostService(
            HostConfig(data_dir=root / "state", home=home, port=0),
            codex=codex,
            start_maintenance=True,
            private_serve_verifier=lambda _port: {},
            filesystem_watcher_factory=watcher_factory,
        )
        project_root = root / "Project"
        project_root.mkdir()
        project = service.database.create_project(
            "Project", str(project_root), str(project_root.resolve())
        )
        service.database.put_session_catalog_cache(
            project["id"],
            {
                "sessions": [
                    {
                        "id": THREAD_ID,
                        "hostID": service.host_id,
                        "projectID": project["id"],
                        "title": "Known",
                        "archived": False,
                        "provider": "codex",
                    }
                ],
                "nextCursor": None,
            },
        )
        codex.responses["thread/read"] = {
            "thread": self.thread(project, status="interrupted", text="Stale"),
        }
        try:
            watcher = watcher_holder[0]
            time.sleep(0.1)
            list_requests_before = [
                method for method, _ in codex.requests
            ].count("thread/list")
            for _ in range(6):
                watcher.callback(THREAD_ID)
                time.sleep(0.03)
            self.assertTrue(
                wait_until(
                    lambda: [method for method, _ in codex.requests].count("thread/read") == 1
                )
            )
            self.assertEqual(
                [method for method, _ in codex.requests].count("thread/list"),
                list_requests_before,
            )
        finally:
            service.close()
        self.assertTrue(watcher_holder[0].closed)
        reads = [method for method, _ in codex.requests].count("thread/read")
        watcher_holder[0].callback(THREAD_ID)
        time.sleep(0.85)
        self.assertEqual([method for method, _ in codex.requests].count("thread/read"), reads)

    def test_thread_status_and_items_are_project_scoped(self):
        fixture = self.fixture()
        project = fixture.project()
        fixture.service._on_codex_notification(
            "thread/started",
            {
                "thread": {
                    "id": THREAD_ID,
                    "cwd": project["canonicalPath"],
                    "name": "Live",
                    "status": {"type": "active", "activeFlags": []},
                }
            },
        )
        fixture.service._on_codex_notification(
            "thread/status/changed",
            {
                "threadId": THREAD_ID,
                "status": {"type": "active", "activeFlags": ["waitingOnApproval"]},
            },
        )
        fixture.service._on_codex_notification(
            "item/reasoning/textDelta",
            {
                "threadId": THREAD_ID,
                "turnId": "turn-live",
                "itemId": "reason-live",
                "delta": "Thinking",
            },
        )

        events = fixture.service.events.replay(0)[0]
        activities = [event["data"] for event in events if event["type"] == "project.activityChanged"]
        self.assertEqual(activities[0]["state"], "working")
        self.assertEqual(activities[1]["state"], "waitingForInteraction")
        self.assertEqual(activities[1]["itemKind"], "approval")
        self.assertEqual(activities[-1]["itemKind"], "reasoning")
        item = [event["data"] for event in events if event["type"] == "turn.item"][-1]
        self.assertEqual(item["projectID"], project["id"])

    def test_current_source_kinds_fall_back_once_for_older_codex(self):
        fixture = self.fixture()
        requests = []

        def response(params):
            requests.append(list(params["sourceKinds"]))
            if len(requests) == 1:
                raise CodexRPCError("unsupported source kind", -32602)
            return {"data": [], "nextCursor": None}

        fixture.codex.responses["thread/list"] = response
        fixture.service._codex_thread_list({"limit": 5})
        fixture.service._codex_thread_list({"limit": 5})

        self.assertEqual(requests[0], CURRENT_CODEX_SOURCE_KINDS)
        self.assertEqual(requests[1], LEGACY_CODEX_SOURCE_KINDS)
        self.assertEqual(requests[2], LEGACY_CODEX_SOURCE_KINDS)


if __name__ == "__main__":
    unittest.main()
