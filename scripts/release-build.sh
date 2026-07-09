#!/usr/bin/env bash
#
# release-build.sh — build, sign, notarize, and package AgentBar.app for a
# release, then stamp the Homebrew cask with the new version + checksum.
#
# Invoked by semantic-release (@semantic-release/exec) during the `prepare`
# step, once the next version has been computed from the commit history:
#
#   scripts/release-build.sh <version>
#
# It produces dist/AgentBar-<version>.zip (uploaded as the release asset by
# @semantic-release/github) and rewrites Casks/agentbar.rb in place (committed
# back to main by @semantic-release/git).
#
# Required environment (supplied as CI secrets by .github/workflows/release.yml):
#   MACOS_CERT_P12          base64-encoded Developer ID Application .p12
#   MACOS_CERT_PASSWORD     password for the .p12
#   MACOS_SIGNING_IDENTITY  codesign identity, e.g. "Developer ID Application: … (TEAMID)"
#   APPLE_ID                Apple ID for notarization
#   APPLE_TEAM_ID           Apple Developer Team ID
#   APPLE_APP_PASSWORD      app-specific password for notarization
#
# Runs on macOS (needs swift, codesign, xcrun, ditto, security).
set -euo pipefail

VERSION="${1:?usage: release-build.sh <version>}"
export VERSION

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ZIP="dist/AgentBar-${VERSION}.zip"

echo "==> Building AgentBar ${VERSION}"
swift build -c release --package-path app
scripts/bundle.sh

echo "==> Importing signing certificate into a temporary keychain"
KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/agentbar-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"
CERT_PATH="${RUNNER_TEMP:-/tmp}/agentbar-cert.p12"

printf '%s' "$MACOS_CERT_P12" | base64 --decode > "$CERT_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

security import "$CERT_PATH" \
  -P "$MACOS_CERT_PASSWORD" \
  -A -t cert -f pkcs12 \
  -k "$KEYCHAIN_PATH"
security set-key-partition-list \
  -S apple-tool:,apple: \
  -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

# Make the temporary keychain visible to codesign.
security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db

rm -f "$CERT_PATH"

echo "==> Codesigning"
codesign --force --deep --options runtime --timestamp \
  --sign "$MACOS_SIGNING_IDENTITY" \
  dist/AgentBar.app
codesign --verify --deep --strict --verbose=2 dist/AgentBar.app

echo "==> Zipping ${ZIP}"
ditto -c -k --keepParent dist/AgentBar.app "$ZIP"

echo "==> Notarizing & stapling"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" \
  --wait
xcrun stapler staple dist/AgentBar.app
# Re-zip so the published artifact contains the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent dist/AgentBar.app "$ZIP"

echo "==> Stamping cask"
SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
scripts/update-cask.sh "$VERSION" "$SHA256"

echo "==> release-build.sh complete: ${ZIP} (sha256 ${SHA256})"
