import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class VersionTest(unittest.TestCase):
    def test_initial_release_uses_package_version(self):
        self.assertEqual(release.next_version("v0.1.0", [], "patch"), "v0.1.0")

    def test_numeric_versions_and_increment_resets(self):
        for bump, expected in [("patch", "v0.10.3"), ("minor", "v0.11.0"), ("major", "v1.0.0")]:
            self.assertEqual(release.next_version("v0.10.2", ["v0.9.0", "v0.10.2", "notes"], bump), expected)

    def test_invalid_input_is_rejected(self):
        for current, bump in [("v01.0.0", "patch"), ("v0.1.0", "custom")]:
            with self.assertRaises(ValueError):
                release.next_version(current, [], bump)


class PublishTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        base = Path(self.directory.name)
        self.repo = base / "source"
        self.repo.mkdir()
        self.remote = base / "remote.git"
        subprocess.run(["git", "init", "--bare", "-q", str(self.remote)], check=True)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release@example.test")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        (self.repo / "mix.exs").write_text('[version: "0.1.0"]\n')
        (self.repo / "README.md").write_text("Core\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Initial commit")
        self.source = self.git("rev-parse", "HEAD")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-q", "origin", "main")
        root = patch.object(release, "ROOT", self.repo)
        root.start()
        self.addCleanup(root.stop)
        self.commands = []
        original = release.run

        def run(*args):
            if args[0] == "gh":
                self.commands.append(args)
                return ""
            return original(*args)

        for mock in (patch.object(release, "run", side_effect=run),
                     patch.object(release, "releases", return_value=[])):
            mock.start()
            self.addCleanup(mock.stop)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True).strip()

    def test_initial_tag_keeps_a_single_commit(self):
        release.publish("v0.1.0", self.source, "example/core")
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "1")
        self.assertEqual(self.git("rev-parse", "v0.1.0"), self.source)
        self.assertIn("--verify-tag", self.commands[0])

    def test_bump_commits_exact_tested_version_and_retry_is_idempotent(self):
        release.publish("v0.1.1", self.source, "example/core")
        published = self.git("rev-parse", "HEAD")
        self.assertEqual(self.git("rev-list", "--count", "HEAD"), "2")
        self.assertIn('"0.1.1"', self.git("show", "v0.1.1:mix.exs"))
        self.git("reset", "--hard", self.source)
        release.publish("v0.1.1", self.source, "example/core")
        self.assertIn(published, self.git("ls-remote", "origin", "refs/heads/main"))

    def test_main_movement_stops_publication(self):
        (self.repo / "README.md").write_text("New change\n")
        self.git("commit", "-qam", "Another change")
        self.git("push", "-q", "origin", "main")
        self.git("reset", "--hard", self.source)
        with self.assertRaisesRegex(ValueError, "main changed"):
            release.publish("v0.1.1", self.source, "example/core")
        self.assertEqual(self.git("ls-remote", "--tags", "origin"), "")
        self.assertEqual(self.commands, [])

    def test_existing_tag_with_different_content_is_never_replaced(self):
        (self.repo / "README.md").write_text("Different source\n")
        self.git("commit", "-qam", "Different source")
        self.git("tag", "v0.1.1")
        self.git("push", "-q", "origin", "refs/tags/v0.1.1")
        self.git("reset", "--hard", self.source)
        with self.assertRaisesRegex(ValueError, "different source"):
            release.publish("v0.1.1", self.source, "example/core")
        self.assertEqual(self.commands, [])


if __name__ == "__main__":
    unittest.main()
