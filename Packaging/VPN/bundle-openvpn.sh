#!/bin/bash
# Bundle the Homebrew `openvpn` binary and its dylib closure into a directory,
# rewriting all load paths to @loader_path so the set is relocatable inside the
# app bundle (Contents/Library/VPN). Optionally codesigns each Mach-O.
#
# Usage: bundle-openvpn.sh <dest-dir> [signing-identity]
#
# NOTE: this stages the arm64 Homebrew build for the packaging spike. A shipping
# universal build must lipo arm64 + x86_64 binaries/dylibs (TODO).
set -euo pipefail

DEST="${1:?usage: bundle-openvpn.sh <dest-dir> [signing-identity]}"
SIGN_ID="${2:-}"
OV_PREFIX="$(brew --prefix openvpn)"

# Dependency closure (resolved via otool; stable for openvpn 2.7 / openssl@3).
LIBS=(
  "/opt/homebrew/opt/lzo/lib/liblzo2.2.dylib"
  "/opt/homebrew/opt/lz4/lib/liblz4.1.dylib"
  "/opt/homebrew/opt/pkcs11-helper/lib/libpkcs11-helper.1.dylib"
  "/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib"
  "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib"
)

mkdir -p "$DEST"
cp "$OV_PREFIX/sbin/openvpn" "$DEST/openvpn"
for l in "${LIBS[@]}"; do cp "$l" "$DEST/$(basename "$l")"; done
chmod u+w "$DEST"/*

# Rewrite ids and any /opt/homebrew dependency (opt OR Cellar path) to a sibling
# reference via @loader_path (binary and all dylibs live in the same directory).
for f in "$DEST"/*; do
  base="$(basename "$f")"
  if [[ "$base" == *.dylib ]]; then
    install_name_tool -id "@loader_path/$base" "$f"
  fi
  # Collect dependency paths first (|| true so a no-match grep doesn't trip
  # pipefail), then rewrite each homebrew dep to a sibling @loader_path ref.
  deps="$(otool -L "$f" | awk 'NR>1 {print $1}' | grep "/opt/homebrew" || true)"
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f"
  done <<< "$deps"
done

# Sign dylibs before the binary (dependencies first).
if [[ -n "$SIGN_ID" ]]; then
  for f in "$DEST"/*.dylib; do
    codesign --force --sign "$SIGN_ID" --options=runtime --timestamp "$f"
  done
  codesign --force --sign "$SIGN_ID" --options=runtime --timestamp "$DEST/openvpn"
fi

echo "Bundled into: $DEST"
