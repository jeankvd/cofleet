import pathlib
import tempfile
import threading
import time
import unittest

from cofleet_host.config import HostConfig
from cofleet_host.database import Database
from cofleet_host.service import CoFleetHostService

from helpers import FakeCodex, ServiceFixture


def wait_until(predicate, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


class SessionCatalogCacheTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixtures = []

    def tearDown(self) -> None:
        for fixture in reversed(self.fixtures):
            fixture.close()

    def fixture(self) -> ServiceFixture:
        fixture = ServiceFixture()
        self.fixtures.append(fixture)
        return fixture

    @staticmethod
    def payload(project, session_id="thread-1", title="Latest"):
        return {
            "sessions": [
                {
                    "id": session_id,
                    "hostID": "host-test",
                    "projectID": project["id"],
                    "title": title,
                    "cwd": project["canonicalPath"],
                    "preview": title,
                    "createdAt": 1,
                    "updatedAt": 2,
                    "archived": False,
                    "model": None,
                    "accessLevel": None,
                    "reasoningEffort": None,
                    "serviceTier": None,
                    "provider": "codex",
                }
            ],
            "nextCursor": None,
        }

    def test_cache_miss_loads_once_synchronously_and_persists_only_five(self) -> None:
        fixture = self.fixture()
        project = fixture.project()
        fixture.codex.responses["thread/list"] = {
            "data": [
                {
                    "id": "thread-%d" % index,
                    "name": "Task %d" % index,
                    "cwd": project["canonicalPath"],
                }
                for index in range(6)
            ],
            "nextCursor": "next-five",
        }

        response = fixture.service._project_sessions(project["id"], {}).payload

        self.assertEqual(len(response["sessions"]), 5)
        self.assertEqual(response["nextCursor"], "next-five")
        self.assertEqual(
            fixture.service.database.get_session_catalog_cache(project["id"]), response
        )
        self.assertEqual(
            [method for method, _ in fixture.codex.requests].count("thread/list"), 1
        )

    def test_concurrent_cache_misses_share_one_foreground_codex_request(self) -> None:
        fixture = self.fixture()
        project = fixture.project()
        entered = threading.Event()
        release = threading.Event()
        self.addCleanup(release.set)

        def blocked(_params):
            entered.set()
            release.wait(2.0)
            return {
                "data": [
                    {
                        "id": "thread-shared",
                        "name": "Shared",
                        "cwd": project["canonicalPath"],
                    }
                ],
                "nextCursor": None,
            }

        fixture.codex.responses["thread/list"] = blocked
        results = []
        errors = []

        def load():
            try:
                results.append(fixture.service._project_sessions(project["id"], {}).payload)
            except Exception as error:  # pragma: no cover - asserted below
                errors.append(error)

        workers = [threading.Thread(target=load) for _ in range(4)]
        for worker in workers:
            worker.start()
        self.assertTrue(entered.wait(1.0))
        time.sleep(0.05)
        self.assertEqual(
            [method for method, _ in fixture.codex.requests].count("thread/list"), 1
        )
        release.set()
        for worker in workers:
            worker.join(2.0)

        self.assertEqual(errors, [])
        self.assertEqual(len(results), 4)
        self.assertTrue(all(item["sessions"][0]["id"] == "thread-shared" for item in results))

    def test_cached_requests_return_immediately_and_coalesce_background_refresh(self) -> None:
        fixture = self.fixture()
        project = fixture.project()
        fixture.service.database.put_session_catalog_cache(
            project["id"], self.payload(project)
        )
        entered = threading.Event()
        release = threading.Event()
        self.addCleanup(release.set)

        def blocked(_params):
            entered.set()
            release.wait(2.0)
            return {"data": [], "nextCursor": None}

        fixture.codex.responses["thread/list"] = blocked
        started = time.monotonic()
        responses = [
            fixture.service._project_sessions(project["id"], {}).payload
            for _ in range(8)
        ]
        elapsed = time.monotonic() - started

        self.assertLess(elapsed, 0.25)
        self.assertTrue(all(item["sessions"][0]["id"] == "thread-1" for item in responses))
        self.assertTrue(entered.wait(1.0))
        self.assertEqual(
            [method for method, _ in fixture.codex.requests].count("thread/list"), 1
        )
        release.set()
        self.assertTrue(
            wait_until(
                lambda: project["id"] not in fixture.service._session_catalog_refreshing
            )
        )

    def test_persisted_restart_uses_snapshot_without_foreground_codex_call(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = pathlib.Path(temporary.name)
        home = root / "home"
        home.mkdir()
        project_root = root / "Project"
        project_root.mkdir()
        config = HostConfig(data_dir=root / "state", home=home, port=0)

        first_codex = FakeCodex()
        first = CoFleetHostService(config, codex=first_codex, start_maintenance=False)
        project = first.database.create_project(
            "Project", str(project_root), str(project_root.resolve())
        )
        first_codex.responses["thread/list"] = {
            "data": [
                {
                    "id": "thread-persisted",
                    "name": "Persisted",
                    "cwd": project["canonicalPath"],
                }
            ],
            "nextCursor": None,
        }
        first._project_sessions(project["id"], {})
        first.close()

        entered = threading.Event()
        release = threading.Event()
        self.addCleanup(release.set)
        request_threads = []
        second_codex = FakeCodex()

        def blocked(_params):
            request_threads.append(threading.current_thread().name)
            entered.set()
            release.wait(2.0)
            return {"data": [], "nextCursor": None}

        second_codex.responses["thread/list"] = blocked
        second = CoFleetHostService(config, codex=second_codex, start_maintenance=False)
        try:
            response = second._project_sessions(project["id"], {}).payload
            self.assertEqual(response["sessions"][0]["id"], "thread-persisted")
            self.assertTrue(entered.wait(1.0))
            self.assertNotIn(threading.current_thread().name, request_threads)
            enriched = second._project_with_source_control(second.database.get_project(project["id"]))
            self.assertEqual(enriched["currentSessionID"], "thread-persisted")
        finally:
            release.set()
            second.close()

    def test_catalog_event_is_published_only_when_snapshot_changes(self) -> None:
        fixture = self.fixture()
        project = fixture.project()
        first = self.payload(project)
        changed = self.payload(project, session_id="thread-2", title="Newer")

        self.assertTrue(fixture.service._store_session_catalog(project["id"], first))
        self.assertFalse(fixture.service._store_session_catalog(project["id"], first))
        self.assertTrue(fixture.service._store_session_catalog(project["id"], changed))
        events, _reset = fixture.service.database.events_after(0)
        catalog_events = [
            event for event in events if event["type"] == "session.catalogUpdated"
        ]
        self.assertEqual(len(catalog_events), 2)
        self.assertEqual(catalog_events[-1]["data"]["currentSessionID"], "thread-2")

    def test_startup_warmup_bounds_concurrent_project_refreshes(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = pathlib.Path(temporary.name)
        home = root / "home"
        home.mkdir()
        config = HostConfig(data_dir=root / "state", home=home, port=0)
        database = Database(config.database_path)
        for index in range(12):
            project_root = root / ("Project-%d" % index)
            project_root.mkdir()
            database.create_project(
                "Project %d" % index,
                str(project_root),
                str(project_root.resolve()),
            )
        database.close()

        release = threading.Event()
        four_active = threading.Event()
        self.addCleanup(release.set)
        state = {"active": 0, "maximum": 0}
        state_lock = threading.Lock()
        codex = FakeCodex()

        def blocked(_params):
            with state_lock:
                state["active"] += 1
                state["maximum"] = max(state["maximum"], state["active"])
                if state["active"] == 4:
                    four_active.set()
            release.wait(2.0)
            with state_lock:
                state["active"] -= 1
            return {"data": [], "nextCursor": None}

        codex.responses["thread/list"] = blocked
        service = CoFleetHostService(config, codex=codex, start_maintenance=True)
        try:
            self.assertTrue(four_active.wait(1.0))
            time.sleep(0.05)
            self.assertEqual(state["maximum"], 4)
            self.assertEqual(
                [method for method, _ in codex.requests].count("thread/list"), 4
            )
            release.set()
            self.assertTrue(
                wait_until(
                    lambda: [method for method, _ in codex.requests].count("thread/list")
                    == 12
                )
            )
        finally:
            release.set()
            service.close()


if __name__ == "__main__":
    unittest.main()
