#!/bin/bash
# Build "CCOP Dev.app" (the local, ad-hoc signed build) and install it on
# this Mac. A release (CCOP.app) in the same folder stays; an older local
# build named CCOP.app (ad-hoc signed) is removed.
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

# shellcheck source=release-lib.sh
. "$ROOT/scripts/release-lib.sh"

"$ROOT/scripts/build-app.sh"
mkdir -p "$dest_dir"
dest="$dest_dir/$CC_DEV_NAME.app"
osascript -e "tell application id \"$CC_DEV_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
old="$dest_dir/CCOP.app"
if [[ -d "$old" ]] && codesign -dv "$old" 2>&1 | grep '^Signature=adhoc' >/dev/null; then
    osascript -e "tell application id \"$CC_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    rm -rf "$old"
    printf '==> Removed the old local build %s\n' "$old"
fi
rm -rf "$dest"
ditto "$ROOT/build/$CC_DEV_NAME.app" "$dest"
printf '==> Installed %s\n' "$dest"
if [[ $launch == 1 ]]; then
    open "$dest"
fi
