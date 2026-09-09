APP      := Kajo
BUNDLE   := $(APP).app
EXEC     := $(BUNDLE)/Contents/MacOS/$(APP)
PLIST    := $(BUNDLE)/Contents/Info.plist
LSREG    := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SIGN_ID  ?= Kajo Self-Signed
DEV_APP  := Kajo Dev.app

.PHONY: build run install reload dev check clean distclean

# Sign every build with a stable self-signed identity so macOS TCC grants
# (Spotify automation, Bluetooth, Location) persist across rebuilds.
build: $(EXEC) $(PLIST)
	@mkdir -p $(BUNDLE)/Contents/Resources && cp assets/Kajo.icns $(BUNDLE)/Contents/Resources/Kajo.icns
	@codesign --force --sign "$(SIGN_ID)" $(BUNDLE) && echo "[codesign] $(BUNDLE) signed with '$(SIGN_ID)'"

# Build via SwiftPM (Package.swift): deployment target = platforms .macOS(.v14), language
# mode = Swift 5 (swiftLanguageVersions). SwiftTerm (terminal window) is the only dependency;
# first build fetches + compiles it once (~1 min), later builds are incremental in .build/.
SWIFT_BUILD := swift build

$(EXEC): Sources/*.swift Package.swift
	$(SWIFT_BUILD) -c release
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@cp .build/release/Kajo $(EXEC)

$(PLIST): Info.plist
	@mkdir -p $(BUNDLE)/Contents
	cp Info.plist $(PLIST)
	# NB: do NOT lsregister the repo bundle here — only `install` registers the
	# /Applications copy for kajo://. Otherwise the repo build also claims the
	# scheme and can shadow the live app → duplicate instances (the Lumo trap).

# Build, kill any running instance, relaunch (registers URL scheme too).
run: build
	@killall $(APP) 2>/dev/null || true
	@open $(BUNDLE)
	@echo "Kajo running. Try:  open 'kajo://tab/music'"

# Rebuild + relaunch in one step during development.
reload: run

# Replace the bundle whole (cp -R over a running app swaps the Mach-O under it →
# "Code Signature Invalid"), then relaunch so you're actually running the new build.
install: build
	@rm -rf /Applications/$(BUNDLE)
	@cp -R $(BUNDLE) /Applications/
	@$(LSREG) -f /Applications/$(BUNDLE) 2>/dev/null || true
	@killall $(APP) 2>/dev/null || true
	@open /Applications/$(BUNDLE)
	@echo "Installed + relaunched /Applications/$(BUNDLE)"

# Parallel dev build: separate bundle id / exec / URL scheme / config dir so it
# runs alongside the installed daily driver without clobbering it. No LaunchAgent.
dev:
	@mkdir -p "$(DEV_APP)/Contents/MacOS" "$(DEV_APP)/Contents/Resources"
	$(SWIFT_BUILD) -c debug          # debug config defines DEBUG
	@cp .build/debug/Kajo "$(DEV_APP)/Contents/MacOS/Kajo Dev"
	@cp assets/Kajo.icns "$(DEV_APP)/Contents/Resources/Kajo.icns"
	@sed -e 's#<string>Kajo</string>#<string>Kajo Dev</string>#g' \
	     -e 's#fi\.mangusti\.kajo#fi.mangusti.kajo.dev#g' \
	     -e 's#<string>kajo</string>#<string>kajodev</string>#g' \
	     Info.plist > "$(DEV_APP)/Contents/Info.plist"
	@codesign --force --sign "$(SIGN_ID)" "$(DEV_APP)"
	@$(LSREG) -f "$(DEV_APP)" 2>/dev/null || true
	@killall "Kajo Dev" 2>/dev/null || true
	@open "$(DEV_APP)"
	@echo "Kajo Dev running — bundle fi.mangusti.kajo.dev · scheme kajodev:// · config ~/.config/kajo-dev/"

# Headless self-check: a -DDEBUG binary runs the asserts, then exits via --clean-url.
check:
	$(SWIFT_BUILD) -c debug
	@.build/debug/Kajo --clean-url "https://example.com/?utm_source=x" >/dev/null && echo "check OK"

clean:
	@rm -rf $(BUNDLE) "$(DEV_APP)" .check
	@echo "cleaned (SwiftPM cache in .build/ kept; \`make distclean\` removes it)"

distclean: clean
	@rm -rf .build
	@echo "removed .build/"
