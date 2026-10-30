"""Device-only sideload metadata and fork download regressions, without Apple SDKs."""
import copy
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

from ios_sideload_source import make_source


class IOSSideloadSourceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ipa = Path(self.directory.name) / "NOOP-hydration.ipa"
        self.template = json.loads((Path(__file__).resolve().parents[1] / "altstore-source.json").read_text())
        self.app = {
            "CFBundleIdentifier": self.template["apps"][0]["bundleIdentifier"],
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "CFBundleExecutable": "NOOP",
            "CFBundleShortVersionString": "12.1.0", "CFBundleVersion": "439",
            "MinimumOSVersion": "17.0", "AppGroupIdentifier": "group.noop.test",
        }
        self.widget = dict(self.app, CFBundleExecutable="NOOPWidgets",
                           CFBundleIdentifier=self.app["CFBundleIdentifier"] + ".widgets")

    def write_ipa(self, widget=True, watch=False, executable=True):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            root = "Payload/NOOP.app/"
            archive.writestr(root + "Info.plist", plistlib.dumps(self.app))
            if executable:
                archive.writestr(root + "NOOP", b"fixture")
            if widget:
                root += "PlugIns/NOOPWidgets.appex/"
                archive.writestr(root + "Info.plist", plistlib.dumps(self.widget))
                archive.writestr(root + "NOOPWidgets", b"fixture")
            if watch:
                archive.writestr("Payload/NOOP.app/Watch/NOOPWatch.app/Info.plist", b"fixture")

    def generate(self):
        return make_source(self.template, self.ipa, "example/fork", "hydration-test-123",
                           "a" * 40, date="2026-10-29")

    def test_fork_source_uses_actual_ipa_metadata_without_mutating_original(self):
        self.write_ipa()
        original = copy.deepcopy(self.template)
        source = self.generate()
        self.assertEqual(self.template, original)
        self.assertEqual(source["sourceURL"], "https://github.com/example/fork/releases/download/hydration-test-123/altstore-hydration-source.json")
        self.assertNotEqual(source["identifier"], original["identifier"])
        self.assertEqual(source["news"], [])
        app = source["apps"][0]
        self.assertEqual(len(app["versions"]), 1, "do not advertise original-repository releases")
        version = app["versions"][0]
        self.assertEqual(version["version"], "12.1.0")
        self.assertEqual(version["buildVersion"], "439")
        self.assertEqual(version["minOSVersion"], "17.0")
        self.assertEqual(version["size"], self.ipa.stat().st_size)
        self.assertEqual(app["downloadURL"], version["downloadURL"])
        self.assertEqual(app["bundleIdentifier"], original["apps"][0]["bundleIdentifier"])
        self.assertEqual(app.get("appPermissions"), original["apps"][0].get("appPermissions"))
        self.assertIn("a" * 40, app["localizedDescription"])
        self.assertIn("can replace an installed NOOP", app["localizedDescription"])

    def test_simulator_binary_cannot_be_advertised_as_a_device_ipa(self):
        self.app["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        self.write_ipa()
        with self.assertRaisesRegex(ValueError, "device IPA"):
            self.generate()

    def test_missing_widget_watch_and_missing_executable_fail_closed(self):
        for options in ({"widget": False}, {"watch": True}, {"executable": False}):
            with self.subTest(options=options):
                self.write_ipa(**options)
                with self.assertRaises(ValueError):
                    self.generate()

    def test_bundle_version_and_app_group_mismatches_are_rejected(self):
        for target, field in ((self.app, "CFBundleIdentifier"), (self.widget, "CFBundleVersion"),
                              (self.widget, "AppGroupIdentifier")):
            with self.subTest(field=field):
                old = target[field]
                target[field] = "wrong"
                self.write_ipa()
                with self.assertRaises(ValueError):
                    self.generate()
                target[field] = old

    def test_release_and_repository_paths_cannot_inject_a_different_download_origin(self):
        self.write_ipa()
        with self.assertRaises(ValueError):
            make_source(self.template, self.ipa, "https://other.example/fork", "test", "a" * 40)
        with self.assertRaises(ValueError):
            make_source(self.template, self.ipa, "example/fork", "../other", "a" * 40)
        with self.assertRaises(ValueError):
            make_source(self.template, self.ipa, "example/fork", "test", "main")


if __name__ == "__main__":
    unittest.main()
