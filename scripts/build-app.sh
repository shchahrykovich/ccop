#!/bin/bash
# Build CCOP.app: the Rust CLI, the Swift menu bar app, Info.plist, icon.
#
#   scripts/build-app.sh [--sign <identity>] [--out <dir>]
#
# Default signing is ad-hoc: it runs on this Mac; other Macs show a
# Gatekeeper warning.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIN_MACOS="14.0"
BUNDLE_ID="dev.ccop.app"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

identity="-"
out="$ROOT/build"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) identity="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        *) die "unknown option $1" ;;
    esac
done

# The version is in one place: [workspace.package] in Cargo.toml.
version="$(sed -n '/^\[workspace.package\]/,/^\[/s/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml")"
[[ -n "$version" ]] || die "cannot read the version from Cargo.toml"
APP="$out/CCOP.app"

say "Building the Rust CLI $version"
(cd "$ROOT" && cargo build --release --quiet -p ccop)

say "Building the Swift app"
swift build -c release --package-path "$ROOT/apps/menubar" --product CCOP >/dev/null
swift_bin="$(swift build -c release --package-path "$ROOT/apps/menubar" --show-bin-path)/CCOP"

say "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$swift_bin" "$APP/Contents/MacOS/CCOP"
# The CLI goes to Helpers: "ccop" and "CCOP" are the same name on a
# case-insensitive file system, so it cannot sit next to the app in MacOS.
cp "$ROOT/target/release/ccop" "$APP/Contents/Helpers/ccop"
for program in MacOS/CCOP Helpers/ccop; do
    [[ -x "$APP/Contents/$program" ]] || die "missing $program in the bundle"
done
cmp -s "$swift_bin" "$APP/Contents/MacOS/CCOP" || die "Contents/MacOS/CCOP is not the Swift app"
sed -e "s|@VERSION@|$version|g" -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" -e "s|@MIN_MACOS@|$MIN_MACOS|g" \
    "$ROOT/scripts/Info.plist.in" > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"

icon_cache="$ROOT/build/AppIcon.icns"
if [[ ! -f "$icon_cache" || "$ROOT/scripts/make-icon.swift" -nt "$icon_cache" ]]; then
    say "Drawing the icon"
    tmp="$(mktemp -d)"
    swift "$ROOT/scripts/make-icon.swift" "$tmp/icon.png"
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

say "Signing ($([[ "$identity" == "-" ]] && echo ad-hoc || echo "$identity"))"
if [[ "$identity" == "-" ]]; then
    flags=(--force --sign - --timestamp=none)
else
    flags=(--force --options runtime --timestamp --sign "$identity")
fi
# Nested programs first, then the bundle.
codesign "${flags[@]}" --identifier "$BUNDLE_ID.cli" "$APP/Contents/Helpers/ccop"
codesign "${flags[@]}" "$APP"
codesign --verify --deep --strict "$APP"
say "Built $APP ($version)"
