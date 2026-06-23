#!/bin/bash
# Bundle the `openvpn` binary and its dylib closure into a directory, rewriting
# all load paths to @loader_path so the set is relocatable inside the app bundle
# (Contents/Library/VPN). Produces a UNIVERSAL (arm64 + x86_64) set when an
# x86_64 Homebrew is available, otherwise arm64-only (with a warning).
#
# Usage: bundle-openvpn.sh <dest-dir> [signing-identity]
#
# Universal builds need an Intel Homebrew at /usr/local (e.g. installed via
# Rosetta, or present on an Intel CI runner) with `openvpn` installed. Note that
# an x86_64 openvpn built from source on a newer macOS targets that macOS, so the
# Intel slice only runs on Macs new enough for it — build the Intel slice on/for
# the oldest supported macOS (CI), not on an Apple-Silicon dev box.
set -euo pipefail

DEST="${1:?usage: bundle-openvpn.sh <dest-dir> [signing-identity]}"
SIGN_ID="${2:-}"

ARM_BREW="/opt/homebrew"
X86_BREW="/usr/local"

# Dependency closure, as paths relative to a Homebrew prefix (stable for
# openvpn 2.7 / openssl@3). Same names on both arches.
REL_LIBS=(
  "opt/lzo/lib/liblzo2.2.dylib"
  "opt/lz4/lib/liblz4.1.dylib"
  "opt/pkcs11-helper/lib/libpkcs11-helper.1.dylib"
  "opt/openssl@3/lib/libssl.3.dylib"
  "opt/openssl@3/lib/libcrypto.3.dylib"
)
REL_OPENVPN="opt/openvpn/sbin/openvpn"

# Copy openvpn + dylib closure from a Homebrew prefix into a dir and rewrite all
# /opt/homebrew or /usr/local load paths to @loader_path siblings.
stage_and_rewrite() {
  local prefix="$1" out="$2"
  mkdir -p "$out"
  cp "$prefix/$REL_OPENVPN" "$out/openvpn"
  for rel in "${REL_LIBS[@]}"; do cp "$prefix/$rel" "$out/$(basename "$rel")"; done
  chmod u+w "$out"/*
  for f in "$out"/*; do
    local base; base="$(basename "$f")"
    [[ "$base" == *.dylib ]] && install_name_tool -id "@loader_path/$base" "$f"
    local deps; deps="$(otool -L "$f" | awk 'NR>1 {print $1}' | grep -E '/opt/homebrew|/usr/local' || true)"
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f"
    done <<< "$deps"
  done
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

stage_and_rewrite "$ARM_BREW" "$TMP/arm64"
mkdir -p "$DEST"

if [[ -x "$X86_BREW/$REL_OPENVPN" ]]; then
  echo "Found Intel openvpn — building universal binaries."
  stage_and_rewrite "$X86_BREW" "$TMP/x86_64"
  for f in "$TMP/arm64"/*; do
    base="$(basename "$f")"
    lipo -create "$TMP/arm64/$base" "$TMP/x86_64/$base" -output "$DEST/$base"
  done
else
  echo "WARNING: no Intel Homebrew openvpn at $X86_BREW — bundling arm64-only."
  echo "         VPN will not work on Intel Macs in this build."
  cp "$TMP/arm64"/* "$DEST/"
fi

# Sign dylibs before the binary (dependencies first).
if [[ -n "$SIGN_ID" ]]; then
  for f in "$DEST"/*.dylib; do
    codesign --force --sign "$SIGN_ID" --options=runtime --timestamp "$f"
  done
  codesign --force --sign "$SIGN_ID" --options=runtime --timestamp "$DEST/openvpn"
fi

echo "Bundled into: $DEST ($(lipo -archs "$DEST/openvpn"))"
