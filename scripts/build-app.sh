#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'MarketBar requires macOS 13 or later.\n' >&2
    exit 1
fi

swift build -c release --product MarketBar
marketbar_bin_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$PWD/dist"
marketbar_stage="$(mktemp -d "$PWD/dist/.MarketBar-build.XXXXXX")"
marketbar_app="$marketbar_stage/MarketBar.app"
marketbar_destination="$PWD/dist/MarketBar.app"
marketbar_previous="$marketbar_stage/previous.app"
cleanup_build() {
    marketbar_status=$?
    if [[ "$marketbar_status" -ne 0 && -d "$marketbar_previous" ]]; then
        if [[ -e "$marketbar_destination" ]] || ! mv "$marketbar_previous" "$marketbar_destination"; then
            printf 'Previous build preserved at: %s\n' "$marketbar_previous" >&2
            exit "$marketbar_status"
        fi
    fi
    rm -rf "$marketbar_stage"
    exit "$marketbar_status"
}
trap cleanup_build EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$marketbar_app/Contents/MacOS" "$marketbar_app/Contents/Resources"
cp "$marketbar_bin_dir/MarketBar" "$marketbar_app/Contents/MacOS/MarketBar"
cat > "$marketbar_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.leoping.MarketBar</string>
<key>CFBundleName</key><string>MarketBar</string>
<key>CFBundleDisplayName</key><string>MarketBar 行情</string>
<key>CFBundleExecutable</key><string>MarketBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$marketbar_app/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon.icns' "$marketbar_app/Contents/Info.plist"
fi
if [[ -f LICENSE ]]; then
    cp LICENSE "$marketbar_app/Contents/Resources/LICENSE.txt"
fi
plutil -lint "$marketbar_app/Contents/Info.plist"
codesign --force --sign - "$marketbar_app"
codesign --verify --deep --strict "$marketbar_app"
if [[ -e "$marketbar_destination" ]]; then
    mv "$marketbar_destination" "$marketbar_previous"
fi
mv "$marketbar_app" "$marketbar_destination"
printf 'Built: %s\n' "$marketbar_destination"
