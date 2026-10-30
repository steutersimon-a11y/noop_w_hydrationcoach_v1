"""Stable installed-source updates, integrity and fail-closed publication without network access."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ios_altstore_channels as channels


REPOSITORY = "example/fork"
OLD, NEW = channels.DEFAULT_CHANNEL_TAGS


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def feed(tag, version="12.1.0", build="439", size=10):
    base = f"https://github.com/{REPOSITORY}/releases/download/{tag}"
    entry = {"version": version, "buildVersion": build, "date": "2026-10-30",
             "downloadURL": base + f"/NOOP-{tag}.ipa", "size": size, "minOSVersion": "17.0",
             "localizedDescription": f"Build {tag}"}
    return {"name": "NOOP Hydration Coach", "identifier": "existing.identity." + tag,
            "sourceURL": base + "/" + channels.SOURCE_NAME, "news": [],
            "apps": [{"name": "NOOP", "bundleIdentifier": "com.noopapp.noop",
                      "versions": [entry], "version": version, "buildVersion": build,
                      "versionDate": entry["date"], "downloadURL": entry["downloadURL"],
                      "size": size, "minOSVersion": "17.0", "developerName": "NoopApp",
                      "appPermissions": {"entitlements": ["com.apple.developer.healthkit"]}}]}


class FakeGitHub:
    def __init__(self):
        self.calls = []
        self.assets = {}
        self.ids = {}
        self.next_id = 1
        self.fail_upload_once = False
        self.fail_rename_once = False
        for tag, version, build in ((OLD, "12.1.0", "439"), (NEW, "12.1.1", "440")):
            ipa = b"verified fixture archive"
            source = encoded(feed(tag, version, build, len(ipa)))
            name = f"NOOP-{tag}.ipa"
            manifest = (f"{digest(ipa)}  {name}\n{digest(source)}  {channels.SOURCE_NAME}\n").encode()
            self.assets[tag] = {name: ipa, channels.SOURCE_NAME: source, channels.CHECKSUM_NAME: manifest}
            self.ids[tag] = {}
            for filename in self.assets[tag]:
                self.ids[tag][filename] = self.next_id
                self.next_id += 1

    def release(self, tag):
        return {"tag_name": tag, "draft": False,
                "assets": [{"id": self.ids[tag][name], "name": name, "size": len(data), "digest": "sha256:" + digest(data),
                            "browser_download_url": f"https://github.com/{REPOSITORY}/releases/download/{tag}/{name}"}
                           for name, data in self.assets[tag].items()]}

    def __call__(self, *arguments):
        self.calls.append(arguments)
        if arguments[0] == "api":
            if arguments[1] == "--method":
                method = arguments[2]
                asset_id = int(arguments[3].split("/")[-1])
                tag, old_name = next((tag, name) for tag in self.ids for name, value in self.ids[tag].items()
                                     if value == asset_id)
                if method == "PATCH":
                    if self.fail_rename_once and arguments[-1] == "name=" + channels.SOURCE_NAME:
                        self.fail_rename_once = False
                        raise RuntimeError("simulated rename failure")
                    name = arguments[-1].removeprefix("name=")
                    if name in self.ids[tag] and self.ids[tag][name] != asset_id:
                        raise RuntimeError("duplicate asset name")
                    data = self.assets[tag].pop(old_name)
                    self.ids[tag].pop(old_name)
                    self.assets[tag][name] = data
                    self.ids[tag][name] = asset_id
                elif method == "DELETE":
                    self.assets[tag].pop(old_name)
                    self.ids[tag].pop(old_name)
                else:
                    raise AssertionError("Unexpected API mutation")
                return "{}"
            return json.dumps(self.release(arguments[1].split("/")[-1]))
        action, tag = arguments[1:3]
        if action == "download":
            directory = Path(arguments[arguments.index("--dir") + 1])
            directory.mkdir(parents=True, exist_ok=True)
            for name in (channels.SOURCE_NAME, channels.CHECKSUM_NAME):
                (directory / name).write_bytes(self.assets[tag][name])
            return ""
        if action == "upload":
            if "--clobber" in arguments:
                raise AssertionError("Clobber can delete working canonical assets before upload succeeds")
            paths = arguments[3:arguments.index("--repo")]
            if self.fail_upload_once:
                self.fail_upload_once = False
                first = Path(paths[0])
                self.assets[tag][first.name] = first.read_bytes()
                self.ids[tag][first.name] = self.next_id
                self.next_id += 1
                raise RuntimeError("simulated partial upload")
            for value in paths:
                path = Path(value)
                if path.name in self.assets[tag]:
                    raise RuntimeError("upload name already exists")
                self.assets[tag][path.name] = path.read_bytes()
                self.ids[tag][path.name] = self.next_id
                self.next_id += 1
            return ""
        raise AssertionError("Unexpected mutation: " + repr(arguments))

    @property
    def uploads(self):
        return [call for call in self.calls if call[:2] == ("release", "upload")]


class AltStoreChannelTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)
        self.github = FakeGitHub()
        self.mock = patch.object(channels, "_gh", self.github)
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def prepare(self):
        return channels.prepare_updates(REPOSITORY, NEW, [OLD, NEW], self.directory)

    def test_upgrade_keeps_enrolled_identity_url_bundle_and_history(self):
        old, latest = feed(OLD), feed(NEW, "12.1.1", "440")
        before = copy.deepcopy((old, latest))
        merged = channels.merge_channel(old, latest, REPOSITORY)
        self.assertEqual((old, latest), before, "no input feed may be mutated")
        self.assertEqual(merged["identifier"], old["identifier"])
        self.assertEqual(merged["sourceURL"], old["sourceURL"])
        app = merged["apps"][0]
        self.assertEqual(app["bundleIdentifier"], old["apps"][0]["bundleIdentifier"])
        self.assertEqual(app["appPermissions"], latest["apps"][0]["appPermissions"])
        self.assertEqual([item["version"] for item in app["versions"]], ["12.1.1", "12.1.0"])
        self.assertEqual(app["downloadURL"], latest["apps"][0]["downloadURL"])
        self.assertEqual(app["version"], "12.1.1")
        self.assertEqual(channels.merge_channel(merged, latest, REPOSITORY), merged)

    def test_numeric_version_and_build_precedence_prevent_downgrades(self):
        for current, candidate in ((feed(OLD, "12.1.10"), feed(NEW, "12.1.9")),
                                   (feed(OLD, "12.1.1", "440"), feed(NEW, "12.1.1", "439"))):
            with self.subTest(current=current["apps"][0]["version"]):
                with self.assertRaisesRegex(ValueError, "downgrade"):
                    channels.merge_channel(current, candidate, REPOSITORY)
        current = feed(OLD, "12.1.1", "440")
        latest = feed(NEW, "12.1.1", "441")
        merged = channels.merge_channel(current, latest, REPOSITORY)
        self.assertEqual([v["buildVersion"] for v in merged["apps"][0]["versions"]], ["441", "440"])

    def test_equal_version_build_can_refresh_archive_metadata_without_duplicate_version(self):
        old, latest = feed(OLD, "12.1.1", "440"), feed(NEW, "12.1.1", "440")
        merged = channels.merge_channel(old, latest, REPOSITORY)
        self.assertEqual(len(merged["apps"][0]["versions"]), 1)
        self.assertEqual(merged["apps"][0]["downloadURL"], latest["apps"][0]["downloadURL"])
        self.assertEqual(merged["identifier"], old["identifier"])

    def test_foreign_urls_renamed_assets_and_changed_apps_are_rejected(self):
        for repository in ("../fork", "example/..", "./fork", "https://example/fork"):
            with self.subTest(repository=repository), self.assertRaises(ValueError):
                channels.merge_channel(feed(OLD), feed(NEW), repository)
        for field, value in (("sourceURL", "https://other.example/feed.json"),
                             ("sourceURL", channels.source_url(REPOSITORY, NEW).replace("altstore-hydration", "wrong"))):
            bad = feed(NEW, "12.1.1", "440")
            bad[field] = value
            with self.assertRaises(ValueError):
                channels.merge_channel(feed(OLD), bad, REPOSITORY)
        for url in ("https://github.com/other/repo/releases/download/tag/NOOP.ipa",
                    "https://github.com@example.org/example/fork/releases/download/tag/NOOP.ipa",
                    "https://github.com/example/fork/releases/download/../NOOP.ipa",
                    "https://github.com/example/fork/releases/download/tag/%2fNOOP.ipa"):
            bad = feed(NEW, "12.1.1", "440")
            bad["apps"][0]["versions"][0]["downloadURL"] = url
            bad["apps"][0]["downloadURL"] = url
            with self.assertRaises(ValueError):
                channels.merge_channel(feed(OLD), bad, REPOSITORY)
        bad = feed(NEW, "12.1.1", "440")
        bad["apps"][0]["bundleIdentifier"] = "different.app"
        with self.assertRaisesRegex(ValueError, "bundle identifier"):
            channels.merge_channel(feed(OLD), bad, REPOSITORY)

    def test_malformed_versions_sizes_and_legacy_fields_fail_closed(self):
        for field, value in (("size", True), ("size", -1), ("version", "12-beta"),
                             ("buildVersion", "440/script"), ("date", "tomorrow"), ("minOSVersion", None)):
            bad = feed(NEW, "12.1.1", "440")
            bad["apps"][0]["versions"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                channels.merge_channel(feed(OLD), bad, REPOSITORY)
        bad = feed(NEW, "12.1.1", "440")
        bad["apps"][0]["downloadURL"] = feed(OLD)["apps"][0]["downloadURL"]
        with self.assertRaisesRegex(ValueError, "Legacy"):
            channels.merge_channel(feed(OLD), bad, REPOSITORY)

    def test_checksum_replacement_preserves_archived_ipa_digest_and_format(self):
        original = self.github.assets[OLD][channels.CHECKSUM_NAME]
        replacement = channels.replace_source_checksum(original, b"new JSON")
        self.assertEqual(original.splitlines()[0], replacement.splitlines()[0])
        self.assertEqual(channels.parse_checksums(replacement)[channels.SOURCE_NAME], digest(b"new JSON"))
        for bad in (b"", b"not a manifest", original + original.splitlines()[0] + b"\n"):
            with self.assertRaises(ValueError):
                channels.replace_source_checksum(bad, b"new JSON")

    def test_publication_updates_only_changed_json_and_manifest_then_is_idempotent(self):
        original_ipa = self.github.assets[OLD][f"NOOP-{OLD}.ipa"]
        updates = self.prepare()
        self.assertEqual([u["changed"] for u in updates], [True, False])
        self.assertEqual(self.github.uploads, [])
        channels.publish_updates(REPOSITORY, updates)
        self.assertEqual(len(self.github.uploads), 1)
        uploaded = self.github.uploads[0]
        paths = uploaded[3:uploaded.index("--repo")]
        self.assertTrue(all(Path(path).name.startswith("altstore-staged-") for path in paths))
        self.assertEqual({Path(path).read_bytes() for path in paths},
                         {self.github.assets[OLD][channels.SOURCE_NAME], self.github.assets[OLD][channels.CHECKSUM_NAME]})
        self.assertEqual(self.github.assets[OLD][f"NOOP-{OLD}.ipa"], original_ipa)
        updated = json.loads(self.github.assets[OLD][channels.SOURCE_NAME])
        self.assertEqual(updated["identifier"], feed(OLD)["identifier"])
        self.assertEqual(updated["apps"][0]["version"], "12.1.1")
        self.github.calls.clear()
        updates = self.prepare()
        self.assertFalse(any(u["changed"] for u in updates))
        channels.publish_updates(REPOSITORY, updates)
        self.assertEqual(self.github.uploads, [])

    def test_failed_second_channel_validation_cannot_publish_the_first(self):
        original = self.github.assets[NEW][channels.CHECKSUM_NAME]
        self.github.assets[NEW][channels.CHECKSUM_NAME] = original.replace(
            digest(self.github.assets[NEW][channels.SOURCE_NAME]).encode(), b"0" * 64)
        with self.assertRaisesRegex(ValueError, "checksum manifest"):
            self.prepare()
        self.assertEqual(self.github.uploads, [])

    def test_latest_ipa_checksum_and_size_must_match_actual_release_assets(self):
        source = json.loads(self.github.assets[NEW][channels.SOURCE_NAME])
        source["apps"][0]["versions"][0]["size"] += 1
        source["apps"][0]["size"] += 1
        data = encoded(source)
        self.github.assets[NEW][channels.SOURCE_NAME] = data
        self.github.assets[NEW][channels.CHECKSUM_NAME] = channels.replace_source_checksum(
            self.github.assets[NEW][channels.CHECKSUM_NAME], data)
        with self.assertRaisesRegex(ValueError, "Newest IPA"):
            self.prepare()
        self.assertEqual(self.github.uploads, [])

    def test_concurrent_channel_change_is_not_overwritten(self):
        updates = self.prepare()
        self.github.assets[OLD][channels.SOURCE_NAME] += b" "
        with self.assertRaisesRegex(ValueError, "changed after staging"):
            channels.publish_updates(REPOSITORY, updates)
        self.assertEqual(self.github.uploads, [])

    def test_failed_staging_upload_never_renames_or_deletes_original_metadata(self):
        before = copy.deepcopy(self.github.assets)
        original_ids = {name: self.github.ids[OLD][name] for name in (channels.SOURCE_NAME, channels.CHECKSUM_NAME)}
        updates = self.prepare()
        self.github.fail_upload_once = True
        with self.assertRaisesRegex(RuntimeError, "original source and checksums were not touched"):
            channels.publish_updates(REPOSITORY, updates)
        self.assertEqual(self.github.assets, before)
        self.assertEqual(len(self.github.uploads), 1)
        mutations = [call for call in self.github.calls if call[:2] == ("api", "--method")]
        self.assertFalse(any(call[2] == "PATCH" for call in mutations))
        self.assertTrue(all(int(call[3].split("/")[-1]) not in original_ids.values() for call in mutations))

    def test_failed_canonical_rename_restores_original_names_without_new_upload(self):
        before = copy.deepcopy(self.github.assets)
        updates = self.prepare()
        self.github.fail_rename_once = True
        with self.assertRaisesRegex(RuntimeError, "original asset names were restored"):
            channels.publish_updates(REPOSITORY, updates)
        self.assertEqual(self.github.assets, before)
        self.assertEqual(len(self.github.uploads), 1, "rollback must use API rename, not another upload")

    def test_dry_run_leaves_reviewable_files_without_publishing(self):
        args = ["ios_altstore_channels.py", "--repository", REPOSITORY, "--release-tag", NEW,
                "--output-dir", str(self.directory), "--dry-run"]
        with patch("sys.argv", args), patch("builtins.print"):
            channels.main()
        self.assertTrue((self.directory / OLD / "after" / channels.SOURCE_NAME).is_file())
        self.assertEqual(self.github.uploads, [])


if __name__ == "__main__":
    unittest.main()
