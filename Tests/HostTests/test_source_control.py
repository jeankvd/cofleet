import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from cofleet_host.service import CoFleetHostService

from helpers import ServiceFixture


GIT = shutil.which("git", path="/usr/bin:/bin")


@unittest.skipUnless(GIT is not None, "system Git required")
class SourceControlTests(unittest.TestCase):
    def git(self, root: pathlib.Path, *arguments: str) -> None:
        subprocess.run(
            [GIT, "-C", str(root), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
        )

    def test_project_catalog_embeds_ancestor_git_status(self) -> None:
        fixture = ServiceFixture()
        try:
            repository = fixture.root / "repository"
            project_root = repository / "Sources" / "Feature"
            project_root.mkdir(parents=True)
            self.git(repository, "init", "-q", "--initial-branch=main")
            project = fixture.service.database.create_project(
                "Feature", str(project_root), str(project_root.resolve())
            )
            device, _ = fixture.pair()

            response = fixture.service.dispatch("GET", "/v1/projects", {}, {}, {}, device)
            listed = next(item for item in response.payload["projects"] if item["id"] == project["id"])

            self.assertEqual(listed["sourceControl"]["kind"], "git")
            self.assertEqual(listed["sourceControl"]["state"], "clean")
            self.assertEqual(listed["sourceControl"]["branch"], "main")
            self.assertIsInstance(listed["sourceControl"]["observedAt"], float)
        finally:
            fixture.close()

    def test_git_status_distinguishes_dirty_staged_and_unpushed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "repository"
            remote = pathlib.Path(temporary) / "origin.git"
            root.mkdir()
            self.git(root, "init", "-q", "--initial-branch=main")
            self.git(root, "config", "user.name", "CoFleet Test")
            self.git(root, "config", "user.email", "cofleet@example.invalid")
            tracked = root / "tracked.txt"
            tracked.write_text("initial\n", encoding="utf-8")
            self.git(root, "add", "tracked.txt")
            self.git(root, "commit", "-q", "-m", "initial")

            tracked.write_text("dirty\n", encoding="utf-8")
            self.assertEqual(CoFleetHostService._git_status(str(root))["state"], "dirty")

            self.git(root, "add", "tracked.txt")
            self.assertEqual(CoFleetHostService._git_status(str(root))["state"], "staged")
            self.git(root, "commit", "-q", "-m", "staged")

            subprocess.run([GIT, "init", "-q", "--bare", str(remote)], check=True)
            self.git(root, "remote", "add", "origin", str(remote))
            self.git(root, "push", "-q", "-u", "origin", "main")
            tracked.write_text("ahead\n", encoding="utf-8")
            self.git(root, "add", "tracked.txt")
            self.git(root, "commit", "-q", "-m", "ahead")
            self.assertEqual(CoFleetHostService._git_status(str(root))["state"], "unpushed")

    def test_github_pr_status_is_optional_bounded_and_normalized(self) -> None:
        responses = [
            (0, "git@github.com:sample/companion.git\n"),
            (0, '[{"isDraft":true,"state":"OPEN","url":"https://example.invalid","number":7}]'),
        ]
        with mock.patch.object(CoFleetHostService, "_run_bounded", side_effect=responses) as runner:
            with mock.patch("cofleet_host.service.shutil.which", return_value="/usr/local/bin/gh"):
                status = CoFleetHostService._github_pull_request_status(
                    "/tmp/repository",
                    "/usr/bin/git",
                    "feature/status",
                    "feature/status...origin/feature/status",
                    {},
                )

        self.assertEqual(status["state"], "draftPullRequest")
        self.assertEqual(status["detail"], "Draft pull request #7")
        self.assertEqual(runner.call_args_list[1].kwargs["timeout"], 2.0)
        self.assertEqual(runner.call_args_list[1].kwargs["maximum_output_bytes"], 16_384)

    def test_subprocess_output_is_rejected_past_the_bound(self) -> None:
        result = CoFleetHostService._run_bounded(
            [sys.executable, "-c", "import sys; sys.stdout.write('x' * 65536)"],
            timeout=2.0,
            maximum_output_bytes=32,
        )
        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()
