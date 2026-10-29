#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh --universal
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
archive="Agent-Pace-$version-universal.zip"
staging="$(mktemp -d "${TMPDIR:-/tmp/}AgentPace.release.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Agent Pace.app"
ditto --norsrc --noextattr "dist/Agent Pace.app" "$app"
xattr -cr "$app"
codesign --verify --deep --strict "$app"
for architecture in arm64 x86_64; do
    lipo "$app/Contents/MacOS/AgentPace" -verify_arch "$architecture"
done
ditto -c -k --keepParent --norsrc --noextattr "$app" "$staging/$archive"
cp "$staging/$archive" "dist/$archive"
(
    cd dist
    shasum -a 256 "$archive" > "$archive.sha256"
)
printf '发布包：%s\n' "$PWD/dist/$archive"
