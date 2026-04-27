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
# else falls through to the self-signed "Lede Dev" path. Used for `make run`.
IDENTITY = $(shell ./scripts/setup-dev-cert.sh)

# For release we strictly need a Developer ID Application identity (Apple
# Development won't pass Gatekeeper on other Macs). Looks one up by name.
RELEASE_IDENTITY = $(shell security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $$2; exit }')

.PHONY: all build bundle sign run clean reset-cert release release-bundle release-sign notarize dmg screenshot sparkle-sign

VERSION ?= 0.1
DMG := $(RELEASE_DIR)/Lede-$(VERSION).dmg
SPARKLE_BIN := .build/artifacts/sparkle/Sparkle/bin

all: run

build:
	swift build

bundle: build
	@rm -rf "$(DEBUG_APP)"
	@mkdir -p "$(DEBUG_APP)/Contents/MacOS" "$(DEBUG_APP)/Contents/Resources" "$(DEBUG_APP)/Contents/Frameworks"
	@cp "$(DEBUG_EXEC)" "$(DEBUG_APP)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(DEBUG_APP)/Contents/Info.plist"
	@# Stamp VERSION into the bundle's plist. Sparkle compares CFBundleVersion
	@# in the installed app to <sparkle:version> in appcast.xml, so this must
	@# match the released VERSION or auto-update never fires.
	@plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(DEBUG_APP)/Contents/Info.plist"
	@plutil -replace CFBundleVersion -string "$(VERSION)" "$(DEBUG_APP)/Contents/Info.plist"
	@cp Resources/AppIcon.icns "$(DEBUG_APP)/Contents/Resources/AppIcon.icns" 2>/dev/null || true
	@# Linked dynamic frameworks (Sparkle, etc.) live alongside the binary
	@# in SwiftPM's output and must be relocated into Contents/Frameworks.
	@# SwiftPM-built binaries compile with @loader_path/lib only, so we add
	@# the standard app-bundle rpath @executable_path/../Frameworks.
	@if [ -d "$(DEBUG_DIR)/Sparkle.framework" ]; then \
	    cp -R "$(DEBUG_DIR)/Sparkle.framework" "$(DEBUG_APP)/Contents/Frameworks/"; \
	    install_name_tool -add_rpath "@executable_path/../Frameworks" \
	        "$(DEBUG_APP)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true; \
	fi

# Local dev sign — keeps Keychain Designated Requirement stable across rebuilds
# (so "Always Allow" sticks). Hardened Runtime is enabled here too so the
# signing flags match the release path; the only difference at release is the
# universal binary + Developer ID identity.
sign: bundle
	@codesign --force --deep \
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
	@mkdir -p "$(RELEASE_APP)/Contents/MacOS" "$(RELEASE_APP)/Contents/Resources" "$(RELEASE_APP)/Contents/Frameworks"
	@cp "$(RELEASE_EXEC)" "$(RELEASE_APP)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(RELEASE_APP)/Contents/Info.plist"
	@plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(RELEASE_APP)/Contents/Info.plist"
	@plutil -replace CFBundleVersion -string "$(VERSION)" "$(RELEASE_APP)/Contents/Info.plist"
	@cp Resources/AppIcon.icns "$(RELEASE_APP)/Contents/Resources/AppIcon.icns"
	@if [ -d "$(RELEASE_DIR)/Sparkle.framework" ]; then \
	    cp -R "$(RELEASE_DIR)/Sparkle.framework" "$(RELEASE_APP)/Contents/Frameworks/"; \
	    install_name_tool -add_rpath "@executable_path/../Frameworks" \
	        "$(RELEASE_APP)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true; \
	fi

release-sign: release-bundle
	@if [ -z "$(RELEASE_IDENTITY)" ]; then \
	    echo "error: no Developer ID Application identity in keychain"; \
	    echo "       run: security find-identity -v -p codesigning"; \
	    exit 1; \
	fi
	@codesign --force --deep \
	    --sign "$(RELEASE_IDENTITY)" \
	    --options runtime \
	    --entitlements $(ENTITLEMENTS) \
	    --timestamp \
	    "$(RELEASE_APP)"
	@codesign -dvv "$(RELEASE_APP)" 2>&1 | grep -E 'Authority|TeamIdentifier|Identifier|flags='
	@echo "  ✓ Signed release at $(RELEASE_APP) with: $(RELEASE_IDENTITY)"

# Submit the signed .app to Apple's notarization service. Requires a
# notarytool keychain profile created via:
#   xcrun notarytool store-credentials lede-notary --apple-id YOU@example.com \
#       --team-id TEAMID --password APP_SPECIFIC_PASSWORD
notarize: release-sign
	@cd $(RELEASE_DIR) && \
	    ditto -c -k --keepParent "$(APP_NAME).app" "$(APP_NAME).zip" && \
	    xcrun notarytool submit "$(APP_NAME).zip" --keychain-profile lede-notary --wait && \
	    xcrun stapler staple "$(APP_NAME).app"

# Bundle the notarized .app into a distributable .dmg with an Applications
# drop-target. Run `make dmg VERSION=0.2.0` to bake the version into the name.
dmg: notarize
	@rm -f "$(DMG)"
	@create-dmg \
	    --volname "Lede" \
	    --volicon "Resources/AppIcon.icns" \
	    --window-size 540 380 \
	    --icon-size 128 \
	    --icon "$(APP_NAME).app" 140 190 \
	    --hide-extension "$(APP_NAME).app" \
	    --app-drop-link 400 190 \
	    "$(DMG)" \
	    "$(RELEASE_APP)"
	@echo "  ✓ Wrote $(DMG)"
	@codesign --sign "$(RELEASE_IDENTITY)" --timestamp "$(DMG)"
	@xcrun notarytool submit "$(DMG)" --keychain-profile lede-notary --wait
	@xcrun stapler staple "$(DMG)"
	@spctl -a -vvv -t open --context context:primary-signature "$(DMG)" 2>&1 | tail -3

clean:
	swift package clean
	rm -rf "$(DEBUG_APP)" "$(RELEASE_APP)"

# Sign the produced .dmg with Sparkle's EdDSA private key (in Keychain) and
# print the appcast attributes you need to paste into docs/appcast.xml.
# Requires `make dmg VERSION=...` to have already run.
sparkle-sign:
	@if [ ! -x "$(SPARKLE_BIN)/sign_update" ]; then \
	    echo "error: $(SPARKLE_BIN)/sign_update missing — run 'swift build' once first"; \
	    exit 1; \
	fi
	@if [ ! -f "$(DMG)" ]; then \
	    echo "error: $(DMG) not found — build it first with 'make dmg VERSION=$(VERSION)'"; \
	    exit 1; \
	fi
	@echo "  ✓ Signing $(DMG) with Sparkle EdDSA key…"
	@echo "  Append this <enclosure> to docs/appcast.xml:"
	@echo
	@$(SPARKLE_BIN)/sign_update "$(DMG)"
	@echo
	@echo "  url should be: https://github.com/kmatzen/lede/releases/download/v$(VERSION)/Lede-$(VERSION).dmg"

# Render PanelView with curated mock data and write a PNG for the website.
# Re-run anytime the panel design changes.
screenshot: build
	@$(DEBUG_EXEC) --screenshot docs/assets/panel.png
	@echo "  Re-run after design changes to refresh the website hero image."

reset-cert:
	@for sha in $$(security find-certificate -a -c "Lede Dev" -Z ~/Library/Keychains/login.keychain-db 2>/dev/null | awk '/SHA-1 hash:/ {print $$3}'); do \
	    echo "  Deleting cert $$sha"; \
	    security delete-certificate -Z "$$sha" ~/Library/Keychains/login.keychain-db 2>&1 | head -1; \
	done
