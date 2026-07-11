#!/usr/bin/env bash
#
# install-copilot-hooks.sh — wire GitHub Copilot CLI up to AgentBar.
#
# Unlike Claude Code (which installs the plugin, and its hooks, from a marketplace), Copilot
# CLI loads personal hooks from JSON files in its config directory. This script writes
#
#   ${COPILOT_CONFIG_DIR:-$HOME/.copilot}/hooks/agentbar.json
#
# from the committed template (copilot/hooks/agentbar.json), replacing the __AGENTBAR_HOOK__
# placeholder with the absolute, quoted path to the agentbar-hook bridge. Each hook POSTs its
# event, fire-and-forget, to the AgentBar app tagged as the "copilot" agent — the same local
# server the Claude Code plugin talks to.
#
# Usage:
#   scripts/install-copilot-hooks.sh              install (or refresh) the hooks
#   scripts/install-copilot-hooks.sh --uninstall  remove them
#
# Env overrides:
#   AGENTBAR_HOOK        explicit path to the agentbar-hook bridge
#   COPILOT_CONFIG_DIR   Copilot config dir (default: ~/.copilot)
#
# The bridge is resolved in priority order: $AGENTBAR_HOOK, then the installed app bundle
# (/Applications/AgentBar.app/Contents/Resources/agentbar-hook), then the repo copy
# (plugin/bin/agentbar-hook) for local development.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${REPO_ROOT}/copilot/hooks/agentbar.json"
COPILOT_DIR="${COPILOT_CONFIG_DIR:-$HOME/.copilot}"
HOOKS_DIR="${COPILOT_DIR}/hooks"
TARGET="${HOOKS_DIR}/agentbar.json"

if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "uninstall" ]; then
  if [ -f "$TARGET" ]; then
    rm -f "$TARGET"
    echo "==> Removed ${TARGET}"
  else
    echo "==> Nothing to remove (${TARGET} not found)"
  fi
  echo "    Restart any running Copilot CLI sessions for the change to take effect."
  exit 0
fi

# Resolve the bridge script.
APP_HOOK="/Applications/AgentBar.app/Contents/Resources/agentbar-hook"
REPO_HOOK="${REPO_ROOT}/plugin/bin/agentbar-hook"
if [ -n "${AGENTBAR_HOOK:-}" ]; then
  HOOK="$AGENTBAR_HOOK"
elif [ -x "$APP_HOOK" ]; then
  HOOK="$APP_HOOK"
elif [ -x "$REPO_HOOK" ]; then
  HOOK="$REPO_HOOK"
else
  echo "error: could not find the agentbar-hook bridge." >&2
  echo "       Install the AgentBar app (brew install --cask agentbar), or set" >&2
  echo "       AGENTBAR_HOOK=/path/to/agentbar-hook and re-run." >&2
  exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
  echo "error: template not found at ${TEMPLATE}" >&2
  exit 1
fi

mkdir -p "$HOOKS_DIR"

# Substitute the placeholder with the quoted absolute path. The path is wrapped in escaped
# double quotes inside the JSON string so a bridge path containing spaces is still one shell
# token. Escape sed-special characters in the path first (& | \).
esc_hook="$(printf '%s' "$HOOK" | sed 's/[&|\\]/\\&/g')"
sed "s|__AGENTBAR_HOOK__|\\\\\"${esc_hook}\\\\\"|g" "$TEMPLATE" > "$TARGET"

echo "==> Wrote ${TARGET}"
echo "    bridge: ${HOOK}"
echo "    events: userPromptSubmitted, postToolUse, agentStop, subagentStop, sessionEnd, errorOccurred"
echo "    Restart any running Copilot CLI sessions for the change to take effect."
