APP_NAME  := Lede
BUNDLE_ID := com.lede.app

BUILD_DIR := .build/debug
EXEC      := $(BUILD_DIR)/$(APP_NAME)
APP       := $(BUILD_DIR)/$(APP_NAME).app

# Resolve the signing identity lazily — picks up your Apple Dev cert if present,
# otherwise falls through to the self-signed "Lede Dev" path.
IDENTITY   = $(shell ./scripts/setup-dev-cert.sh)

.PHONY: all build bundle sign run clean reset-cert

all: run

build:
	swift build

bundle: build
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS"
	@cp "$(EXEC)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(APP)/Contents/Info.plist"

sign: bundle
	@codesign --force --sign "$(IDENTITY)" "$(APP)"
	@echo "  ✓ Signed $(APP) with: $(IDENTITY)"

run: sign
	@killall "$(APP_NAME)" 2>/dev/null || true
	@open "$(APP)"
	@echo "  ✓ Launched Lede"

clean:
	swift package clean
	rm -rf "$(APP)"

# If the Keychain ACL ever gets gunked up (e.g. you added then revoked Apple
# Development), `make reset-cert` wipes the self-signed fallback so the setup
# script recreates it on next build.
reset-cert:
	@for sha in $$(security find-certificate -a -c "Lede Dev" -Z ~/Library/Keychains/login.keychain-db 2>/dev/null | awk '/SHA-1 hash:/ {print $$3}'); do \
	    echo "  Deleting cert $$sha"; \
	    security delete-certificate -Z "$$sha" ~/Library/Keychains/login.keychain-db 2>&1 | head -1; \
	done
