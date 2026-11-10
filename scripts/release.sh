#!/bin/bash
# For licensing see accompanying LICENSE file.
# Copyright 2026 Argmax, Inc. All rights reserved.

# Builds dist/deviceloop-<version>-arm64.tar.gz, signed with Developer ID and notarized.
#
#   scripts/release.sh [<tag>]             the tag defaults to the one at HEAD
#   scripts/release.sh --verify <tarball>  checks a built or downloaded tarball
#
# Notarization uses NOTARY_PROFILE, a notarytool keychain profile, or the App Store Connect API key in
# NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID. SIGN_IDENTITY=- signs ad hoc and skips notarization.

set -euo pipefail

fail() {
    printf 'error: %s\nfix: %s\n' "$1" "$2" >&2
    exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/deviceloop-release.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Extracts the tarball and checks architecture, home paths, signatures, Gatekeeper, the stapled ticket and --version.
verify() {
    mkdir "$work/check"
    tar -xzf "$1" -C "$work/check"
    local root
    root=$(echo "$work"/check/deviceloop-*)
    local binary="$root/bin/deviceloop" app="$root/libexec/DeviceLoopCapture.app"
    [ "$(lipo -archs "$binary")" = arm64 ] || fail "bin/deviceloop is not arm64 only." "Build on an Apple silicon Mac."
    [ "$(strings -a "$binary" | grep -c /Users/)" = 0 ] ||
        fail "bin/deviceloop contains a /Users/ path." "Find it with strings -a and keep it out of release builds."
    codesign --verify --strict --verbose "$binary"
    codesign --verify --strict --verbose "$app"
    if [[ $(codesign -dv "$app" 2>&1) == *Signature=adhoc* ]]; then
        echo "ad hoc signature, skipping the Gatekeeper and stapled ticket checks"
    else
        spctl -a -t exec -vv "$app"
        xcrun stapler validate "$app"
    fi
    local expected=${root##*/deviceloop-}
    [ "$("$binary" --version)" = "$expected" ] || fail "bin/deviceloop --version does not print $expected." "Rebuild from the tagged commit."
}

if [ "${1:-}" = --verify ]; then
    verify "${2:?usage: scripts/release.sh --verify <tarball>}"
    exit 0
fi

cd "$(dirname "$0")/.."
version=$(sed -n 's/^public let version = "\(.*\)"$/\1/p' Sources/DeviceLoopKit/Core/Version.swift)
identity=${SIGN_IDENTITY:-Developer ID Application: Argmax, Inc. (PP83DTRKSA)}
tag=${1:-$(git describe --tags --exact-match 2>/dev/null)} || fail "HEAD has no tag." "Tag the release commit or pass the tag."
[ "$tag" = "v$version" ] || fail "Tag $tag does not match version $version in Version.swift." "Tag v$version or change the version."

notary=()
if [ "$identity" != - ]; then
    if [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
        notary=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    elif [ -n "${NOTARY_PROFILE:-}" ]; then
        notary=(--keychain-profile "$NOTARY_PROFILE")
    else
        fail "No notarization credentials." "Set NOTARY_PROFILE, or NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID."
    fi
fi

xcrun swift build -c release --product deviceloop
binary="$(xcrun swift build -c release --show-bin-path)/deviceloop"

root="$work/deviceloop-$version"
app="$root/libexec/DeviceLoopCapture.app"
mkdir -p "$root/bin" "$app/Contents/MacOS"
cp "$binary" "$root/bin/deviceloop"
codesign --force --options runtime --timestamp --identifier com.argmaxinc.deviceloop --sign "$identity" "$root/bin/deviceloop"
if [ "$identity" != - ] && [[ $(codesign -dv "$root/bin/deviceloop" 2>&1) == *"TeamIdentifier=not set"* ]]; then
    fail "The signature has no team ID, so its designated requirement does not hold." \
        "Remove the custom trust setting on the Developer ID certificate. security dump-trust-settings lists it."
fi
cp "$root/bin/deviceloop" "$app/Contents/MacOS/deviceloop"
cp Packaging/DeviceLoopCapture-Info.plist "$app/Contents/Info.plist"
codesign --force --options runtime --timestamp --entitlements Packaging/DeviceLoopCapture.entitlements --sign "$identity" "$app"

if [ "$identity" != - ]; then
    ditto -c -k "$root" "$work/notarize.zip"
    xcrun notarytool submit "$work/notarize.zip" "${notary[@]}" --wait --output-format json | tee "$work/notary.json" || true
    if [ "$(plutil -extract status raw -o - "$work/notary.json" 2>/dev/null)" != Accepted ]; then
        id=$(plutil -extract id raw -o - "$work/notary.json" 2>/dev/null) && xcrun notarytool log "$id" "${notary[@]}" >&2 || true
        fail "Notarization was not accepted." "Fix the problems in the notarization log and run the script again."
    fi
    xcrun stapler staple "$app"
fi

mkdir -p "$root/share/deviceloop" dist
ditto Runner "$root/share/deviceloop/Runner"
ditto skills "$root/share/deviceloop/skills"
cp LICENSE NOTICE "$root/"
tarball="dist/deviceloop-$version-arm64.tar.gz"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$tarball" -C "$work" "deviceloop-$version"
verify "$tarball"
shasum -a 256 "$tarball"
