#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodebuild >/dev/null || { printf '%s\n' 'Full Xcode is required.' >&2; exit 1; }
BUILD_ROOT="${BUILD_ROOT:-build/unsigned}"
[ ! -e "$BUILD_ROOT" ] && [ ! -L "$BUILD_ROOT" ] || { printf '%s\n' 'Build directory exists; choose a fresh BUILD_ROOT.' >&2; exit 1; }
mkdir -p "$BUILD_ROOT"
python3 Scripts/release_dependencies.py
.tools/xcodegen/bin/xcodegen generate
EXPECTED_BUILD="$(python3 -c 'import pathlib,re; values=re.findall(r"^\s*CURRENT_PROJECT_VERSION: \"([0-9]+)\"\s*$",pathlib.Path("project.yml").read_text(),re.M); assert len(values)==1,"Expected one explicit project build number"; print(values[0])')"
xcodebuild -version > "$BUILD_ROOT/toolchain.txt"
.tools/xcodegen/bin/xcodegen --version >> "$BUILD_ROOT/toolchain.txt"
python3 --version >> "$BUILD_ROOT/toolchain.txt"
xcodebuild \
  -project KickUnblock.xcodeproj \
  -scheme KickUnblock \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_ROOT/dd" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > "$BUILD_ROOT/xcodebuild.log" 2>&1
python3 Scripts/release_package.py \
  --app "$BUILD_ROOT/dd/Build/Products/Release-iphoneos/KickUnblock.app" \
  --sdk Vendor/AmazonIVSPlayer.xcframework \
  --sdk-archive .tools/AmazonIVSPlayer-1.54.1.zip \
  --output "$BUILD_ROOT/release" --build "$EXPECTED_BUILD"
cp "$BUILD_ROOT/toolchain.txt" "$BUILD_ROOT/release/toolchain.txt"
printf 'Verified unsigned package and checksums: %s/release\n' "$BUILD_ROOT"
