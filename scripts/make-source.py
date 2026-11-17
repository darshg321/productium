#!/usr/bin/env python3
"""Writes a SideStore/AltStore source for the free build.

  make-source.py <repo owner/name> <bundle id> <version> <build> <ipa path or size> [out.json]

CI runs it on every release and attaches the result as source.json, so
https://github.com/<repo>/releases/latest/download/source.json is always current.
"""
import json, os, sys, datetime

repo, bundle, version, build, ipa = sys.argv[1:6]
out = sys.argv[6] if len(sys.argv) > 6 else "source.json"
size = os.path.getsize(ipa) if os.path.exists(ipa) else int(ipa)
base = f"https://github.com/{repo}"
raw = f"https://raw.githubusercontent.com/{repo}/main"

source = {
    "name": "Productium",
    "identifier": f"{bundle}.source",
    "subtitle": "A calm planner for school",
    "description": "Productium plans your study around school, sleep and free time.",
    "iconURL": f"{raw}/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
    "website": base,
    "apps": [{
        "name": "Productium",
        "bundleIdentifier": bundle,
        "developerName": repo.split("/")[0],
        "subtitle": "Plans your study around your life",
        "localizedDescription": "A calm iOS life planner for high-school students: one box for everything, a live plan, sleep-aware wake-ups and less scrolling.",
        "iconURL": f"{raw}/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
        "tintColor": "3478F6",
        "category": "productivity",
        "versions": [{
            "version": version,
            "buildVersion": build,
            "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "localizedDescription": f"See {base}/releases/tag/v{version}",
            "downloadURL": f"{base}/releases/latest/download/Productium-free.ipa",
            "size": size,
            "minOSVersion": "17.0",
        }],
        # legacy fields: older SideStore/AltStore builds read these instead of versions[]
        "version": version,
        "versionDate": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "versionDescription": f"See {base}/releases/tag/v{version}",
        "downloadURL": f"{base}/releases/latest/download/Productium-free.ipa",
        "size": size,
        "appPermissions": {"entitlements": [], "privacy": {}},
    }],
    "news": [],
}
json.dump(source, open(out, "w"), indent=2)
print(out)
