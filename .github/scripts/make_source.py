#!/usr/bin/env python3
"""Generate the Quill AltStore-style source JSON from all published GitHub Releases.

Usage: make_source.py --repo OWNER/REPO --out source.json [--icon-url URL]
Needs the `gh` CLI with GH_TOKEN set. Python stdlib only. An empty release list is fine.
"""
import argparse
import json
import subprocess
import sys

BUNDLE_ID = "app.quill.sign"
ASSET_NAME = "Quill.ipa"


def gh_releases(repo):
    releases, page = [], 1
    while True:
        out = subprocess.run(
            ["gh", "api", f"repos/{repo}/releases?per_page=100&page={page}"],
            check=True, capture_output=True, text=True,
        ).stdout
        chunk = json.loads(out or "[]")
        if not isinstance(chunk, list):
            raise SystemExit(f"unexpected API response: {out[:200]}")
        releases.extend(chunk)
        if len(chunk) < 100:
            return releases
        page += 1


def build_versions(releases):
    versions = []
    for r in releases:
        if r.get("draft") or r.get("prerelease"):
            continue
        asset = next((a for a in r.get("assets") or [] if a.get("name") == ASSET_NAME), None)
        if not asset:
            continue
        versions.append({
            "version": (r.get("tag_name") or "").lstrip("v"),
            "date": r.get("published_at") or r.get("created_at") or "",
            "localizedDescription": (r.get("body") or "").strip(),
            "downloadURL": asset["browser_download_url"],
            "size": int(asset.get("size") or 0),
            "minOSVersion": "16.0",
        })
    versions.sort(key=lambda v: v["date"], reverse=True)
    return versions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--icon-url", default="")
    args = ap.parse_args()

    icon = args.icon_url or f"https://raw.githubusercontent.com/{args.repo}/quill/.github/quill-icon.png"
    versions = build_versions(gh_releases(args.repo))

    app = {
        "name": "Quill",
        "bundleIdentifier": BUNDLE_ID,
        "developerName": "SP",
        "subtitle": "On-device iOS signer and installer",
        "localizedDescription": "Quill signs and installs iOS apps on your device.",
        "iconURL": icon,
        "tintColor": "1E3A5F",
        "versions": versions,
    }
    if versions:
        latest = versions[0]
        app["version"] = latest["version"]
        app["versionDate"] = latest["date"]
        app["downloadURL"] = latest["downloadURL"]
        app["size"] = latest["size"]

    source = {
        "name": "Quill",
        "identifier": "app.quill.source",
        "subtitle": "Official Quill releases",
        "description": "Official source for Quill, an on-device iOS signer and installer.",
        "iconURL": icon,
        "website": f"https://github.com/{args.repo}",
        "apps": [app],
        "news": [],
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(json.dumps(source, indent=2, ensure_ascii=False))
    print(f"versions: {len(versions)}", file=sys.stderr)


if __name__ == "__main__":
    main()
