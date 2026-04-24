APP_NAME  := Lede
BUNDLE_ID := com.lede.app

DEBUG_DIR    := .build/debug
RELEASE_DIR  := .build/apple/Products/Release
DEBUG_EXEC   := $(DEBUG_DIR)/$(APP_NAME)
DEBUG_APP    := $(DEBUG_DIR)/$(APP_NAME).app
RELEASE_EXEC := $(RELEASE_DIR)/$(APP_NAME)
RELEASE_APP  := $(RELEASE_DIR)/$(APP_NAME).app
ENTITLEMENTS := Resources/Lede.entitlements

# Resolve the signing identity lazily — picks up Apple Dev / Developer ID,
# else falls through to the self-signed "Lede Dev" path.
IDENTITY = $(shell ./scripts/setup-dev-cert.sh)

# For notarized release you need a Developer ID Application identity. The
# resolver above will pick it up first if installed; you can also override:
#   make release IDENTITY="Developer ID Application: Your Name (TEAMID)"

.PHONY: all build bundle sign run clean reset-cert release release-bundle release-sign notarize

all: run

build:
	swift build

bundle: build
	@rm -rf "$(DEBUG_APP)"
	@mkdir -p "$(DEBUG_APP)/Contents/MacOS"
	@cp "$(DEBUG_EXEC)" "$(DEBUG_APP)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(DEBUG_APP)/Contents/Info.plist"

# Local dev sign — keeps Keychain Designated Requirement stable across rebuilds
# (so "Always Allow" sticks). Hardened Runtime is enabled here too so the
# signing flags match the release path; the only difference at release is the
# universal binary + Developer ID identity.
sign: bundle
	@codesign --force \
	    --sign "$(IDENTITY)" \
	    --options runtime \
	    --entitlements $(ENTITLEMENTS) \
	    "$(DEBUG_APP)"
	@echo "  ✓ Signed $(DEBUG_APP) with: $(IDENTITY)"

run: sign
	@killall "$(APP_NAME)" 2>/dev/null || true
	@open "$(DEBUG_APP)"
	@echo "  ✓ Launched Lede"

# Universal arm64 + x86_64 release build, ready for notarization.
release:
	swift build -c release --arch arm64 --arch x86_64

release-bundle: release
	@rm -rf "$(RELEASE_APP)"
	@mkdir -p "$(RELEASE_APP)/Contents/MacOS"
	@cp "$(RELEASE_EXEC)" "$(RELEASE_APP)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(RELEASE_APP)/Contents/Info.plist"

release-sign: release-bundle
	@codesign --force --deep \
	    --sign "$(IDENTITY)" \
	    --options runtime \
	    --entitlements $(ENTITLEMENTS) \
	    --timestamp \
	    "$(RELEASE_APP)"
	@codesign -dvv "$(RELEASE_APP)" 2>&1 | grep -E 'Authority|TeamIdentifier|Identifier|flags='
	@echo "  ✓ Signed release at $(RELEASE_APP)"

# Submit the signed .app to Apple's notarization service. Requires a
# notarytool keychain profile created via:
#   xcrun notarytool store-credentials lede-notary --apple-id YOU@example.com \
#       --team-id TEAMID --password APP_SPECIFIC_PASSWORD
notarize: release-sign
	@cd $(RELEASE_DIR) && \
	    ditto -c -k --keepParent "$(APP_NAME).app" "$(APP_NAME).zip" && \
	    xcrun notarytool submit "$(APP_NAME).zip" --keychain-profile lede-notary --wait && \
	    xcrun stapler staple "$(APP_NAME).app"

clean:
	swift package clean
	rm -rf "$(DEBUG_APP)" "$(RELEASE_APP)"

reset-cert:
	@for sha in $$(security find-certificate -a -c "Lede Dev" -Z ~/Library/Keychains/login.keychain-db 2>/dev/null | awk '/SHA-1 hash:/ {print $$3}'); do \
	    echo "  Deleting cert $$sha"; \
	    security delete-certificate -Z "$$sha" ~/Library/Keychains/login.keychain-db 2>&1 | head -1; \
	done
