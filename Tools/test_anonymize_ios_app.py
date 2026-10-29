"""Run the actual iOS bundle scrubber without Apple SDKs or signing tools."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parent / "anonymize-ios-app.sh"


class IOSAnonymizationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.app = Path(directory.name) / "NOOP test.app"
        self.app.mkdir()

    def run_scrubber(self, env=None):
        return subprocess.run(["bash", str(SCRIPT), str(self.app)],
                              capture_output=True, text=True, check=False, env=env)

    def test_already_clean_bundle_succeeds_when_grep_has_no_matches(self):
        executable = self.app / "NOOP"
        original = b"\x00already anonymous\x00"
        executable.write_bytes(original)
        result = self.run_scrubber()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("residual home-path hits: 0", result.stdout)
        self.assertEqual(executable.read_bytes(), original)

    def test_verification_tool_error_cannot_be_reported_as_a_clean_bundle(self):
        tools = self.app.parent / "tools"
        tools.mkdir()
        verifier = tools / "grep"
        verifier.write_text("#!/usr/bin/env bash\nexit 2\n")
        verifier.chmod(0o755)
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"])
        result = self.run_scrubber(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("\u2713 clean", result.stdout)

    def test_app_widget_and_framework_are_scrubbed_without_changing_lengths(self):
        home_path = os.fsencode(Path.home())
        original = b"\x00" + home_path + b"/source.swift\x00" + home_path + b"/other.swift\x00"
        paths = ("NOOP", "PlugIns/NOOPWidgets.appex/NOOPWidgets",
                 "Frameworks/Example.framework/Example")
        for relative in paths:
            path = self.app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(original)
        result = self.run_scrubber()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("scrubbed 6 occurrence(s) across 3 file(s)", result.stdout)
        self.assertIn("residual home-path hits: 0", result.stdout)
        for relative in paths:
            scrubbed = (self.app / relative).read_bytes()
            self.assertNotIn(home_path, scrubbed)
            self.assertEqual(len(scrubbed), len(original))


if __name__ == "__main__":
    unittest.main()
