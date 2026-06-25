APP      := Kajo
BUNDLE   := $(APP).app
EXEC     := $(BUNDLE)/Contents/MacOS/$(APP)
PLIST    := $(BUNDLE)/Contents/Info.plist
LSREG    := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SIGN_ID  := Lumo Self-Signed
DEV_APP  := Kajo Dev.app

.PHONY: build run install reload dev clean

# Sign every build with a stable self-signed identity so macOS TCC grants
# (Spotify automation, Bluetooth, Location) persist across rebuilds.
build: $(EXEC) $(PLIST)
	@mkdir -p $(BUNDLE)/Contents/Resources && cp assets/Kajo.icns $(BUNDLE)/Contents/Resources/Kajo.icns
	@codesign --force --sign "$(SIGN_ID)" $(BUNDLE) && echo "[codesign] $(BUNDLE) signed with '$(SIGN_ID)'"

$(EXEC): Sources/*.swift
	@mkdir -p $(BUNDLE)/Contents/MacOS
	swiftc -O -swift-version 5 Sources/*.swift -o $(EXEC)

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

install: build
	@cp -R $(BUNDLE) /Applications/
	@$(LSREG) -f /Applications/$(BUNDLE) 2>/dev/null || true
	@echo "Installed to /Applications/$(BUNDLE)"

# Parallel dev build: separate bundle id / exec / URL scheme / config dir so it
# runs alongside the installed daily driver without clobbering it. No LaunchAgent.
dev:
	@mkdir -p "$(DEV_APP)/Contents/MacOS"
	swiftc -O -swift-version 5 Sources/*.swift -o "$(DEV_APP)/Contents/MacOS/Kajo Dev"
	@sed -e 's#<string>Kajo</string>#<string>Kajo Dev</string>#g' \
	     -e 's#fi\.mangusti\.kajo#fi.mangusti.kajo.dev#g' \
	     -e 's#<string>kajo</string>#<string>kajodev</string>#g' \
	     Info.plist > "$(DEV_APP)/Contents/Info.plist"
	@codesign --force --sign "$(SIGN_ID)" "$(DEV_APP)"
	@$(LSREG) -f "$(DEV_APP)" 2>/dev/null || true
	@killall "Kajo Dev" 2>/dev/null || true
	@open "$(DEV_APP)"
	@echo "Kajo Dev running — bundle fi.mangusti.kajo.dev · scheme kajodev:// · config ~/.config/kajo-dev/"

clean:
	@rm -rf $(BUNDLE) "$(DEV_APP)"
	@echo "cleaned"
