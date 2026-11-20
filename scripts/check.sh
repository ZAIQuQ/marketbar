#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 0 ]]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'The application checks require macOS 13 or later.\n' >&2
    exit 1
fi

# Build both executables once. All three suites use fixed data or temporary
# files; none calls a live market-data endpoint or touches the user's archive.
swift build
marketbar_bin_dir="$(swift build --show-bin-path)"
"$marketbar_bin_dir/TickerCoreTests"
"$marketbar_bin_dir/MarketBar" --self-test
"$marketbar_bin_dir/MarketBar" --archive-test
printf 'All offline checks passed.\n'
