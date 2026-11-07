#!/usr/bin/env python3
import hashlib
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tempfile
import urllib.request
import zipfile

XCODEGEN_VERSION = '2.46.0'
XCODEGEN_SHA256 = '4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806'
XCODEGEN_URL = f'https://github.com/yonaskolb/XcodeGen/releases/download/{XCODEGEN_VERSION}/xcodegen.zip'
SDK_VERSION = '1.54.1'
SDK_SHA256 = '6572968f41e31b4a52e5d970be39e366924eaf586ee8a89cf9709b86fc93510d'
SDK_URL = f'https://player.live-video.net/{SDK_VERSION}/AmazonIVSPlayer.xcframework.zip'
SDK_AUTHORITY = 'Authority=iPhone Distribution: AMZN Mobile LLC (94KV3E626L)'
SDK_REQUIREMENT = '-R=anchor apple generic and certificate leaf[subject.OU] = "94KV3E626L"'


def verify_archive(path, expected):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ValueError('Dependency archive hash mismatch')


def safe_extract(archive, destination, root):
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise ValueError('Extraction destination exists')
    with zipfile.ZipFile(archive) as z:
        names = set()
        for entry in z.infolist():
            path = PurePosixPath(entry.filename)
            mode = entry.external_attr >> 16
            if (not path.parts or path.parts[0] != root or path.is_absolute()
                    or '..' in path.parts or '\\' in entry.filename
                    or entry.filename in names or entry.flag_bits & 1
                    or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
                raise ValueError('Unsafe archive inventory')
            names.add(entry.filename)
        if not names or z.testzip() is not None:
            raise ValueError('Invalid archive CRC/inventory')
        destination.mkdir()
        for entry in z.infolist():
            target = destination / entry.filename
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with z.open(entry) as source, target.open('xb') as sink:
                    shutil.copyfileobj(source, sink)
                target.chmod(0o755 if entry.external_attr >> 16 & 0o111 else 0o644)


def verify_signature(sdk):
    subprocess.run(['codesign', '--verify', '--strict', SDK_REQUIREMENT, str(sdk)],
                   check=True, capture_output=True)
    result = subprocess.run(['codesign', '-dvv', str(sdk)], check=True, capture_output=True, text=True)
    if SDK_AUTHORITY not in result.stderr:
        raise ValueError('Unexpected SDK signing authority')


def fetch(url, expected, destination):
    destination = Path(destination)
    if destination.is_symlink():
        raise ValueError('Symlink dependency archive')
    if not destination.exists():
        with tempfile.TemporaryDirectory(prefix='dependency-', dir=destination.parent) as tmp:
            candidate = Path(tmp) / 'download.zip'
            with urllib.request.urlopen(url, timeout=120) as source, candidate.open('xb') as sink:
                shutil.copyfileobj(source, sink)
            verify_archive(candidate, expected)
            with candidate.open('rb') as source, destination.open('xb') as sink:
                shutil.copyfileobj(source, sink)
    verify_archive(destination, expected)


def main():
    root = Path(__file__).resolve().parents[1]
    tools = root / '.tools'
    tools.mkdir(exist_ok=True)
    for name, url, digest, bundle, target in [
        ('xcodegen-2.46.0.zip', XCODEGEN_URL, XCODEGEN_SHA256, 'xcodegen', tools / 'xcodegen'),
        ('AmazonIVSPlayer-1.54.1.zip', SDK_URL, SDK_SHA256, 'AmazonIVSPlayer.xcframework', root / 'Vendor/AmazonIVSPlayer.xcframework'),
    ]:
        archive = tools / name
        fetch(url, digest, archive)
        with tempfile.TemporaryDirectory(prefix='extract-', dir=tools) as tmp:
            extracted = Path(tmp) / 'contents'
            safe_extract(archive, extracted, bundle)
            candidate = extracted / bundle
            if bundle.endswith('.xcframework'):
                verify_signature(candidate)
            if target.exists() or target.is_symlink():
                from release_package import snapshot
                if target.is_symlink() or snapshot(target) != snapshot(candidate):
                    raise ValueError('Extracted dependency differs from pinned archive; remove cache deliberately')
            else:
                target.parent.mkdir(exist_ok=True)
                shutil.move(str(candidate), str(target))
    presets = tools / 'xcodegen/share/xcodegen/SettingPresets'
    if not (presets / 'base.yml').is_file() or not (presets / 'Platforms/iOS.yml').is_file():
        raise ValueError('Incomplete XcodeGen installation')
    subprocess.run([str(tools / 'xcodegen/bin/xcodegen'), '--version'], check=True)
    print('Verified XcodeGen 2.46.0 and public Amazon IVS 1.54.1 archives and extracted bytes.')


if __name__ == '__main__':
    main()
