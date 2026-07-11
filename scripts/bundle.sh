#!/usr/bin/env bash
#
# bundle.sh — assemble dist/AgentBar.app from the release binary.
#
# Builds the classic macOS .app bundle layout around the SPM release binary:
#
#   dist/AgentBar.app/
#     Contents/
#       Info.plist        (from app/Support/Info.plist, version-stamped)
#       PkgInfo           ("APPL????")
#       MacOS/AgentBar    (the release executable)
#       Resources/        (AppIcon.icns and future assets)
#
# Env:
#   VERSION   marketing version stamped into CFBundleShortVersionString
#             (default 0.1.0)
#
# Intended to run on macOS after `swift build -c release --package-path app`.
set -euo pipefail

VERSION="${VERSION:-0.1.0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AgentBar"
BINARY="${REPO_ROOT}/app/.build/release/${APP_NAME}"
PLIST_SRC="${REPO_ROOT}/app/Support/Info.plist"
DIST="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"

if [ ! -f "$BINARY" ]; then
  echo "error: release binary not found at ${BINARY}" >&2
  echo "       run: swift build -c release --package-path app" >&2
  exit 1
fi

if [ ! -f "$PLIST_SRC" ]; then
  echo "error: Info.plist template not found at ${PLIST_SRC}" >&2
  exit 1
fi

echo "==> Assembling ${APP_NAME}.app (version ${VERSION})"

# Start from a clean bundle so stale files never linger.
rm -rf "$APP_BUNDLE"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "$BINARY" "${CONTENTS}/MacOS/${APP_NAME}"
chmod +x "${CONTENTS}/MacOS/${APP_NAME}"

cp "$PLIST_SRC" "${CONTENTS}/Info.plist"

# App icon. CFBundleIconFile in Info.plist points at "AppIcon" → AppIcon.icns.
ICON_SRC="${REPO_ROOT}/app/Support/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "${CONTENTS}/Resources/AppIcon.icns"
else
  echo "warning: ${ICON_SRC} not found; bundling without an app icon" >&2
  echo "         regenerate it with: python3 scripts/generate-icon.py" >&2
fi

# Bundle the hook bridge so it has a stable absolute path for the Copilot CLI integration
# (Claude Code references it via ${CLAUDE_PLUGIN_ROOT} from the marketplace-installed plugin;
# Copilot's personal hooks need a fixed path, and the installed app bundle is that anchor —
# scripts/install-copilot-hooks.sh looks here first).
HOOK_SRC="${REPO_ROOT}/plugin/bin/agentbar-hook"
if [ -f "$HOOK_SRC" ]; then
  cp "$HOOK_SRC" "${CONTENTS}/Resources/agentbar-hook"
  chmod +x "${CONTENTS}/Resources/agentbar-hook"
else
  echo "warning: ${HOOK_SRC} not found; app bundle will omit the Copilot hook bridge" >&2
fi

# Classic bundle signature.
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# Stamp CFBundleShortVersionString. PlistBuddy is the correct tool on macOS;
# fall back to an in-place sed rewrite if it is unavailable.
PLIST_BUDDY="/usr/libexec/PlistBuddy"
if [ -x "$PLIST_BUDDY" ]; then
  if "$PLIST_BUDDY" -c "Set :CFBundleShortVersionString ${VERSION}" "${CONTENTS}/Info.plist" 2>/dev/null; then
    :
  else
    "$PLIST_BUDDY" -c "Add :CFBundleShortVersionString string ${VERSION}" "${CONTENTS}/Info.plist"
  fi
else
  echo "warning: ${PLIST_BUDDY} not found; using sed fallback to stamp version" >&2
  # Replace the string value on the line following the CFBundleShortVersionString key.
  tmp="$(mktemp)"
  awk -v ver="$VERSION" '
    prev ~ /CFBundleShortVersionString/ {
      sub(/<string>[^<]*<\/string>/, "<string>" ver "</string>")
    }
    { print; prev = $0 }
  ' "${CONTENTS}/Info.plist" > "$tmp"
  mv "$tmp" "${CONTENTS}/Info.plist"
fi

echo "==> Built ${APP_BUNDLE}"
