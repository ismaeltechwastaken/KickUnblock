#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import zipfile
import release_dependencies as dependencies


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def files(root):
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not (path.is_dir() or path.is_file()):
            raise ValueError("Symlink or special file in package input")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = path
    return result


def verify_retained_sdk(vendor, embedded):
    original = {name: path for name, path in files(vendor).items()
                if name.split("/")[0] not in {"Headers", "PrivateHeaders", "Modules"}}
    retained = files(embedded)
    if "PrivacyInfo.xcprivacy" not in original or set(original) != set(retained):
        raise ValueError("SDK retained inventory/privacy mismatch")
    if any(sha(path) != sha(retained[name]) for name, path in original.items()):
        raise ValueError("SDK retained file hash mismatch")
    return {name: sha(path) for name, path in retained.items()}


def write_zip(payload, output):
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, path in files(payload).items():
            entry = zipfile.ZipInfo("Payload/" + name, (1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | (0o755 if path.stat().st_mode & 0o111 else 0o644)) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, path.read_bytes(), compresslevel=9)


def verify_zip(archive_path, payload):
    expected = {"Payload/" + name: path for name, path in files(payload).items()}
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or set(names) != set(expected) or archive.testzip() is not None:
            raise ValueError("ZIP content inventory or CRC mismatch")
        for name, path in expected.items():
            entry = archive.getinfo(name)
            expected_mode = stat.S_IFREG | (0o755 if path.stat().st_mode & 0o111 else 0o644)
            if entry.create_system != 3 or entry.external_attr >> 16 != expected_mode:
                raise ValueError("ZIP file type or executable mode mismatch")
            if hashlib.sha256(archive.read(name)).hexdigest() != sha(path):
                raise ValueError("ZIP content hash mismatch")


def text_hash(path):
    result = subprocess.run(["xcrun", "otool", "-s", "__TEXT", "__text", str(path)],
                            check=True, capture_output=True, text=True)
    lines = result.stdout.splitlines()
    if len(lines) < 3 or "(__TEXT,__text)" not in lines[1]:
        raise ValueError("Missing executable code section")
    return hashlib.sha256("\n".join(lines[2:]).encode()).hexdigest()


def require_unsigned(path):
    result = subprocess.run(["codesign", "-dv", str(path)], capture_output=True, text=True)
    if result.returncode == 0 or "code object is not signed at all" not in result.stderr:
        raise ValueError("Expected genuinely unsigned Mach-O")


def snapshot(root):
    return {name: sha(path) for name, path in files(root).items()}


def verify_sdk_archive(sdk, archive, parent):
    dependencies.verify_archive(archive, dependencies.SDK_SHA256)
    with tempfile.TemporaryDirectory(prefix="sdk-provenance-", dir=parent) as tmp:
        extracted = Path(tmp) / "contents"
        dependencies.safe_extract(archive, extracted, "AmazonIVSPlayer.xcframework")
        if snapshot(sdk) != snapshot(extracted / "AmazonIVSPlayer.xcframework"):
            raise ValueError("SDK does not match pinned archive")


def package(app, sdk, output, build, sdk_archive=None):
    app, sdk, output = Path(app).resolve(), Path(sdk).resolve(), Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("Output already exists; refusing replacement")
    for source in (app, sdk):
        if source == output or source in output.resolve().parents:
            raise ValueError("Output cannot be inside an input")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if (info.get("DTPlatformName") != "iphoneos" or info.get("CFBundleIdentifier") != "dev.ismaeltech.kickunblock"
            or info.get("MinimumOSVersion") != "17.0" or info.get("CFBundleVersion") != build
            or info.get("CFBundleExecutable") != "KickUnblock"):
        raise ValueError("Expected device app identity, build and minimum iOS 17.0")
    if sdk_archive is None:
        raise ValueError("Pinned SDK archive is required")
    verify_sdk_archive(sdk, Path(sdk_archive), output.parent)
    original_files, sdk_files = files(app), files(sdk)
    main_executable = app / "KickUnblock"
    if (not main_executable.is_file() or main_executable.is_symlink()
            or not (main_executable.stat().st_mode & 0o100)):
        raise ValueError("Main executable permission is missing or invalid")
    if any(name.endswith((".mobileprovision", ".p12", ".p8", ".pem", ".key")) for name in original_files):
        raise ValueError("Signing/credential file in app; refusing unsigned packaging")
    framework = app / "Frameworks/AmazonIVSPlayer.framework"
    if {p.name for p in (app / "Frameworks").iterdir()} != {"AmazonIVSPlayer.framework"}:
        raise ValueError("Unexpected embedded framework")
    vendor = sdk / "ios-arm64/AmazonIVSPlayer.framework"
    version = plistlib.loads((vendor / "Info.plist").read_bytes()).get("IVSBundleSemanticVersionString")
    if version != "1.54.1":
        raise ValueError("Unexpected SDK version")
    dependencies.verify_signature(sdk)
    retained = verify_retained_sdk(vendor, framework)
    binaries = ["KickUnblock", "Frameworks/AmazonIVSPlayer.framework/AmazonIVSPlayer"]
    macho_magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                   b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    found = set()
    for name, path in original_files.items():
        with path.open("rb") as stream:
            if stream.read(4) in macho_magic:
                found.add(name)
    if found != set(binaries):
        raise ValueError("Unexpected Mach-O inventory")
    before_app, before_sdk = snapshot(app), snapshot(sdk)
    code = {name: text_hash(app / name) for name in binaries}
    with tempfile.TemporaryDirectory(prefix="release-stage-", dir=output.parent) as tmp:
        work = Path(tmp)
        staged = work / "Payload" / app.name
        shutil.copytree(app, staged)
        for name in binaries:
            target = staged / name
            display = subprocess.run(["codesign", "-dv", str(target)], capture_output=True, text=True)
            if display.returncode == 0:
                subprocess.run(["codesign", "--remove-signature", str(target)], check=True, capture_output=True)
            else:
                require_unsigned(target)
        for signature in list(staged.rglob("_CodeSignature")):
            shutil.rmtree(signature)
        staged_files = files(staged)
        expected = {name for name in before_app if "_CodeSignature" not in Path(name).parts}
        if set(staged_files) != expected:
            raise ValueError("Staged file inventory changed")
        for name, path in staged_files.items():
            if name not in binaries and sha(path) != before_app[name]:
                raise ValueError("Non-code file changed in staging")
        for name in binaries:
            if text_hash(staged / name) != code[name]:
                raise ValueError("Executable code bytes changed during signature removal")
            require_unsigned(staged / name)
        if snapshot(app) != before_app or snapshot(sdk) != before_sdk:
            raise ValueError("Input app or SDK changed during packaging")
        ipa = work / "KickUnblock-unsigned.ipa"
        write_zip(work / "Payload", ipa)
        verify_zip(ipa, work / "Payload")
        report = {"verified": True, "bundle_id": info["CFBundleIdentifier"], "build": build,
                  "minimum_os": info["MinimumOSVersion"], "platform": info["DTPlatformName"],
                  "sdk_version": version, "sdk_team": "94KV3E626L", "sdk_retained_files": retained,
                  "sdk_archive_sha256": dependencies.SDK_SHA256, "sdk_archive_url": dependencies.SDK_URL,
                  "sdk_privacy_sha256": retained["PrivacyInfo.xcprivacy"],
                  "code_text_sha256": code, "source_inputs_unchanged": True,
                  "staged_files_sha256": snapshot(staged), "ipa_sha256": sha(ipa), "ipa_bytes": ipa.stat().st_size,
                  "limits": ["Unsigned; manual signing/install required.",
                             "Deterministic ZIP for identical staged inputs and Python/zlib; Xcode output is not promised bit-reproducible."]}
        output.mkdir()
        shutil.copyfile(ipa, output / ipa.name)
        (output / "verification.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        (output / "SHA256SUMS").write_text(report["ipa_sha256"] + "  " + ipa.name + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description="Package an unsigned IPA.")
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--sdk", required=True, type=Path)
    parser.add_argument("--sdk-archive", required=True, type=Path, help="Original hash-pinned public SDK ZIP")
    parser.add_argument("--output", required=True, type=Path, help="New output directory; parent must exist")
    parser.add_argument("--build", required=True, help="Expected CFBundleVersion")
    args = parser.parse_args()
    try:
        report = package(args.app, args.sdk, args.output, args.build, args.sdk_archive)
    except (ValueError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        parser.exit(1, "Packaging failed: " + type(error).__name__ + "; inspect inputs locally.\n")
    print(json.dumps({key: report[key] for key in ("verified", "build", "ipa_sha256", "ipa_bytes")}, sort_keys=True))


if __name__ == "__main__":
    main()
