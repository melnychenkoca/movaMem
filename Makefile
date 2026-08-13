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

# Release builds ship a universal binary so one download runs on both Apple
# Silicon and Intel. `swift build --arch a --arch b` cannot do this: multi-arch
# routes through Xcode's build system, which is absent under Command Line Tools.
# Two single-triple builds joined with lipo is the equivalent that works.
ARM64_TRIPLE  = arm64-apple-macosx14.0
X86_64_TRIPLE = x86_64-apple-macosx14.0
ARM64_BINARY  = .build/arm64-apple-macosx/release/$(APP_NAME)
X86_64_BINARY = .build/x86_64-apple-macosx/release/$(APP_NAME)
UNIVERSAL_BINARY = .build/universal/$(APP_NAME)

.PHONY: bundle install sign-setup build-universal bundle-universal dist

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

# --- Release ---------------------------------------------------------------
# What CI runs on a version tag. Kept here rather than in the workflow so the
# release build can be reproduced locally with a single command.

build-universal:
	swift build -c release --triple $(ARM64_TRIPLE)
	swift build -c release --triple $(X86_64_TRIPLE)
	mkdir -p $(dir $(UNIVERSAL_BINARY))
	lipo -create -output $(UNIVERSAL_BINARY) $(ARM64_BINARY) $(X86_64_BINARY)
	@echo "Universal binary: $$(lipo -archs $(UNIVERSAL_BINARY))"

bundle-universal: build-universal
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(UNIVERSAL_BINARY) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@# Ad-hoc signing is required, not cosmetic: an unsigned binary will not
	@# execute at all on Apple Silicon. It is not notarization — see README.
	codesign --force --sign - $(APP_BUNDLE)
	codesign --verify --deep --strict $(APP_BUNDLE)
	@echo "Built universal $(APP_BUNDLE)"

# ditto, not zip: plain zip does not preserve the bundle structure and metadata
# that the code signature is computed over, so the signature fails after a
# download-and-unpack round trip.
dist: bundle-universal
	rm -f $(APP_NAME).zip
	ditto -c -k --keepParent $(APP_BUNDLE) $(APP_NAME).zip
	@echo "Created $(APP_NAME).zip"
	@shasum -a 256 $(APP_NAME).zip

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
