#!/bin/bash
# Build CCOP.app: the Rust CLI, the Swift menu bar app, Info.plist, icon.
#
#   scripts/build-app.sh [--sign <identity>] [--developer-id] [--out <dir>]
#
# Default signing is ad-hoc: it runs on this Mac; other Macs show a
# Gatekeeper warning, and the app does not update itself. Such a build is
# "build/CCOP Dev.app" (id dev.ccop.app.dev, a grey icon with DEV), so it is
# never taken for a release. --developer-id or --sign build build/CCOP.app.
# --developer-id
# picks the "Developer ID Application" identity from the keychain and signs
# with the hardened runtime, as notarization requires.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=release-lib.sh
. "$ROOT/scripts/release-lib.sh"

identity="-"
out="$ROOT/build"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) identity="$2"; shift 2 ;;
        --developer-id)
            cc_load_signing_env "$ROOT"
            identity="$(cc_developer_id "${APPLE_TEAM_ID:-}")"
            [[ -n "$identity" ]] || cc_die "no Developer ID Application identity in the keychain"
            shift ;;
        --out) out="$2"; shift 2 ;;
        *) cc_die "unknown option $1" ;;
    esac
done

# The version is in one place: [workspace.package] in Cargo.toml.
version="$(cc_version "$ROOT/Cargo.toml")"
[[ -n "$version" ]] || cc_die "cannot read the version from Cargo.toml"
if [[ "$identity" == "-" ]]; then
    name="$CC_DEV_NAME"; bundle_id="$CC_DEV_BUNDLE_ID"; icon_kind="dev"
else
    name="CCOP"; bundle_id="$CC_BUNDLE_ID"; icon_kind="release"
fi
APP="$out/$name.app"

cc_say "Building the Rust CLI $version"
(cd "$ROOT" && cargo build --release --quiet -p ccop)

cc_say "Building the Swift app"
swift build -c release --package-path "$ROOT/apps/menubar" --product CCOP >/dev/null
swift_bin="$(swift build -c release --package-path "$ROOT/apps/menubar" --show-bin-path)/CCOP"

cc_say "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$swift_bin" "$APP/Contents/MacOS/CCOP"
# The CLI goes to Helpers: "ccop" and "CCOP" are the same name on a
# case-insensitive file system, so it cannot sit next to the app in MacOS.
cp "$ROOT/target/release/ccop" "$APP/Contents/Helpers/ccop"
for program in MacOS/CCOP Helpers/ccop; do
    [[ -x "$APP/Contents/$program" ]] || cc_die "missing $program in the bundle"
done
cmp -s "$swift_bin" "$APP/Contents/MacOS/CCOP" || cc_die "Contents/MacOS/CCOP is not the Swift app"
sed -e "s|@VERSION@|$version|g" -e "s|@BUNDLE_ID@|$bundle_id|g" -e "s|@MIN_MACOS@|$CC_MIN_MACOS|g" -e "s|@NAME@|$name|g" \
    "$ROOT/scripts/Info.plist.in" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

icon_cache="$ROOT/build/AppIcon-$icon_kind.icns"
if [[ ! -f "$icon_cache" || "$ROOT/scripts/make-icon.swift" -nt "$icon_cache" ]]; then
    cc_say "Drawing the icon"
    tmp="$(mktemp -d)"
    swift "$ROOT/scripts/make-icon.swift" "$tmp/icon.png" "$icon_kind"
    mkdir "$tmp/AppIcon.iconset"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    mkdir -p "$ROOT/build"
    iconutil -c icns "$tmp/AppIcon.iconset" -o "$icon_cache"
    rm -rf "$tmp"
fi
cp "$icon_cache" "$APP/Contents/Resources/AppIcon.icns"

# The help page the menu's Help opens in the browser. Through a temp file, so a
# failed run leaves no half-written page in the bundle.
help_page="$(mktemp)"
"$APP/Contents/Helpers/ccop" help-page > "$help_page"
grep -q "<title>ccop help</title>" "$help_page" || cc_die "the help page has no title"
mv "$help_page" "$APP/Contents/Resources/help.html"
chmod 644 "$APP/Contents/Resources/help.html"

cc_say "Signing ($([[ "$identity" == "-" ]] && echo ad-hoc || echo "Developer ID"))"
if [[ "$identity" == "-" ]]; then
    flags=(--force --sign - --timestamp=none)
else
    flags=(--force --options runtime --timestamp --sign "$identity")
fi
# Nested programs first, then the bundle.
codesign "${flags[@]}" --identifier "$bundle_id.cli" "$APP/Contents/Helpers/ccop"
codesign "${flags[@]}" "$APP"
codesign --verify --deep --strict "$APP"
cc_say "Built $APP ($version)"
