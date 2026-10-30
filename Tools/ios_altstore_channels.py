#!/usr/bin/env python3
"""Update enrolled AltStore feeds without changing their identities or archived IPAs."""

import argparse
import copy
from datetime import date
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid
from urllib.parse import urlsplit


SOURCE_NAME = "altstore-hydration-source.json"
CHECKSUM_NAME = "SHA256SUMS"
DEFAULT_CHANNEL_TAGS = (
    "hydration-coach-36616a7b30d4",
    "hydration-coach-cf9e28b7acb3",
)
_REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
_NAME = re.compile(r"[A-Za-z0-9_.-]+")
_VERSION = re.compile(r"[0-9]+(?:\.[0-9]+){0,2}")
_SHA256 = re.compile(r"[0-9a-f]{64}")


def _repository(repository):
    if (not isinstance(repository, str) or not _REPOSITORY.fullmatch(repository)
            or any(part in (".", "..") for part in repository.split("/"))):
        raise ValueError("Expected a GitHub owner/repository")


def _name(value):
    if not isinstance(value, str) or not _NAME.fullmatch(value) or value in (".", ".."):
        raise ValueError("Expected a release tag or asset name without path components")
    return value


def source_url(repository, tag):
    _repository(repository)
    return f"https://github.com/{repository}/releases/download/{_name(tag)}/{SOURCE_NAME}"


def _download_parts(value, repository, suffix):
    if not isinstance(value, str):
        raise ValueError("Expected a release download URL")
    parsed = urlsplit(value)
    prefix = f"/{repository}/releases/download/"
    if (parsed.scheme != "https" or parsed.netloc != "github.com" or parsed.query or parsed.fragment
            or not parsed.path.startswith(prefix)):
        raise ValueError("Download URL must belong to this GitHub repository")
    parts = parsed.path[len(prefix):].split("/")
    if len(parts) != 2:
        raise ValueError("Expected one release tag and asset name")
    tag, filename = map(_name, parts)
    if not filename.endswith(suffix):
        raise ValueError("Unexpected release asset name")
    return tag, filename


def _version(value):
    if not isinstance(value, str) or not _VERSION.fullmatch(value):
        raise ValueError("Expected a numeric version or build version")
    numbers = tuple(int(part) for part in value.split("."))
    return numbers + (0,) * (3 - len(numbers))


def _version_key(entry):
    return _version(entry.get("version")), _version(entry.get("buildVersion"))


def _feed(feed, repository):
    if not isinstance(feed, dict) or not isinstance(feed.get("identifier"), str) or not feed["identifier"]:
        raise ValueError("Expected an enrolled source identifier")
    if not isinstance(feed.get("name"), str) or not feed["name"]:
        raise ValueError("Expected a source name")
    _, filename = _download_parts(feed.get("sourceURL"), repository, SOURCE_NAME)
    if filename != SOURCE_NAME:
        raise ValueError("Unexpected source asset name")
    apps = feed.get("apps")
    if not isinstance(apps, list) or len(apps) != 1 or not isinstance(apps[0], dict):
        raise ValueError("Expected the single-app hydration source")
    app = apps[0]
    if not isinstance(app.get("bundleIdentifier"), str) or not app["bundleIdentifier"]:
        raise ValueError("Expected an app bundle identifier")
    versions = app.get("versions")
    if not isinstance(versions, list) or not versions:
        raise ValueError("Expected at least one app version")
    keys = []
    for entry in versions:
        if not isinstance(entry, dict):
            raise ValueError("Invalid version entry")
        keys.append(_version_key(entry))
        _download_parts(entry.get("downloadURL"), repository, ".ipa")
        if type(entry.get("size")) is not int or entry["size"] <= 0:
            raise ValueError("Version size must be a positive byte count")
        _version(entry.get("minOSVersion"))
        if not isinstance(entry.get("date"), str):
            raise ValueError("Expected an ISO version date")
        date.fromisoformat(entry["date"])
    if len(set(keys)) != len(keys) or keys != sorted(keys, reverse=True):
        raise ValueError("Versions must be unique and ordered newest first")
    first = versions[0]
    for legacy, field in (("version", "version"), ("buildVersion", "buildVersion"),
                          ("downloadURL", "downloadURL"), ("size", "size"),
                          ("minOSVersion", "minOSVersion"), ("versionDate", "date")):
        if legacy in app and app[legacy] != first[field]:
            raise ValueError("Legacy app metadata does not match the newest version")
    return app


def merge_channel(existing, latest, repository):
    """Keep installed-source identity and history while advertising the newest verified build."""
    _repository(repository)
    old_app = _feed(existing, repository)
    new_app = _feed(latest, repository)
    if old_app["bundleIdentifier"] != new_app["bundleIdentifier"]:
        raise ValueError("An enrolled app bundle identifier cannot change")
    if _version_key(new_app["versions"][0]) < _version_key(old_app["versions"][0]):
        raise ValueError("Refusing to downgrade an enrolled source")
    versions = {_version_key(entry): copy.deepcopy(entry) for entry in old_app["versions"]}
    versions.update({_version_key(entry): copy.deepcopy(entry) for entry in new_app["versions"]})
    result = copy.deepcopy(latest)
    result["identifier"] = existing["identifier"]
    result["sourceURL"] = existing["sourceURL"]
    result["apps"][0]["versions"] = [versions[key] for key in sorted(versions, reverse=True)]
    _feed(result, repository)
    return result


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def parse_checksums(data):
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as error:
        raise ValueError("Checksum manifest must be ASCII") from error
    entries = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)", line)
        if not match or match[2] in entries:
            raise ValueError("Invalid or duplicate checksum manifest entry")
        entries[match[2]] = match[1]
    if SOURCE_NAME not in entries:
        raise ValueError("Checksum manifest does not cover the source JSON")
    return entries


def replace_source_checksum(manifest, source_bytes):
    """Change only the JSON digest; archived IPA hashes and other manifest entries stay intact."""
    parse_checksums(manifest)
    lines = manifest.decode("ascii").splitlines(keepends=True)
    replacement = _sha256(source_bytes)
    return "".join(replacement + line[64:] if line[66:].strip() == SOURCE_NAME else line
                   for line in lines).encode("ascii")


def _gh(*arguments):
    result = subprocess.run(["gh", *arguments], check=False, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"GitHub command failed ({arguments[0]}): {result.stderr.strip()}")
    return result.stdout


def _release(repository, tag):
    release = json.loads(_gh("api", f"repos/{repository}/releases/tags/{_name(tag)}"))
    if release.get("tag_name") != tag or release.get("draft"):
        raise ValueError("Expected a published release with the requested tag")
    return release


def _asset(release, name):
    found = [asset for asset in release.get("assets", []) if asset.get("name") == name]
    if len(found) != 1:
        raise ValueError(f"Release must contain exactly one {name} asset")
    asset = found[0]
    digest = asset.get("digest", "")
    if not isinstance(digest, str) or not digest.startswith("sha256:") or not _SHA256.fullmatch(digest[7:]):
        raise ValueError(f"GitHub did not provide a SHA-256 digest for {name}")
    return asset


def _read_release(repository, tag, directory, require_local_ipa=False):
    release = _release(repository, tag)
    source_asset, manifest_asset = _asset(release, SOURCE_NAME), _asset(release, CHECKSUM_NAME)
    directory.mkdir(parents=True, exist_ok=True)
    _gh("release", "download", tag, "--repo", repository, "--dir", str(directory),
        "--pattern", SOURCE_NAME, "--pattern", CHECKSUM_NAME, "--clobber")
    source_bytes = (directory / SOURCE_NAME).read_bytes()
    manifest = (directory / CHECKSUM_NAME).read_bytes()
    if (_sha256(source_bytes) != source_asset["digest"][7:]
            or _sha256(manifest) != manifest_asset["digest"][7:]):
        raise ValueError("Downloaded metadata does not match GitHub's asset digests")
    checksums = parse_checksums(manifest)
    if checksums[SOURCE_NAME] != _sha256(source_bytes):
        raise ValueError("Source JSON does not match its checksum manifest")
    feed = json.loads(source_bytes)
    app = _feed(feed, repository)
    if feed["sourceURL"] != source_url(repository, tag):
        raise ValueError("Source URL differs from the enrolled release asset URL")
    if require_local_ipa:
        version = app["versions"][0]
        ipa_tag, filename = _download_parts(version["downloadURL"], repository, ".ipa")
        asset = _asset(release, filename)
        if (ipa_tag != tag or version["downloadURL"] != asset.get("browser_download_url")
                or version["size"] != asset.get("size")
                or checksums.get(filename) != asset["digest"][7:]):
            raise ValueError("Newest IPA metadata must match this release's checksummed archive")
    return {"tag": tag, "release": release, "feed": feed, "manifest": manifest,
            "source_digest": source_asset["digest"], "manifest_digest": manifest_asset["digest"],
            "directory": directory}


def prepare_updates(repository, release_tag, channel_tags, directory):
    """Read and validate every input before making any release asset writes."""
    _repository(repository)
    latest = _read_release(repository, release_tag, directory / "latest", require_local_ipa=True)
    updates = []
    for tag in dict.fromkeys(channel_tags):
        _name(tag)
        channel = _read_release(repository, tag, directory / tag / "before")
        merged = merge_channel(channel["feed"], latest["feed"], repository)
        after = directory / tag / "after"
        after.mkdir(parents=True, exist_ok=True)
        source_bytes = (json.dumps(merged, ensure_ascii=False, indent=2) + "\n").encode()
        (after / SOURCE_NAME).write_bytes(source_bytes)
        (after / CHECKSUM_NAME).write_bytes(replace_source_checksum(channel["manifest"], source_bytes))
        channel.update(after=after, changed=merged != channel["feed"], merged=merged)
        updates.append(channel)
    return updates


def _rename_asset(repository, asset_id, name):
    _name(name)
    _gh("api", "--method", "PATCH", f"repos/{repository}/releases/assets/{asset_id}",
        "-f", f"name={name}")


def _delete_asset(repository, asset_id):
    _gh("api", "--method", "DELETE", f"repos/{repository}/releases/assets/{asset_id}")


def _remove_staged_assets(repository, tag, names):
    """Only unique names created by this attempt are eligible for failed-upload cleanup."""
    current = _release(repository, tag)
    for asset in current.get("assets", []):
        if asset.get("name") in names:
            _delete_asset(repository, asset["id"])


def publish_updates(repository, updates):
    changed = [update for update in updates if update["changed"]]
    # A second workflow or manual publisher must not be silently overwritten after staging.
    for update in changed:
        current = _release(repository, update["tag"])
        if (_asset(current, SOURCE_NAME)["digest"] != update["source_digest"]
                or _asset(current, CHECKSUM_NAME)["digest"] != update["manifest_digest"]):
            raise ValueError("Channel changed after staging; rerun with current metadata")
    for update in changed:
        nonce = uuid.uuid4().hex
        staged_names = {name: f"altstore-staged-{nonce}-{name}" for name in (SOURCE_NAME, CHECKSUM_NAME)}
        backup_names = {name: f"altstore-backup-{nonce}-{name}" for name in (SOURCE_NAME, CHECKSUM_NAME)}
        upload = update["after"] / "staged-upload"
        upload.mkdir(parents=True, exist_ok=True)
        for name, staged_name in staged_names.items():
            (upload / staged_name).write_bytes((update["after"] / name).read_bytes())
        paths = [str(upload / staged_names[name]) for name in (SOURCE_NAME, CHECKSUM_NAME)]
        # Never clobber a working URL just to discover that uploads.github.com rejects the token.
        try:
            _gh("release", "upload", update["tag"], *paths, "--repo", repository)
        except RuntimeError as error:
            try:
                _remove_staged_assets(repository, update["tag"], set(staged_names.values()))
            except (RuntimeError, ValueError):
                print("Staged upload cleanup failed; canonical metadata was not touched.", file=sys.stderr)
            raise RuntimeError("Staging upload failed; original source and checksums were not touched") from error
        current = _release(repository, update["tag"])
        old_assets = {name: _asset(current, name) for name in (SOURCE_NAME, CHECKSUM_NAME)}
        new_assets = {name: _asset(current, staged_names[name]) for name in (SOURCE_NAME, CHECKSUM_NAME)}
        if (old_assets[SOURCE_NAME]["digest"] != update["source_digest"]
                or old_assets[CHECKSUM_NAME]["digest"] != update["manifest_digest"]):
            _remove_staged_assets(repository, update["tag"], set(staged_names.values()))
            raise ValueError("Channel changed after staging upload; original metadata was not touched")
        for name, asset in new_assets.items():
            data = (update["after"] / name).read_bytes()
            if asset["digest"] != "sha256:" + _sha256(data) or asset.get("size") != len(data):
                _remove_staged_assets(repository, update["tag"], set(staged_names.values()))
                raise ValueError("Staged upload failed integrity verification; original metadata was not touched")
        try:
            for name, asset in old_assets.items():
                _rename_asset(repository, asset["id"], backup_names[name])
            for name, asset in new_assets.items():
                _rename_asset(repository, asset["id"], name)
            checked = _read_release(repository, update["tag"], update["after"] / "verified")
            if checked["feed"] != json.loads((update["after"] / SOURCE_NAME).read_text()):
                raise ValueError("Published source differs from the reviewed update")
        except (RuntimeError, ValueError) as error:
            try:
                for name, asset in new_assets.items():
                    _rename_asset(repository, asset["id"], staged_names[name])
                for name, asset in old_assets.items():
                    _rename_asset(repository, asset["id"], name)
            except RuntimeError as rollback_error:
                raise RuntimeError("Metadata rename rollback failed; retain release backup assets for recovery") from rollback_error
            _remove_staged_assets(repository, update["tag"], set(staged_names.values()))
            raise RuntimeError("Metadata update failed; original asset names were restored") from error
        for asset in old_assets.values():
            try:
                _delete_asset(repository, asset["id"])
            except RuntimeError:
                print("Source update verified; an old backup asset could not be removed.", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--release-tag", required=True)
    parser.add_argument("--channel-tag", action="append", dest="channel_tags")
    parser.add_argument("--output-dir", type=Path, default=Path("build/altstore-channels"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    updates = prepare_updates(args.repository, args.release_tag,
                              args.channel_tags or DEFAULT_CHANNEL_TAGS, args.output_dir)
    for update in updates:
        app = update["merged"]["apps"][0]
        print(json.dumps({"channel": update["tag"], "changed": update["changed"],
                          "identifier": update["merged"]["identifier"],
                          "sourceURL": update["merged"]["sourceURL"], "version": app["version"],
                          "build": app["buildVersion"], "prepared": str(update["after"])}))
    if not args.dry_run:
        publish_updates(args.repository, updates)


if __name__ == "__main__":
    main()
