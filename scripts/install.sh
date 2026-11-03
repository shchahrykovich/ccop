#!/bin/bash
# Build CCOP.app and install it on this Mac.
#
#   scripts/install.sh [--user] [--launch]
#
# --user installs to ~/Applications instead of /Applications.
# --launch opens the app after installing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

dest_dir="/Applications"
launch=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) dest_dir="$HOME/Applications"; shift ;;
        --launch) launch=1; shift ;;
        *) printf 'error: unknown option %s\n' "$1" >&2; exit 1 ;;
    esac
done

"$ROOT/scripts/build-app.sh"
mkdir -p "$dest_dir"
dest="$dest_dir/CCOP.app"
osascript -e 'tell application id "dev.ccop.app" to quit' >/dev/null 2>&1 || true
rm -rf "$dest"
ditto "$ROOT/build/CCOP.app" "$dest"
printf '==> Installed %s\n' "$dest"
if [[ $launch == 1 ]]; then
    open "$dest"
fi
