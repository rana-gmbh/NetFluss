#!/bin/bash
# Copyright (C) 2026 Rana GmbH — GPLv3. See LICENSE at the repository root.
#
# Releases NetFluss for macOS and Windows together, from the same commit and with the same
# release notes:
#
#   Tools/release.sh 2.7.3 notes.md                    both platforms (the normal case)
#   Tools/release.sh 2.7.3 notes.md --windows-notes w.md   Windows gets its own notes
#   Tools/release.sh 2.7.4-beta.1 notes.md --windows-only  a Windows beta (pre-release)
#   Tools/release.sh 2.7.3 notes.md --mac-only           a Mac-only release
#   Tools/release.sh 2.7.3 notes.md --dry-run            checks only, creates nothing
#
# Why two GitHub releases rather than one: the Mac's Sparkle feed is
# releases/latest/download/appcast.xml, so the Mac release must be "latest", and Windows
# installs only look for releases tagged win-v… (windows/src/NetFluss.Core/UpdateLookup.cs).
# So each version gets vX.Y.Z (Mac, latest) and win-vX.Y.Z (Windows, never latest). Creating
# a release pushes its tag, and the tags start release.yml and windows-release.yml.
#
# Run it from your own machine, not from a workflow: a tag pushed with a workflow's
# GITHUB_TOKEN starts no other workflow, so neither build would run.

set -euo pipefail

REPO="rana-gmbh/NetFluss"

die() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '4,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

[[ $# -ge 2 ]] || usage
VERSION="$1"
NOTES="$2"
shift 2

MAC=1
WINDOWS=1
DRY_RUN=0
WINDOWS_NOTES=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mac-only) WINDOWS=0 ;;
        --windows-only) MAC=0 ;;
        --windows-notes) [[ $# -ge 2 ]] || usage; WINDOWS_NOTES="$2"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        *) usage ;;
    esac
    shift
done

[[ $MAC -eq 1 || $WINDOWS -eq 1 ]] || die "--mac-only and --windows-only exclude each other."
[[ -s "$NOTES" ]] || die "release notes file '$NOTES' is missing or empty."
[[ -z "$WINDOWS_NOTES" || -s "$WINDOWS_NOTES" ]] || die "Windows notes file '$WINDOWS_NOTES' is missing or empty."
WINDOWS_NOTES="${WINDOWS_NOTES:-$NOTES}"

# The same version format both workflows accept. A pre-release is a Windows-only thing: the
# Mac has no beta channel, and a Mac pre-release would not be "latest", so Sparkle would
# never offer it.
if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    PRERELEASE=0
elif [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-(alpha|beta|rc)\.[0-9]+$ ]]; then
    PRERELEASE=1
    [[ $MAC -eq 0 ]] || die "$VERSION is a pre-release; pre-releases are Windows-only (add --windows-only)."
else
    die "version must be X.Y.Z, or X.Y.Z-beta.N with --windows-only; got '$VERSION'."
fi
if [[ $WINDOWS -eq 1 && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    die "Windows versions need three parts (X.Y.Z); got '$VERSION'."
fi

cd "$(git rev-parse --show-toplevel)"

command -v gh >/dev/null || die "the GitHub CLI (gh) is not installed."
gh auth status >/dev/null 2>&1 || die "gh is not signed in (gh auth login)."

# --- The commit -------------------------------------------------------------------------

BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
[[ "$BRANCH" == "main" ]] || die "releases are cut from main; this checkout is on '${BRANCH:-a detached HEAD}'."

# Untracked files (screenshots, notes) do not end up in a release; changes to tracked files
# would mean the release is not what this checkout shows.
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "tracked files have uncommitted changes."

git fetch --quiet origin main || die "could not fetch main from GitHub."
SHA="$(git rev-parse HEAD)"
[[ "$SHA" == "$(git rev-parse origin/main)" ]] || die "main is not the same as origin/main; push or pull first."

# Tags are checked on GitHub, not locally: local tags can be stale or differ from GitHub's.
MAC_TAG="v$VERSION"
WIN_TAG="win-v$VERSION"
tag_exists() {
    [[ -n "$(git ls-remote --tags origin "refs/tags/$1")" ]] || gh release view "$1" --repo "$REPO" >/dev/null 2>&1
}
if [[ $MAC -eq 1 ]] && tag_exists "$MAC_TAG"; then die "$MAC_TAG exists already on GitHub."; fi
if [[ $WINDOWS -eq 1 ]] && tag_exists "$WIN_TAG"; then die "$WIN_TAG exists already on GitHub."; fi

# Windows CI runs only when windows/ changed, so HEAD may have no run; a failed or unfinished
# one stops the release.
if [[ $WINDOWS -eq 1 ]]; then
    CI="$(gh run list --repo "$REPO" --workflow "Windows CI" --commit "$SHA" --json status,conclusion \
        --jq '.[0] | if . == null then "none" else "\(.status) \(.conclusion)" end')"
    case "$CI" in
        "completed success") echo "Windows CI passed on ${SHA:0:7}." ;;
        none) echo "Windows CI has no run on ${SHA:0:7} (nothing under windows/ changed since its last run)." ;;
        *) die "Windows CI on ${SHA:0:7} is '$CI'; release only a commit whose Windows CI passed." ;;
    esac
fi

# --- Confirm ----------------------------------------------------------------------------

echo
echo "Commit:  ${SHA:0:7}  $(git log -1 --format=%s "$SHA")"
[[ $MAC -eq 0 ]] || echo "Mac:     $MAC_TAG  \"NetFluss $VERSION\"  (latest)  notes: $NOTES"
[[ $WINDOWS -eq 0 ]] || echo "Windows: $WIN_TAG  \"NetFluss $VERSION for Windows\"  ($([[ $PRERELEASE -eq 1 ]] && echo pre-release || echo stable), not latest)  notes: $WINDOWS_NOTES"
echo

if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry run: nothing created."
    exit 0
fi

read -r -p "Create these releases? This publishes them and starts the builds. [y/N] " answer
[[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "Nothing created."; exit 1; }

# --- Create -----------------------------------------------------------------------------

# The Mac first: it is the one marked latest. windows-release.yml also puts "latest" back
# on the newest Mac release if anything moved it.
if [[ $MAC -eq 1 ]]; then
    gh release create "$MAC_TAG" --repo "$REPO" --target "$SHA" \
        --title "NetFluss $VERSION" --latest --notes-file "$NOTES"
fi

if [[ $WINDOWS -eq 1 ]]; then
    PRE=()
    [[ $PRERELEASE -eq 0 ]] || PRE=(--prerelease)
    gh release create "$WIN_TAG" --repo "$REPO" --target "$SHA" \
        --title "NetFluss $VERSION for Windows" --latest=false ${PRE[@]+"${PRE[@]}"} --notes-file "$WINDOWS_NOTES"
fi

echo
echo "Builds started: https://github.com/$REPO/actions"
if [[ $MAC -eq 1 ]]; then
    echo "When the Mac build has finished, update the Homebrew cask (rana-gmbh/homebrew-netfluss):"
    echo "  curl -sL https://github.com/$REPO/releases/download/$MAC_TAG/NetFluss-$VERSION.zip | shasum -a 256"
fi
