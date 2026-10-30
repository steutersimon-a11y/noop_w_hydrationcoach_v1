#!/usr/bin/env python3
"""Validate a device IPA and generate an isolated AltStore source for a fork test build."""
import argparse
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import re
from urllib.parse import quote
import zipfile


def make_source(template, ipa_path, repository, tag, commit, date=None):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Expected a GitHub owner/repository")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected the full built commit SHA")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", tag):
        raise ValueError("Expected a release tag without path components")
    ipa_path = Path(ipa_path)
    app_root = "Payload/NOOP.app/"
    widget_root = app_root + "PlugIns/NOOPWidgets.appex/"
    with zipfile.ZipFile(ipa_path) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA archive failed its CRC check")
        names = archive.namelist()
        if any(name.startswith(app_root + "Watch/") for name in names):
            raise ValueError("Remove the watch app before sideload packaging")
        try:
            info = plistlib.loads(archive.read(app_root + "Info.plist"))
            widget = plistlib.loads(archive.read(widget_root + "Info.plist"))
        except KeyError as error:
            raise ValueError("IPA must include the app and its widget") from error
        if "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
            raise ValueError("A device IPA is required, not an iOS Simulator build")
        if info.get("CFBundleIdentifier") != template["apps"][0]["bundleIdentifier"]:
            raise ValueError("IPA bundle identifier differs from the AltStore source")
        for field in ("CFBundleVersion", "CFBundleShortVersionString"):
            if not info.get(field) or info[field] != widget.get(field):
                raise ValueError("App and widget versions must match")
        if not info.get("AppGroupIdentifier") or info["AppGroupIdentifier"] != widget.get("AppGroupIdentifier"):
            raise ValueError("App and widget must share their App Group")
        for root, plist in ((app_root, info), (widget_root, widget)):
            executable = plist.get("CFBundleExecutable", "")
            if not executable or "/" in executable or executable in (".", ".."):
                raise ValueError("Invalid app or widget executable")
            if root + executable not in names:
                raise ValueError("App or widget executable is missing")

    result = copy.deepcopy(template)
    base = f"https://github.com/{repository}/releases/download/{quote(tag, safe='')}"
    download = f"{base}/{quote(ipa_path.name, safe='')}"
    description = (
        f"NOOP Hydration Coach iOS build, commit {commit}. "
        "Sign with AltStore Classic or SideStore. Uses NOOP's existing app identifier, "
        "so it can replace an installed NOOP; back up existing data before switching. "
        "Wake time stays in NOOP's Alarms screen. The shared WHOOP 4.0 alarm supports a "
        "wake-to-hydration-to-bedtime routine; following alarms require Bluetooth and iOS "
        "background event delivery. Physical haptics remain unverified."
    )
    result.update({
        "name": "NOOP Hydration Coach",
        "identifier": f"com.noopapp.noop.altstore.hydration.{repository.lower().replace('/', '.').replace('_', '-')}.{tag}",
        "sourceURL": base + "/altstore-hydration-source.json",
        "subtitle": "Wake alarm and adaptive hydration routine",
        "description": description + " Based on the NOOP project: https://github.com/ryanbr/noop",
        "website": f"https://github.com/{repository}/releases/tag/{quote(tag, safe='')}",
        "news": [],
    })
    app = copy.deepcopy(template["apps"][0])
    entry = {
        "version": info["CFBundleShortVersionString"],
        "buildVersion": info["CFBundleVersion"],
        "date": date or datetime.now(timezone.utc).date().isoformat(),
        "localizedDescription": description,
        "downloadURL": download,
        "size": ipa_path.stat().st_size,
        "minOSVersion": info["MinimumOSVersion"],
    }
    app.update({
        "name": "NOOP Hydration Coach",
        "subtitle": "Optional hydration reminders on your iPhone",
        "localizedDescription": description,
        "versions": [entry],
        "version": entry["version"],
        "buildVersion": entry["buildVersion"],
        "versionDate": entry["date"],
        "versionDescription": description,
        "downloadURL": download,
        "size": entry["size"],
        "minOSVersion": entry["minOSVersion"],
    })
    # Retain the original project's attribution, icon and signing permission declarations.
    result["apps"] = [app]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = make_source(json.loads(args.template.read_text()), args.ipa,
                         args.repository, args.tag, args.commit)
    args.output.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
