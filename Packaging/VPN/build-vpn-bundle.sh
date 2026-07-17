#!/bin/bash
# Build the universal (arm64 + x86_64) VPN toolchain for NetFluss from pinned
# Homebrew bottles downloaded straight from ghcr.io — no Intel Mac and no paid
# Intel CI runner required (issue #48).
#
# Why bottles-from-ghcr: GitHub retired the free macos-13 Intel runner, so the
# x86_64 VPN slice can no longer be compiled on free CI. But Homebrew still ships
# prebuilt x86_64 *ventura* bottles for every tool we bundle, and those download
# fine on an Apple-Silicon host. A ventura-targeted (macOS 13) x86_64 binary runs
# on every still-supported Intel Mac (13/14/15). We pin the SAME versions for the
# arm64 slice so both halves of each universal binary are one matched toolchain.
#
# Usage:
#   build-vpn-bundle.sh <dest-vpn-dir> [signing-identity]
# Env:
#   INTEL=0   Build arm64-only (skip the x86_64 slice) — for quick local testing.
#
# Produces, in <dest-vpn-dir>:
#   openvpn (+ libssl/libcrypto/liblzo2/liblz4/libpkcs11-helper dylibs)
#   wireguard-go, wg, wg-quick, bash (+ libreadline/libncursesw/libintl … dylibs)
# with every load path rewritten to @loader_path so the set is relocatable inside
# the app bundle. Mach-Os are signed if a Developer ID identity is given.
set -euo pipefail

DEST="${1:?usage: build-vpn-bundle.sh <dest-vpn-dir> [signing-identity]}"
SIGN_ID="${2:-}"
INTEL="${INTEL:-1}"

# Matched, ventura-compatible pins. Every version below has BOTH an arm64_ventura
# and an x86_64 ventura bottle on ghcr (verified). openvpn 2.7.x and current
# openssl/pkcs11-helper/wireguard-tools/bash dropped their x86_64 ventura bottles,
# which is why these are held slightly behind latest. Refresh together, and keep
# to versions that still publish a `ventura` (x86_64) bottle.
PINS=(
  "openvpn=2.6.14"
  "openssl@3=3.5.2"
  "lzo=2.10"
  "lz4=1.10.0"
  "pkcs11-helper=1.30.0"
  "wireguard-go=0.0.20250522"
  "wireguard-tools=1.0.20250521"
  "bash=5.3.3"
  "readline=8.3.1"
  "ncurses=6.5"
  "gettext=0.26"
)

# The executables/scripts we actually ship (resolved from the cellar); their dylib
# closure is pulled in automatically.
TARGET_BINS=(openvpn wireguard-go wg bash)
TARGET_SCRIPTS=(wg-quick)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# homebrew/core OCI repo for a formula ('openssl@3' -> 'homebrew/core/openssl/3').
repo_of() { echo "homebrew/core/${1/@//}"; }

ghcr_token() {
  curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:$1:pull" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])"
}

# Download the bottle for <formula> <version> <tag> and extract it under $1's
# cellar root. Bottles untar to <formula>/<version>/…, so a basename search over
# the cellar later finds every binary and dylib regardless of formula.
download_bottle() {
  local formula="$1" version="$2" tag="$3" cellar="$4"
  local repo; repo="$(repo_of "$formula")"
  local token; token="$(ghcr_token "$repo")"
  # The bottle tag ('ventura', 'arm64_ventura') selects one manifest from the
  # version's OCI index; that child manifest's single layer is the bottle tarball.
  local index child layer
  index="$(curl -fsSL -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    "https://ghcr.io/v2/$repo/manifests/$version")"
  child="$(echo "$index" | python3 -c "import sys,json
d=json.load(sys.stdin); want='$version.$tag'
print(next(m['digest'] for m in d['manifests']
          if m['annotations']['org.opencontainers.image.ref.name']==want))")"
  layer="$(curl -fsSL -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://ghcr.io/v2/$repo/manifests/$child" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['layers'][0]['digest'])")"
  mkdir -p "$cellar"
  curl -fsSL -H "Authorization: Bearer $token" \
    "https://ghcr.io/v2/$repo/blobs/$layer" -o "$WORK/bottle.tar.gz"
  tar xzf "$WORK/bottle.tar.gz" -C "$cellar"
}

is_macho() { file -b "$1" 2>/dev/null | grep -q "Mach-O"; }

# Assemble one arch's flat, relocatable set into $out from the cellar at $cellar.
stage_arch() {
  local out="$1" cellar="$2"
  mkdir -p "$out"
  local b
  for b in "${TARGET_BINS[@]}"; do
    cp "$(find "$cellar" -type f -name "$b" -perm +111 | head -1)" "$out/$b"
  done
  for b in "${TARGET_SCRIPTS[@]}"; do
    cp "$(find "$cellar" -type f -name "$b" | head -1)" "$out/$b"
  done
  chmod -R u+w "$out"

  # Pull in the recursive dylib closure by basename (bottle load paths are
  # @@HOMEBREW_PREFIX@@/opt/<f>/lib/<lib>, so basename resolves within the cellar).
  while :; do
    local added=0 f dep base src
    for f in "$out"/*; do
      is_macho "$f" || continue
      for dep in $(otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | grep -E '@@HOMEBREW|/opt/homebrew|/usr/local' || true); do
        base="$(basename "$dep")"
        if [[ ! -e "$out/$base" ]]; then
          # Include symlinks: bottles ship e.g. liblz4.1.dylib -> liblz4.1.10.0.dylib
          # and libreadline.8.dylib -> …8.3.dylib. cp -L copies the real content
          # under the name the loader expects (@loader_path/<base>).
          src="$(find "$cellar" -name "$base" | head -1)"
          if [[ -n "$src" ]]; then cp -L "$src" "$out/$base"; chmod u+w "$out/$base"; added=1; fi
        fi
      done
    done
    [[ "$added" -eq 0 ]] && break
  done

  # Rewrite every homebrew load path to a @loader_path sibling.
  for f in "$out"/*; do
    is_macho "$f" || continue
    base="$(basename "$f")"
    [[ "$base" == *.dylib ]] && install_name_tool -id "@loader_path/$base" "$f"
    local dep
    for dep in $(otool -L "$f" 2>/dev/null | awk 'NR>1{print $1}' | grep -E '@@HOMEBREW|/opt/homebrew|/usr/local' || true); do
      install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f"
    done
  done
}

echo "Staging arm64 slice…"
ARM_OUT="$WORK/arm64"
for pin in "${PINS[@]}"; do download_bottle "${pin%=*}" "${pin#*=}" "arm64_ventura" "$WORK/cellar-arm64"; done
stage_arch "$ARM_OUT" "$WORK/cellar-arm64"

mkdir -p "$DEST"
if [[ "$INTEL" == "1" ]]; then
  echo "Staging x86_64 slice…"
  X86_OUT="$WORK/x86_64"
  for pin in "${PINS[@]}"; do download_bottle "${pin%=*}" "${pin#*=}" "ventura" "$WORK/cellar-x86_64"; done
  stage_arch "$X86_OUT" "$WORK/cellar-x86_64"

  echo "Creating universal binaries…"
  for f in "$ARM_OUT"/*; do
    base="$(basename "$f")"
    if is_macho "$f" && [[ -f "$X86_OUT/$base" ]] && is_macho "$X86_OUT/$base"; then
      lipo -create "$f" "$X86_OUT/$base" -output "$DEST/$base"
    else
      cp "$f" "$DEST/$base"   # scripts (wg-quick) — identical across arches
    fi
  done
else
  echo "WARNING: INTEL=0 — bundling arm64-only (VPN will not run on Intel Macs)."
  cp "$ARM_OUT"/* "$DEST/"
fi

chmod +x "$DEST"/openvpn "$DEST"/wireguard-go "$DEST"/wg "$DEST"/wg-quick "$DEST"/bash

# Sign dylibs before the executables that load them.
if [[ -n "$SIGN_ID" ]]; then
  for f in "$DEST"/*.dylib; do
    codesign --force --sign "$SIGN_ID" --options=runtime --timestamp "$f"
  done
  for b in openvpn wireguard-go wg bash; do
    codesign --force --sign "$SIGN_ID" --options=runtime --timestamp "$DEST/$b"
  done
fi

echo "Universal VPN toolchain in: $DEST"
echo "  openvpn:      $(lipo -archs "$DEST/openvpn")"
echo "  wireguard-go: $(lipo -archs "$DEST/wireguard-go")"
echo "  wg:           $(lipo -archs "$DEST/wg")"
echo "  bash:         $(lipo -archs "$DEST/bash")"
