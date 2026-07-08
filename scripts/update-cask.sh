#!/usr/bin/env bash
#
# update-cask.sh — stamp a version and sha256 into Casks/agentbar.rb in place.
#
# Usage: update-cask.sh <version> <sha256>
#
#   version   marketing version, e.g. 0.2.0 (no leading "v")
#   sha256    64-hex-character checksum of the release zip
#
# Uses a sed idiom that is portable across GNU sed and macOS/BSD sed.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <version> <sha256>" >&2
  exit 2
fi

VERSION="$1"
SHA256="$2"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASK="${REPO_ROOT}/Casks/agentbar.rb"

if [ ! -f "$CASK" ]; then
  echo "error: cask not found at ${CASK}" >&2
  exit 1
fi

if ! printf '%s' "$SHA256" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "error: sha256 must be 64 lowercase hex characters, got: ${SHA256}" >&2
  exit 1
fi

# BSD sed requires an argument to -i (empty string for no backup); GNU sed
# accepts -i with no argument. Using `-i.bak` then removing the backup works
# identically on both.
sed -i.bak -E \
  -e "s/^([[:space:]]*version )\"[^\"]*\"/\\1\"${VERSION}\"/" \
  -e "s/^([[:space:]]*sha256 )\"[^\"]*\"/\\1\"${SHA256}\"/" \
  "$CASK"
rm -f "${CASK}.bak"

echo "==> Updated ${CASK}:"
grep -E '^[[:space:]]*(version|sha256) ' "$CASK"
