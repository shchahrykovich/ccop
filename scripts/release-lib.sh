# Facts the release scripts must agree about. Sourced, not run.
#
# One version source, Developer ID by keychain hash, notary credentials from
# the environment or from .env.notarize at the repository root (never exported).

CC_BUNDLE_ID="dev.ccop.app"
# A local (ad-hoc signed) build has its own name, id and icon, so it is never
# taken for a release: it does not update itself, and both can be installed.
CC_DEV_NAME="CCOP Dev"
CC_DEV_BUNDLE_ID="$CC_BUNDLE_ID.dev"
CC_GH_REPO="${CC_GH_REPO:-shchahrykovich/ccop}"
CC_MIN_MACOS="14.0"

# The version in [workspace.package] of Cargo.toml.
#   cc_version <path to Cargo.toml>
cc_version() {
    awk '
        /^\[workspace\.package\]/ { in_pkg = 1; next }
        /^\[/                     { in_pkg = 0 }
        in_pkg && /^version[[:space:]]*=/ { gsub(/[",]/, "", $3); print $3; exit }
    ' "$1"
}

# Rewrite the version in [workspace.package].
#   cc_set_version <path to Cargo.toml> <x.y.z>
cc_set_version() {
    local file="$1" new="$2" tmp
    tmp="$(mktemp)"
    awk -v new="$new" '
        /^\[workspace\.package\]/ { in_pkg = 1; print; next }
        /^\[/                     { in_pkg = 0 }
        in_pkg && /^version[[:space:]]*=/ { print "version = \"" new "\""; in_pkg = 0; next }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Read .env.notarize into this shell, only when the environment has nothing.
# The values stay shell variables: exporting them would hand an app-specific
# password to every child process of the build.
#   cc_load_signing_env <repository root>
cc_load_signing_env() {
    local file="$1/.env.notarize"
    if [[ -n "${APPLE_ID:-}${APPLE_API_KEY:-}" ]]; then
        return 0
    fi
    if [[ -f "$file" ]]; then
        # shellcheck disable=SC1090
        . "$file"
    fi
    return 0
}

# Keychain hash of a "Developer ID Application" identity, or nothing.
#   cc_developer_id [team id]
cc_developer_id() {
    local team="${1:-}" found=""
    if [[ -n "$team" ]]; then
        found="$(security find-identity -v -p codesigning 2>/dev/null | awk -v want="($team)" '
            /Developer ID Application/ && index($0, want) { print $2; exit }')"
    fi
    if [[ -z "$found" ]]; then
        found="$(security find-identity -v -p codesigning 2>/dev/null | awk '
            /Developer ID Application/ { print $2; exit }')"
    fi
    printf '%s' "$found"
}

# Arguments for `xcrun notarytool`, one per line; answers 1 when incomplete.
#   if lines="$(cc_notary_credentials)"; then ... fi
cc_notary_credentials() {
    if [[ -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
        printf '%s\n' --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER"
        return 0
    fi
    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        printf '%s\n' --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID"
        return 0
    fi
    return 1
}

cc_die() { printf 'error: %s\n' "$*" >&2; exit 1; }
cc_say() { printf '==> %s\n' "$*"; }
