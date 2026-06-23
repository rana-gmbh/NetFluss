#!/bin/bash
# Bundle the WireGuard userspace toolchain into a directory for the VPN client:
# wireguard-go (userspace tunnel), wg (config tool), wg-quick (bring-up script),
# and a modern bash (wg-quick requires bash 4+; macOS ships 3.2). All dylib
# dependencies are resolved recursively and rewritten to @loader_path so the set
# is relocatable inside the app bundle (Contents/Library/VPN). wg-quick adds its
# own directory to PATH, so it finds wg/wireguard-go beside it; the helper invokes
# it as `bash wg-quick …`.
#
# Usage: bundle-wireguard.sh <dest-dir> [signing-identity]
#
# arm64-only for now (the user base in testing is Apple Silicon); a universal
# build needs the Intel slices lipo'd in via CI, same as bundle-openvpn.sh (TODO).
set -euo pipefail

DEST="${1:?usage: bundle-wireguard.sh <dest-dir> [signing-identity]}"
SIGN_ID="${2:-}"

WGGO="$(brew --prefix wireguard-go)/bin/wireguard-go"
WG="$(brew --prefix wireguard-tools)/bin/wg"
WGQUICK="$(brew --prefix wireguard-tools)/bin/wg-quick"
BASH_BIN="$(brew --prefix bash)/bin/bash"

mkdir -p "$DEST"
cp "$WGGO" "$DEST/wireguard-go"
cp "$WG" "$DEST/wg"
cp "$BASH_BIN" "$DEST/bash"
cp "$WGQUICK" "$DEST/wg-quick"   # script — invoked via the bundled bash
chmod u+w "$DEST"/*

# Recursively pull in the Homebrew dylib closure of every Mach-O already staged.
while :; do
  added=0
  for f in "$DEST"/*; do
    case "$f" in *.dylib|*/wireguard-go|*/wg|*/bash) ;; *) continue ;; esac
    deps="$(otool -L "$f" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '/opt/homebrew|/usr/local' || true)"
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      base="$(basename "$dep")"
      if [[ ! -e "$DEST/$base" ]]; then
        cp "$dep" "$DEST/$base"
        chmod u+w "$DEST/$base"
        added=1
      fi
    done <<< "$deps"
  done
  [[ "$added" -eq 0 ]] && break
done

# Rewrite ids and all Homebrew load paths to @loader_path siblings.
for f in "$DEST"/*; do
  base="$(basename "$f")"
  [[ "$base" == "wg-quick" ]] && continue   # plain script
  if [[ "$base" == *.dylib ]]; then
    install_name_tool -id "@loader_path/$base" "$f"
  fi
  deps="$(otool -L "$f" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '/opt/homebrew|/usr/local' || true)"
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f"
  done <<< "$deps"
done

if [[ -n "$SIGN_ID" ]]; then
  for f in "$DEST"/*.dylib; do
    codesign --force --sign "$SIGN_ID" --options=runtime --timestamp "$f"
  done
  for bin in wireguard-go wg bash; do
    codesign --force --sign "$SIGN_ID" --options=runtime --timestamp "$DEST/$bin"
  done
fi

chmod +x "$DEST/wireguard-go" "$DEST/wg" "$DEST/bash" "$DEST/wg-quick"
echo "Bundled WireGuard tools into: $DEST"
ls "$DEST"