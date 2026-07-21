import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[2]


def run(command, *, cwd, env=None):
    return subprocess.run(
        [str(item) for item in command],
        cwd=str(cwd),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
        check=False,
    )


class ReleaseGateTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("ruby"), "Ruby is required for OpenAPI validation")
    def test_openapi_validator_parses_from_any_cwd_and_rejects_dangling_refs(self) -> None:
        validator = REPOSITORY_ROOT / "Scripts" / "check-openapi.rb"
        contract = REPOSITORY_ROOT / "Docs" / "openapi.yaml"
        with tempfile.TemporaryDirectory() as temporary:
            outside = pathlib.Path(temporary) / "outside"
            outside.mkdir()
            valid = run(["ruby", validator, contract], cwd=outside)
            self.assertEqual(valid.returncode, 0, valid.stderr)

            invalid_contract = pathlib.Path(temporary) / "invalid-openapi.yaml"
            source = contract.read_text(encoding="utf-8")
            invalid_contract.write_text(
                source.replace(
                    "#/components/schemas/PairedDevice",
                    "#/components/schemas/MissingDevice",
                    1,
                ),
                encoding="utf-8",
            )
            invalid = run(["ruby", validator, invalid_contract], cwd=outside)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("is dangling", invalid.stderr)

            described_response = """        \"200\":
          description: Device revoked.
          content:
            application/json:
              schema: { $ref: \"#/components/schemas/DeviceEnvelope\" }
"""
            undescribed_response = """        \"200\":
          description: Device revoked.
"""
            self.assertIn(described_response, source)
            incomplete_contract = pathlib.Path(temporary) / "incomplete-openapi.yaml"
            incomplete_contract.write_text(
                source.replace(described_response, undescribed_response, 1),
                encoding="utf-8",
            )
            incomplete = run(["ruby", validator, incomplete_contract], cwd=outside)
            self.assertNotEqual(incomplete.returncode, 0)
            self.assertIn("must describe its successful response body", incomplete.stderr)

    @unittest.skipUnless(shutil.which("rg"), "ripgrep is required for private-content checks")
    def test_private_content_exclusions_work_from_outside_repository(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary) / "publication"
            scripts = root / "Scripts"
            config = root / "Config"
            outside = pathlib.Path(temporary) / "outside"
            scripts.mkdir(parents=True)
            config.mkdir()
            outside.mkdir()
            shutil.copy2(REPOSITORY_ROOT / "Scripts" / "lib.sh", scripts / "lib.sh")
            shutil.copy2(
                REPOSITORY_ROOT / "Scripts" / "check-private-content.sh",
                scripts / "check-private-content.sh",
            )
            (config / "private-terms.txt").write_text("private-marker\n", encoding="utf-8")

            checked = run([scripts / "check-private-content.sh"], cwd=outside)
            self.assertEqual(checked.returncode, 0, checked.stderr)

    @unittest.skipUnless(
        shutil.which("rg") and shutil.which("git"),
        "Git and ripgrep are required for history checks",
    )
    def test_private_content_history_scans_removed_sensitive_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = pathlib.Path(temporary).resolve()
            root = temporary_root / "publication"
            scripts = root / "Scripts"
            config = root / "Config"
            outside = temporary_root / "outside"
            scripts.mkdir(parents=True)
            config.mkdir()
            outside.mkdir()
            shutil.copy2(REPOSITORY_ROOT / "Scripts" / "lib.sh", scripts / "lib.sh")
            shutil.copy2(
                REPOSITORY_ROOT / "Scripts" / "check-private-content.sh",
                scripts / "check-private-content.sh",
            )
            (config / "private-terms.txt").write_text("# test denylist\n", encoding="utf-8")
            removed = root / "removed-private-path.txt"
            removed.write_text("/" + "Users" + "/alice/work\n", encoding="utf-8")

            self.assertEqual(run(["git", "init", "-q"], cwd=root).returncode, 0)
            self.assertEqual(run(["git", "config", "user.name", "CoFleet Test"], cwd=root).returncode, 0)
            self.assertEqual(
                run(["git", "config", "user.email", "test@example.invalid"], cwd=root).returncode,
                0,
            )
            self.assertEqual(run(["git", "add", "--all"], cwd=root).returncode, 0)
            self.assertEqual(run(["git", "commit", "-q", "-m", "initial"], cwd=root).returncode, 0)
            removed.unlink()
            self.assertEqual(run(["git", "add", "--all"], cwd=root).returncode, 0)
            self.assertEqual(run(["git", "commit", "-q", "-m", "remove private path"], cwd=root).returncode, 0)

            checked = run([scripts / "check-private-content.sh", "--history"], cwd=outside)
            self.assertNotEqual(checked.returncode, 0)
            self.assertIn("exists in Git history", checked.stderr)

    @unittest.skipUnless(
        shutil.which("bash") and shutil.which("git"),
        "Bash and Git are required for source revision checks",
    )
    def test_revision_recognizes_checkout_reached_through_path_alias(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = pathlib.Path(temporary).resolve()
            root = temporary_root / "publication"
            scripts = root / "Scripts"
            outside = temporary_root / "outside"
            scripts.mkdir(parents=True)
            outside.mkdir()
            shutil.copy2(REPOSITORY_ROOT / "Scripts" / "lib.sh", scripts / "lib.sh")

            self.assertEqual(run(["git", "init", "-q"], cwd=root).returncode, 0)
            self.assertEqual(run(["git", "config", "user.name", "CoFleet Test"], cwd=root).returncode, 0)
            self.assertEqual(
                run(["git", "config", "user.email", "test@example.invalid"], cwd=root).returncode,
                0,
            )
            self.assertEqual(run(["git", "add", "--all"], cwd=root).returncode, 0)
            self.assertEqual(run(["git", "commit", "-q", "-m", "initial"], cwd=root).returncode, 0)

            revision = run(["git", "rev-parse", "--short=12", "HEAD"], cwd=root)
            self.assertEqual(revision.returncode, 0, revision.stderr)
            alias = temporary_root / "publication-alias"
            alias.symlink_to(root, target_is_directory=True)

            checked = run(
                [
                    "bash",
                    "-c",
                    'source "$1"; printf "%s\\n" "$COFLEET_ROOT"; cofleet_revision',
                    "cofleet-revision-test",
                    alias / "Scripts" / "lib.sh",
                ],
                cwd=outside,
            )
            self.assertEqual(checked.returncode, 0, checked.stderr)
            self.assertEqual(
                checked.stdout.splitlines(),
                [str(root.resolve()), revision.stdout.strip()],
            )

    @unittest.skipUnless(shutil.which("git"), "Git is required for clean-clone verification")
    def test_clean_clone_runs_inside_clone_with_forced_release_signing_settings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = pathlib.Path(temporary).resolve()
            root = temporary_root / "publication"
            scripts = root / "Scripts"
            outside = temporary_root / "outside"
            proof = temporary_root / "proof.txt"
            scripts.mkdir(parents=True)
            outside.mkdir()
            shutil.copy2(REPOSITORY_ROOT / "Scripts" / "lib.sh", scripts / "lib.sh")
            shutil.copy2(
                REPOSITORY_ROOT / "Scripts" / "verify-clean-clone.sh",
                scripts / "verify-clean-clone.sh",
            )
            for name in ("bootstrap", "test", "build"):
                script = scripts / (name + ".sh")
                script.write_text(
                    "#!/usr/bin/env bash\n"
                    "set -euo pipefail\n"
                    "root=\"$(git rev-parse --show-toplevel)\"\n"
                    "[[ \"$PWD\" == \"$root\" ]]\n"
                    "printf '%s|%s|%s|%s\\n' \""
                    + name
                    + "\" \"$PWD\" \"${COFLEET_SIGNING:-}\" \"${CONFIGURATION:-}\" >> \"$PROOF_FILE\"\n",
                    encoding="utf-8",
                )
                script.chmod(0o755)

            self.assertEqual(run(["git", "init", "-q"], cwd=root).returncode, 0)
            self.assertEqual(run(["git", "config", "user.name", "CoFleet Test"], cwd=root).returncode, 0)
            self.assertEqual(
                run(["git", "config", "user.email", "test@example.invalid"], cwd=root).returncode,
                0,
            )
            self.assertEqual(run(["git", "add", "--all"], cwd=root).returncode, 0)
            self.assertEqual(run(["git", "commit", "-q", "-m", "initial"], cwd=root).returncode, 0)

            environment = dict(os.environ)
            environment.update(
                {
                    "PROOF_FILE": str(proof),
                    "COFLEET_SIGNING": "1",
                    "CONFIGURATION": "Debug",
                }
            )
            checked = run([scripts / "verify-clean-clone.sh"], cwd=outside, env=environment)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            entries = [line.split("|") for line in proof.read_text(encoding="utf-8").splitlines()]
            self.assertEqual([entry[0] for entry in entries], ["bootstrap", "test", "build"])
            self.assertEqual(len({entry[1] for entry in entries}), 1)
            self.assertEqual(pathlib.Path(entries[0][1]).name, "clone")
            self.assertEqual(entries[2][2:], ["0", "Release"])


if __name__ == "__main__":
    unittest.main()
