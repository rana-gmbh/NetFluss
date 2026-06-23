#!/bin/bash
# Bundle the WireGuard userspace toolchain into a directory for the VPN client:
# wireguard-go (userspace tunnel), wg (config tool), wg-quick (bring-up script),
# and a modern bash (wg-quick requires bash 4+; macOS ships 3.2). All dylib
# dependencies are resolved recursively and rewritten to @loader_path so the set
# is relocatable inside the app bundle (Contents/Library/VPN). wg-quick adds its
# own directory to PATH, so it finds wg/wireguard-go beside it; the helper invokes
# it as `bash wg-quick …`.
#
# Usage:
#   bundle-wireguard.sh <dest-dir> [signing-identity]
#       Bundle from the local Homebrew. Universal if X86_THIN_DIR points at a
#       rewritten x86_64 set (produced by a `stage-only` run on an Intel host);
#       otherwise arm64-only with a warning.
#   STAGE_ONLY=1 bundle-wireguard.sh <out-dir>
#       Just stage + path-rewrite the local arch's set (no sign, no lipo). Run on
#       an Intel runner to produce the x86_64 set for X86_THIN_DIR.
set -euo pipefail

DEST="${1:?usage: bundle-wireguard.sh <dest-dir> [signing-identity]}"
SIGN_ID="${2:-}"
STAGE_ONLY="${STAGE_ONLY:-0}"
X86_THIN_DIR="${X86_THIN_DIR:-}"

is_macho() { case "$(basename "$1")" in *.dylib|*/wireguard-go|*/wg|*/bash|wireguard-go|wg|bash) return 0 ;; *) return 1 ;; esac; }

# Copy wireguard-go + wg + bash + wg-quick from the local Homebrew into $1, pull
# in the recursive dylib closure, and rewrite all load paths to @loader_path.
stage_thin() {
  local out="$1"
  mkdir -p "$out"
  cp "$(brew --prefix wireguard-go)/bin/wireguard-go" "$out/wireguard-go"
  cp "$(brew --prefix wireguard-tools)/bin/wg" "$out/wg"
  cp "$(brew --prefix wireguard-tools)/bin/wg-quick" "$out/wg-quick"
  cp "$(brew --prefix bash)/bin/bash" "$out/bash"
  chmod u+w "$out"/*

  while :; do
    local added=0
    for f in "$out"/*; do
      is_macho "$f" || continue
      local deps; deps="$(otool -L "$f" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '/opt/homebrew|/usr/local' || true)"
      while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        local base; base="$(basename "$dep")"
        if [[ ! -e "$out/$base" ]]; then cp "$dep" "$out/$base"; chmod u+w "$out/$base"; added=1; fi
      done <<< "$deps"
    done
    [[ "$added" -eq 0 ]] && break
  done

  for f in "$out"/*; do
    local base; base="$(basename "$f")"
    [[ "$base" == "wg-quick" ]] && continue
    [[ "$base" == *.dylib ]] && install_name_tool -id "@loader_path/$base" "$f"
    local deps; deps="$(otool -L "$f" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '/opt/homebrew|/usr/local' || true)"
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f"
    done <<< "$deps"
  done
}

if [[ "$STAGE_ONLY" == "1" ]]; then
  stage_thin "$DEST"
  echo "Staged thin WireGuard set ($(lipo -archs "$DEST/wg")) into: $DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
stage_thin "$TMP/arm64"
mkdir -p "$DEST"

if [[ -n "$X86_THIN_DIR" && -f "$X86_THIN_DIR/wg" ]]; then
  echo "Found Intel WireGuard set at $X86_THIN_DIR — building universal binaries."
  for f in "$TMP/arm64"/*; do
    base="$(basename "$f")"
    if [[ "$base" == "wg-quick" ]]; then
      cp "$f" "$DEST/$base"                       # script — same on both arches
    elif [[ -f "$X86_THIN_DIR/$base" ]]; then
      lipo -create "$f" "$X86_THIN_DIR/$base" -output "$DEST/$base"
    else
      cp "$f" "$DEST/$base"
    fi
  done
else
  echo "WARNING: no Intel WireGuard set (X86_THIN_DIR) — bundling arm64-only."
  echo "         WireGuard will not work on Intel Macs in this build."
  cp "$TMP/arm64"/* "$DEST/"
fi

if [[ -n "$SIGN_ID" ]]; then
  for f in "$DEST"/*.dylib; do
    codesign --force --sign "$SIGN_ID" --options=runtime --timestamp "$f"
  done
  for bin in wireguard-go wg bash; do
    codesign --force --sign "$SIGN_ID" --options=runtime --timestamp "$DEST/$bin"
  done
fi

chmod +x "$DEST/wireguard-go" "$DEST/wg" "$DEST/bash" "$DEST/wg-quick"
echo "Bundled WireGuard tools into: $DEST ($(lipo -archs "$DEST/wg"))"