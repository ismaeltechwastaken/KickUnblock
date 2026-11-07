#!/usr/bin/env python3
import argparse
import datetime as dt
import hashlib
import json
import plistlib
import re
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSET_NAME = "KickUnblock.ipa"


def project_version(project_yml=ROOT / "project.yml"):
    text = Path(project_yml).read_text()
    version = re.findall(r'^\s*MARKETING_VERSION: "([^"]+)"\s*$', text, re.M)
    build = re.findall(r'^\s*CURRENT_PROJECT_VERSION: "([0-9]+)"\s*$', text, re.M)
    bundle = re.findall(r'^\s*PRODUCT_BUNDLE_IDENTIFIER: (\S+)\s*$', text, re.M)
    if len(version) != 1 or len(build) != 1 or len(bundle) != 1:
        sys.exit("project.yml must declare exactly one MARKETING_VERSION, CURRENT_PROJECT_VERSION and PRODUCT_BUNDLE_IDENTIFIER")
    return version[0], build[0], bundle[0]


def tag_for(version, build):
    return f"v{version}-build{build}"


def changelog_notes(version, build, changelog=ROOT / "CHANGELOG.md"):
    text = Path(changelog).read_text()
    heading = f"## {version} ({build})"
    match = re.search(rf"^{re.escape(heading)}\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not match or not match.group(1).strip():
        sys.exit(f"CHANGELOG.md has no '{heading}' section")
    return re.sub(r"\n[ \t]+(?=\S)", " ", match.group(1).strip())


def ipa_info(ipa):
    with zipfile.ZipFile(ipa) as z:
        names = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(names) != 1:
            sys.exit(f"{ipa}: expected one Payload/*.app/Info.plist")
        return plistlib.loads(z.read(names[0]))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def prepare(ipa, out, now=None, project_yml=ROOT / "project.yml", changelog=ROOT / "CHANGELOG.md"):
    version, build, bundle = project_version(project_yml)
    info = ipa_info(ipa)
    found = (info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"), str(info.get("CFBundleVersion")))
    if found != (bundle, version, build):
        sys.exit(f"IPA is {found}, project.yml says {(bundle, version, build)}")
    notes = changelog_notes(version, build, changelog)
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    target = out / ASSET_NAME
    shutil.copyfile(ipa, target)
    digest = sha256(target)
    released = (now or dt.datetime.now(dt.timezone.utc)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    meta = {
        "schema": 1,
        "name": "KickUnblock",
        "bundleIdentifier": bundle,
        "version": version,
        "buildVersion": build,
        "tag": tag_for(version, build),
        "date": released,
        "minOSVersion": info.get("MinimumOSVersion"),
        "asset": ASSET_NAME,
        "size": target.stat().st_size,
        "sha256": digest,
        "localizedDescription": notes,
        "privacy": {k: v for k, v in sorted(info.items()) if k.endswith("UsageDescription")},
    }
    (out / "release.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
    (out / "SHA256SUMS").write_text(f"{digest}  {ASSET_NAME}\n")
    (out / "notes.md").write_text(notes + f"\n\nSHA-256 `{digest}`. Unsigned: sign it with your own certificate or Apple ID.\n")
    return meta


def main():
    p = argparse.ArgumentParser(description="Prepare GitHub Release files for a verified unsigned IPA.")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("version")
    sub.add_parser("tag")
    pr = sub.add_parser("prepare")
    pr.add_argument("--ipa", required=True)
    pr.add_argument("--out", required=True)
    args = p.parse_args()
    if args.cmd == "version":
        version, build, _ = project_version()
        print(version, build)
    elif args.cmd == "tag":
        print(tag_for(*project_version()[:2]))
    else:
        meta = prepare(args.ipa, args.out)
        print(json.dumps({k: meta[k] for k in ("tag", "version", "buildVersion", "size", "sha256")}))


if __name__ == "__main__":
    main()
