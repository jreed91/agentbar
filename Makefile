# AgentBar — build / bundle / sign / notarize / distribute
#
# Common flows:
#   make bundle                       assemble dist/AgentBar.app (release build)
#   make install                      local ad-hoc build → /Applications
#   make sign SIGNING_IDENTITY="…"    Developer ID codesign
#   make zip notarize                 notarize a signed bundle for distribution

APP_NAME  := AgentBar
BUNDLE_ID := com.jreed91.AgentBar
# Default to the latest release tag so a manual `make bundle zip` never stamps
# a version older than what users already have. CI overrides this explicitly.
VERSION   ?= $(shell { git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0-dev; } | sed 's/^v//')
DIST      := dist

APP_BUNDLE := $(DIST)/$(APP_NAME).app
ZIP        := $(DIST)/$(APP_NAME)-$(VERSION).zip

.PHONY: all build test test-plugin bundle sign adhoc zip notarize install clean icon doctor \
        install-copilot uninstall-copilot

all: bundle

build:
	swift build -c release --package-path app

# Run the Swift unit tests (payload/transcript parsers, queue lifecycle, formatting).
test:
	swift test --package-path app

# Validate and test the Claude Code mod (plugin/). Needs the `claude` CLI on PATH.
test-plugin:
	claude plugin validate plugin
	claude plugin test plugin

# Verify both halves are wired up: the app installed & responding, and the plugin
# hook present and executable. The two-part install (cask + plugin) is the most common
# source of "notifications aren't showing", so this checks each part end to end.
doctor:
	@echo "AgentBar doctor"
	@echo "==============="
	@if [ -d "/Applications/$(APP_NAME).app" ]; then \
		echo "ok   app installed: /Applications/$(APP_NAME).app"; \
	else \
		echo "warn app not in /Applications — install the cask or run 'make install'"; \
	fi
	@if [ -f "plugin/hooks/agentbar.tsx" ]; then \
		echo "ok   Claude Code mod present (plugin/hooks/agentbar.tsx)"; \
	else \
		echo "FAIL plugin/hooks/agentbar.tsx missing"; \
	fi
	@if [ -x "bin/agentbar-hook" ]; then \
		echo "ok   hook bridge present and executable (used by Copilot)"; \
	else \
		echo "FAIL bin/agentbar-hook missing or not executable"; \
	fi
	@if [ -f "$${COPILOT_CONFIG_DIR:-$$HOME/.copilot}/hooks/agentbar.json" ]; then \
		echo "ok   Copilot hooks installed: $${COPILOT_CONFIG_DIR:-$$HOME/.copilot}/hooks/agentbar.json"; \
	else \
		echo "info Copilot hooks not installed — run 'make install-copilot' (optional; Claude Code needs no step here)"; \
	fi
	@command -v curl >/dev/null 2>&1 \
		&& echo "ok   curl available" \
		|| echo "FAIL curl not found — the hook needs it"
	@echo "---"
	@echo "Live pipeline check (launches AgentBar if needed):"
	@bin/agentbar-hook --selftest || true

# Regenerate app/Support/AppIcon.icns from the pure-Python design source.
# Only needed when the icon design changes; the .icns is committed.
icon:
	python3 scripts/generate-icon.py

bundle: build
	VERSION=$(VERSION) scripts/bundle.sh

# Developer ID signing. Requires SIGNING_IDENTITY, e.g.
#   make sign SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)"
sign:
	@if [ -z "$(SIGNING_IDENTITY)" ]; then \
		echo "error: SIGNING_IDENTITY is not set."; \
		echo "       make sign SIGNING_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""; \
		echo "       (for local unsigned dev builds use: make adhoc)"; \
		exit 1; \
	fi
	codesign --force --deep --options runtime --timestamp --sign "$(SIGNING_IDENTITY)" $(APP_BUNDLE)

# Ad-hoc signature ("-") for local development — no Developer ID needed.
adhoc:
	codesign --force --deep --sign - $(APP_BUNDLE)

zip:
	ditto -c -k --keepParent $(APP_BUNDLE) $(ZIP)

# Notarize a signed, zipped bundle, then staple the ticket and re-zip so the
# stapled bundle is what ships.
notarize: zip
	xcrun notarytool submit $(ZIP) \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(APPLE_TEAM_ID)" \
		--password "$(APPLE_APP_PASSWORD)" \
		--wait
	xcrun stapler staple $(APP_BUNDLE)
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP_BUNDLE) $(ZIP)

# Local install: build, ad-hoc sign, replace any copy in /Applications.
install: bundle adhoc
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_BUNDLE) /Applications/$(APP_NAME).app

# Wire GitHub Copilot CLI to AgentBar by writing ~/.copilot/hooks/agentbar.json. Claude Code
# gets its hooks from the plugin marketplace; Copilot needs this one-time install step.
install-copilot:
	scripts/install-copilot-hooks.sh

uninstall-copilot:
	scripts/install-copilot-hooks.sh --uninstall

clean:
	rm -rf $(DIST) app/.build
