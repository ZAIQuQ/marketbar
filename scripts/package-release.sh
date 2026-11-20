#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--no-build" ) ]]; then
    printf 'Usage: %s [--no-build]\n' "$0" >&2
    exit 2
fi
if [[ $# -eq 0 ]]; then bash scripts/build-app.sh; fi
marketbar_app="$PWD/dist/MarketBar.app"
codesign --verify --deep --strict "$marketbar_app"
marketbar_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$marketbar_app/Contents/Info.plist")"
if [[ ! "$marketbar_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
    printf 'Invalid bundle version.\n' >&2
    exit 1
fi
marketbar_arch="$(lipo -archs "$marketbar_app/Contents/MacOS/MarketBar")"
case "$marketbar_arch" in
    arm64|x86_64) ;;
    'x86_64 arm64'|'arm64 x86_64') marketbar_arch=universal ;;
    *) printf 'Unsupported binary architecture: %s\n' "$marketbar_arch" >&2; exit 1 ;;
esac
marketbar_name="MarketBar-$marketbar_version-macos-$marketbar_arch.zip"
marketbar_stage="$(mktemp -d "$PWD/dist/.MarketBar-release.XXXXXX")"
trap 'rm -rf "$marketbar_stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto -c -k --keepParent --norsrc --noextattr "$marketbar_app" "$marketbar_stage/$marketbar_name"
mv "$marketbar_stage/$marketbar_name" "$PWD/dist/$marketbar_name"
cd dist
shasum -a 256 "$marketbar_name" > "$marketbar_name.sha256"
printf 'Packaged: %s/%s\n' "$PWD" "$marketbar_name"
cat "$marketbar_name.sha256"
