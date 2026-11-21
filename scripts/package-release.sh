#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--no-build" ) ]]; then
    printf 'Usage: %s [--no-build]\n' "$0" >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'Release packaging requires macOS.\n' >&2
    exit 1
fi
if [[ $# -eq 0 ]]; then bash scripts/build-app.sh --universal; fi

marketbar_dist="$PWD/dist"
marketbar_app="$marketbar_dist/MarketBar.app"
marketbar_plist="$marketbar_app/Contents/Info.plist"
marketbar_binary="$marketbar_app/Contents/MacOS/MarketBar"
if [[ ! -f "$marketbar_plist" || ! -x "$marketbar_binary" ]]; then
    printf 'No built app found. Run bash scripts/build-app.sh --universal first.\n' >&2
    exit 1
fi
plutil -lint "$marketbar_plist" >/dev/null
codesign --verify --deep --strict "$marketbar_app"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$marketbar_plist")" != local.leoping.MarketBar ||
      "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$marketbar_plist")" != MarketBar ]]; then
    printf 'Unexpected application bundle identity.\n' >&2
    exit 1
fi
marketbar_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$marketbar_plist")"
marketbar_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$marketbar_plist")"
if [[ ! "$marketbar_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ||
      ! "$marketbar_build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    printf 'Invalid bundle version or build number.\n' >&2
    exit 1
fi
marketbar_arch="$(lipo -archs "$marketbar_binary")"
case "$marketbar_arch" in
    arm64|x86_64) ;;
    'x86_64 arm64'|'arm64 x86_64') marketbar_arch=universal ;;
    *) printf 'Unsupported binary architecture: %s\n' "$marketbar_arch" >&2; exit 1 ;;
esac
marketbar_stem="MarketBar-$marketbar_version-macos-$marketbar_arch"
marketbar_zip="$marketbar_stem.zip"
# Only a verified two-architecture app gets the stable DMG download name.
if [[ "$marketbar_arch" == universal ]]; then
    marketbar_dmg=MarketBar.dmg
else
    marketbar_dmg="$marketbar_stem.dmg"
fi

marketbar_stage="$(mktemp -d "$marketbar_dist/.MarketBar-release.XXXXXX")"
trap 'rm -rf "$marketbar_stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$marketbar_stage/image-root" "$marketbar_stage/artifacts"
ditto --norsrc --noextattr "$marketbar_app" "$marketbar_stage/image-root/MarketBar.app"
codesign --verify --deep --strict "$marketbar_stage/image-root/MarketBar.app"
cmp -s "$marketbar_binary" "$marketbar_stage/image-root/MarketBar.app/Contents/MacOS/MarketBar"
cmp -s "$marketbar_plist" "$marketbar_stage/image-root/MarketBar.app/Contents/Info.plist"
ln -s /Applications "$marketbar_stage/image-root/Applications"

ditto -c -k --keepParent --norsrc --noextattr \
    "$marketbar_stage/image-root/MarketBar.app" "$marketbar_stage/artifacts/$marketbar_zip"
hdiutil create -quiet -volname MarketBar -srcfolder "$marketbar_stage/image-root" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$marketbar_stage/artifacts/$marketbar_dmg"
hdiutil verify -quiet "$marketbar_stage/artifacts/$marketbar_dmg"
hdiutil imageinfo -plist "$marketbar_stage/artifacts/$marketbar_dmg" > "$marketbar_stage/image-info.plist"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :Format' "$marketbar_stage/image-info.plist")" != UDZO ]]; then
    printf 'Disk image is not compressed read-only UDZO.\n' >&2
    exit 1
fi
(
    cd "$marketbar_stage/artifacts"
    shasum -a 256 "$marketbar_zip" > "$marketbar_zip.sha256"
    shasum -a 256 "$marketbar_dmg" > "$marketbar_dmg.sha256"
    shasum -a 256 -c "$marketbar_zip.sha256" "$marketbar_dmg.sha256"
)
# Do not replace existing artifacts until both packages and checksums are ready.
for marketbar_name in "$marketbar_zip" "$marketbar_zip.sha256" "$marketbar_dmg" "$marketbar_dmg.sha256"; do
    if [[ -d "$marketbar_dist/$marketbar_name" ]]; then
        printf 'Release destination is a directory: %s\n' "$marketbar_dist/$marketbar_name" >&2
        exit 1
    fi
done
for marketbar_name in "$marketbar_zip" "$marketbar_zip.sha256" "$marketbar_dmg" "$marketbar_dmg.sha256"; do
    mv -f "$marketbar_stage/artifacts/$marketbar_name" "$marketbar_dist/$marketbar_name"
done
printf 'Packaged MarketBar %s (build %s, %s):\n' "$marketbar_version" "$marketbar_build" "$marketbar_arch"
printf '  %s/%s\n' "$marketbar_dist" "$marketbar_zip" "$marketbar_dist" "$marketbar_dmg"
cat "$marketbar_dist/$marketbar_zip.sha256" "$marketbar_dist/$marketbar_dmg.sha256"
