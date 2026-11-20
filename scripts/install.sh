#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--no-build" ) ]]; then
    printf 'Usage: %s [--no-build]\n' "$0" >&2
    exit 2
fi
if [[ $# -eq 0 ]]; then bash scripts/build-app.sh; fi

marketbar_source="$PWD/dist/MarketBar.app"
marketbar_destination="$HOME/Applications/MarketBar.app"
marketbar_binary="$marketbar_destination/Contents/MacOS/MarketBar"
if [[ ! -x "$marketbar_source/Contents/MacOS/MarketBar" ]]; then
    printf 'No built app found. Run bash scripts/build-app.sh first.\n' >&2
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$marketbar_source/Contents/Info.plist")" != "local.leoping.MarketBar" ]]; then
    printf 'Unexpected application bundle identifier.\n' >&2
    exit 1
fi
codesign --verify --deep --strict "$marketbar_source"
mkdir -p "$HOME/Applications"
marketbar_stage="$(mktemp -d "$HOME/Applications/.MarketBar-install.XXXXXX")"
marketbar_backup=""
marketbar_installed=0
cleanup_install() {
    marketbar_status=$?
    if [[ "$marketbar_status" -ne 0 && "$marketbar_installed" -eq 1 && -d "$marketbar_destination" ]]; then
        mv "$marketbar_destination" "$marketbar_stage/failed.app" || true
    fi
    if [[ "$marketbar_status" -ne 0 && -n "$marketbar_backup" && -d "$marketbar_backup" && ! -e "$marketbar_destination" ]]; then
        if mv "$marketbar_backup" "$marketbar_destination"; then
            printf 'Installation failed; restored the previous app.\n' >&2
            open "$marketbar_destination" >/dev/null 2>&1 || true
        else
            printf 'Previous app remains available at: %s\n' "$marketbar_backup" >&2
        fi
    fi
    rm -rf "$marketbar_stage"
    exit "$marketbar_status"
}
trap cleanup_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Stage and validate before interrupting the running app. No user data is moved.
ditto "$marketbar_source" "$marketbar_stage/MarketBar.app"
codesign --verify --deep --strict "$marketbar_stage/MarketBar.app"

target_is_running() {
    [[ "$(ps -ww -p "$1" -o comm= 2>/dev/null || true)" == "$marketbar_binary" ]]
}
marketbar_pids=()
while read -r marketbar_pid marketbar_command; do
    if [[ "$marketbar_command" == "$marketbar_binary" ]] && target_is_running "$marketbar_pid"; then
        marketbar_pids+=("$marketbar_pid")
        kill -TERM "$marketbar_pid" 2>/dev/null || true
    fi
done < <(ps -axww -o pid=,comm=)
# The app handles SIGTERM by flushing its archive and completing normal quit.
marketbar_deadline=$((SECONDS + 10))
for marketbar_pid in ${marketbar_pids[@]+"${marketbar_pids[@]}"}; do
    while target_is_running "$marketbar_pid"; do
        if [[ "$SECONDS" -ge "$marketbar_deadline" ]]; then
            printf 'MarketBar has not exited. Use its Quit button, then retry; the installed app is unchanged.\n' >&2
            exit 1
        fi
        sleep 0.1
    done
done

if [[ -e "$marketbar_destination" ]]; then
    marketbar_backup="$HOME/Applications/MarketBar.backup.$(date +%Y%m%d-%H%M%S).$$.app"
    mv "$marketbar_destination" "$marketbar_backup"
fi
mv "$marketbar_stage/MarketBar.app" "$marketbar_destination"
marketbar_installed=1
open "$marketbar_destination"
printf 'Installed: %s\n' "$marketbar_destination"
if [[ -n "$marketbar_backup" ]]; then printf 'Previous app: %s\n' "$marketbar_backup"; fi
