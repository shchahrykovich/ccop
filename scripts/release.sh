#!/bin/bash
# Build a release DMG: bump the version, build and sign the app, make the image.
#
#   scripts/release.sh [--patch|--minor|--major|--set X.Y.Z|--no-bump] [--notarize]
#
# --notarize signs with Developer ID and runs scripts/notarize.sh on the image.
# Without it the app is ad-hoc signed: fine for this Mac, not for other Macs.
# Output: dist/ccop-<version>.dmg
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=release-lib.sh
. "$ROOT/scripts/release-lib.sh"

bump="patch"
set_to=""
notarize=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --patch|--minor|--major) bump="${1#--}"; shift ;;
        --set) bump="set"; set_to="$2"; shift 2 ;;
        --no-bump) bump="none"; shift ;;
        --notarize) notarize=1; shift ;;
        *) cc_die "unknown option $1" ;;
    esac
done

old="$(cc_version "$ROOT/Cargo.toml")"
IFS=. read -r major minor patch <<<"$old"
case "$bump" in
    patch) new="$major.$minor.$((patch + 1))" ;;
    minor) new="$major.$((minor + 1)).0" ;;
    major) new="$((major + 1)).0.0" ;;
    set) [[ "$set_to" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || cc_die "--set needs X.Y.Z"; new="$set_to" ;;
    none) new="$old" ;;
esac

restore_version() { [[ "$new" != "$old" ]] && cc_set_version "$ROOT/Cargo.toml" "$old" && (cd "$ROOT" && cargo metadata --format-version 1 >/dev/null 2>&1); }
if [[ "$new" != "$old" ]]; then
    cc_say "Version $old -> $new"
    cc_set_version "$ROOT/Cargo.toml" "$new"
    trap 'restore_version; cc_die "release failed; version restored to $old"' ERR
fi

sign_args=()
[[ $notarize == 1 ]] && sign_args=(--developer-id)
"$ROOT/scripts/build-app.sh" ${sign_args[@]+"${sign_args[@]}"}

mkdir -p "$ROOT/dist"
DMG="$ROOT/dist/ccop-$new.dmg"
cc_say "Making $DMG"
staging="$(mktemp -d)"
app_name="CCOP"
[[ $notarize == 1 ]] || app_name="$CC_DEV_NAME"
ditto "$ROOT/build/$app_name.app" "$staging/$app_name.app"
ln -s /Applications "$staging/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "ccop $new" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$staging"

if [[ $notarize == 1 ]]; then
    "$ROOT/scripts/notarize.sh" "$DMG"
fi
trap - ERR
cc_say "Done: $DMG"
[[ "$new" != "$old" ]] && echo "Commit the version: git commit -am \"Release $new\""
exit 0
