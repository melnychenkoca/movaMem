# Swift Testing ships inside Command Line Tools but is not on any default search
# path. -F finds the framework at compile time; the two -rpath flags let dyld find
# the framework and its interop dylib at run time. Without all three, `swift test`
# fails either with "no such module 'Testing'" or a dyld load error.
TESTING_FW  = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TESTING_LIB = /Library/Developer/CommandLineTools/Library/Developer/usr/lib

TEST_FLAGS = -Xswiftc -F -Xswiftc $(TESTING_FW) \
             -Xlinker -rpath -Xlinker $(TESTING_FW) \
             -Xlinker -rpath -Xlinker $(TESTING_LIB)

.PHONY: test build clean

test:
	swift test $(TEST_FLAGS)

build:
	swift build -c release

clean:
	rm -rf .build movaMem.app

APP_NAME   = movaMem
APP_BUNDLE = $(APP_NAME).app
BINARY     = .build/release/$(APP_NAME)

.PHONY: bundle install sign-setup

# Assembles the .app directory structure by hand, which is what Xcode would
# otherwise do for us.
bundle: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BINARY) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@# Sign with the local certificate if it exists, otherwise ad-hoc sign.
	@# Ad-hoc works fine but its identity changes every build.
	@if security find-certificate -c "movaMem Local" >/dev/null 2>&1; then \
		echo "Signing with movaMem Local certificate"; \
		codesign --force --sign "movaMem Local" $(APP_BUNDLE); \
	else \
		echo "No local certificate found; ad-hoc signing"; \
		codesign --force --sign - $(APP_BUNDLE); \
	fi
	@echo "Built $(APP_BUNDLE)"

install: bundle
	rm -rf /Applications/$(APP_BUNDLE)
	cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"

# One-time setup for a stable code signature. Not required — ad-hoc signing works
# — but a stable identity keeps Gatekeeper quiet across rebuilds.
sign-setup:
	@echo "Create a self-signed certificate named exactly: movaMem Local"
	@echo ""
	@echo "  1. Open Keychain Access"
	@echo "  2. Menu: Keychain Access > Certificate Assistant > Create a Certificate..."
	@echo "  3. Name: movaMem Local"
	@echo "  4. Identity Type: Self Signed Root"
	@echo "  5. Certificate Type: Code Signing"
	@echo "  6. Create, then re-run 'make bundle'"
