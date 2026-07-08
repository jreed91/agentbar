# AgentBar — build / bundle / sign / notarize / distribute
#
# Common flows:
#   make bundle                       assemble dist/AgentBar.app (release build)
#   make install                      local ad-hoc build → /Applications
#   make sign SIGNING_IDENTITY="…"    Developer ID codesign
#   make zip notarize                 notarize a signed bundle for distribution

APP_NAME  := AgentBar
BUNDLE_ID := com.jreed91.AgentBar
VERSION   ?= 0.1.0
DIST      := dist

APP_BUNDLE := $(DIST)/$(APP_NAME).app
ZIP        := $(DIST)/$(APP_NAME)-$(VERSION).zip

.PHONY: all build bundle sign adhoc zip notarize install clean

all: bundle

build:
	swift build -c release --package-path app

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
	codesign --force --deep --options runtime --sign "$(SIGNING_IDENTITY)" $(APP_BUNDLE)

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

clean:
	rm -rf $(DIST) app/.build
