#!/usr/bin/env python3
"""Run with python3 scripts/test-signing.py; no Xcode or third-party packages."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("configure_signing", ROOT / "scripts/configure-signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
TEAM, BUNDLE = "A1B2C3D4E5", "dev.fixture.codejam16.tasklens"


def run(*args, cwd):
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=True)


class SigningTests(unittest.TestCase):
    def test_shared_project_has_no_personal_signing_overrides(self):
        signing.check_shared(ROOT)

    def test_xcode_reference_comments_are_accepted(self):
        key = signing.ident("ref:Config/Signing.xcconfig")
        block = f"baseConfigurationReference = {key} /* Signing.xcconfig */;"
        self.assertEqual(signing.setting(block, "baseConfigurationReference"), key)

    def test_import_reads_app_identity_instead_of_test_bundle(self):
        project = (ROOT / signing.PROJECT).read_text()
        project = project.replace(signing.TEAM_VARIABLE, TEAM).replace(signing.BUNDLE_VARIABLE, BUNDLE)
        self.assertEqual(signing.import_values(project), (TEAM, BUNDLE))

    def test_conflicting_debug_release_identities_require_explicit_choice(self):
        project = (ROOT / signing.PROJECT).read_text()
        project = project.replace(signing.TEAM_VARIABLE, TEAM).replace(signing.BUNDLE_VARIABLE, BUNDLE)
        block = signing.configuration(project, "app", "Release")
        project = project.replace(block, block.replace(TEAM, "Z9Y8X7W6V5"))
        with self.assertRaises(ValueError):
            signing.import_values(project)

    def test_invalid_values_cannot_inject_build_settings(self):
        for team, bundle in [("YOURTEAMID", BUNDLE), ("", BUNDLE), (TEAM, "dev.bad;SETTING=YES"),
                             (TEAM + "\n", BUNDLE), (TEAM, "$(OTHER_BUNDLE)"), (TEAM, "dev.bad//comment")]:
            with self.assertRaises(ValueError):
                signing.validate(team, bundle)

    def test_existing_local_settings_are_never_silently_replaced(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertTrue(signing.save_local(root, TEAM, BUNDLE))
            self.assertFalse(signing.save_local(root, TEAM, BUNDLE))
            before = (root / signing.LOCAL).read_bytes()
            with self.assertRaises(ValueError):
                signing.save_local(root, "Z9Y8X7W6V5", "dev.someoneelse.tasklens")
            self.assertEqual((root / signing.LOCAL).read_bytes(), before)

    def test_saved_commit_migration_works_from_server_and_is_git_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for file in ["scripts/configure-signing.py", signing.PROJECT, ".gitignore", "ios/Config/Signing.xcconfig"]:
                dest = root / file
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / file, dest)
            (root / "server").mkdir()
            project = root / signing.PROJECT
            shared = project.read_text()
            project.write_text(shared.replace(signing.TEAM_VARIABLE, TEAM).replace(signing.BUNDLE_VARIABLE, BUNDLE))
            run("git", "init", "-q", cwd=root)
            run("git", "add", ".", cwd=root)
            run("git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Old signing", cwd=root)
            old = run("git", "rev-parse", "HEAD", cwd=root).stdout.strip()
            project.write_text(shared)
            run(sys.executable, "../scripts/configure-signing.py", "--from-commit", old[:7], cwd=root / "server")
            local = root / signing.LOCAL
            self.assertIn(TEAM, local.read_text())
            self.assertIn(BUNDLE, local.read_text())
            self.assertEqual(project.read_text(), shared)
            self.assertEqual(run("git", "check-ignore", signing.LOCAL, cwd=root).stdout.strip(), signing.LOCAL)
            run(sys.executable, "../scripts/configure-signing.py", "--from-commit", old[:7], cwd=root / "server")

    def test_generator_keeps_local_identity_out_of_both_target_configs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for file in ["scripts/configure-signing.py", "scripts/generate-xcode-project.py", "ios/Config/Signing.xcconfig", "ios/Config/Signing.example.xcconfig"]:
                dest = root / file
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / file, dest)
            for file in ["ios/TaskLens/App.swift", "ios/TaskLens/Info.plist", "ios/TaskLensTests/ExampleTests.swift"]:
                dest = root / file
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text("// Fixture only\n")
            signing.save_local(root, TEAM, BUNDLE)
            local_before = (root / signing.LOCAL).read_bytes()
            run(sys.executable, "scripts/generate-xcode-project.py", cwd=root)
            signing.check_shared(root)
            project_before = (root / signing.PROJECT).read_text()
            self.assertNotIn(TEAM, project_before)
            self.assertNotIn(BUNDLE, project_before)
            self.assertIn("App.swift", project_before)
            self.assertIn("ExampleTests.swift", project_before)
            run(sys.executable, "scripts/generate-xcode-project.py", cwd=root)
            self.assertEqual((root / signing.PROJECT).read_text(), project_before)
            self.assertEqual((root / signing.LOCAL).read_bytes(), local_before)


if __name__ == "__main__":
    unittest.main()
