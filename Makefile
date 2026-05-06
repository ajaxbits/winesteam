# Build targets for WineSteam
# Requires: Xcode command line tools (swiftc), mingw-w64 (x86_64-w64-mingw32-gcc)

PREFIX ?= $(HOME)/Library/Application Support/WineSteam
CEF_DIR = $(PREFIX)/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64

# Bundle paths
BUNDLE = dist/WineSteam.app
BUNDLE_CONTENTS = $(BUNDLE)/Contents
BUNDLE_MACOS = $(BUNDLE_CONTENTS)/MacOS
BUNDLE_RESOURCES = $(BUNDLE_CONTENTS)/Resources

.PHONY: all wrapper launcher clean install-wrapper bundle release bundle-clean

all: wrapper launcher

# ── Developer targets (git-clone workflow) ────────────────────────────

# Windows PE wrapper for steamwebhelper (requires mingw-w64)
# Install mingw-w64: brew install mingw-w64
wrapper: steamwebhelper_wrapper.exe

steamwebhelper_wrapper.exe: webhelper_wrapper.c
	x86_64-w64-mingw32-gcc -O2 -o $@ $<

# Native macOS launcher (optional for dev — the dev app uses the shell script)
launcher: WineSteam.app/Contents/MacOS/WineSteamLauncher

WineSteam.app/Contents/MacOS/WineSteamLauncher: WineSteamLauncher.swift
	swiftc -O -o $@ $<
	codesign --force --deep -s - WineSteam.app

# Copy the webhelper wrapper into the Wine prefix
install-wrapper: steamwebhelper_wrapper.exe
	@if [ ! -f "$(CEF_DIR)/steamwebhelper.exe" ]; then \
		echo "Error: Steam not installed in prefix yet. Run launch-steam.sh first."; \
		exit 1; \
	fi
	@if [ ! -f "$(CEF_DIR)/steamwebhelper_real.exe" ]; then \
		cp "$(CEF_DIR)/steamwebhelper.exe" "$(CEF_DIR)/steamwebhelper_real.exe"; \
	fi
	cp steamwebhelper_wrapper.exe "$(CEF_DIR)/steamwebhelper.exe"
	@echo "Wrapper installed."

# ── Distribution targets (self-contained .app) ───────────────────────

bundle: wrapper
	@echo "Assembling WineSteam.app..."
	rm -rf dist/
	mkdir -p "$(BUNDLE_MACOS)" "$(BUNDLE_RESOURCES)"
	# Compile Swift launcher
	swiftc -O -o "$(BUNDLE_MACOS)/WineSteamLauncher" WineSteamLauncher.swift
	# Info.plist (patched for bundle: use WineSteamLauncher, add LSUIElement)
	/usr/libexec/PlistBuddy -c "Copy :CFBundleName CFBundleName" /dev/null 2>/dev/null || true
	cp WineSteam.app/Contents/Info.plist "$(BUNDLE_CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable WineSteamLauncher" "$(BUNDLE_CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$(BUNDLE_CONTENTS)/Info.plist" 2>/dev/null || \
		/usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$(BUNDLE_CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :NSAppleEventsUsageDescription string 'WineSteam needs to dismiss Steam error dialogs automatically.'" "$(BUNDLE_CONTENTS)/Info.plist" 2>/dev/null || true
	# Copy icon (if available)
	@if [ -f WineSteam.app/Contents/Resources/AppIcon.icns ]; then \
		cp WineSteam.app/Contents/Resources/AppIcon.icns "$(BUNDLE_RESOURCES)/"; \
	fi
	# Copy runtime resources
	cp launch-steam.sh "$(BUNDLE_RESOURCES)/"
	cp setup.sh "$(BUNDLE_RESOURCES)/"
	cp dismiss-dialogs.sh "$(BUNDLE_RESOURCES)/"
	cp steamwebhelper_wrapper.exe "$(BUNDLE_RESOURCES)/"
	chmod +x "$(BUNDLE_RESOURCES)"/*.sh
	# Ad-hoc code sign
	codesign --force --deep -s - "$(BUNDLE)"
	@echo ""
	@echo "Bundle ready at dist/WineSteam.app"
	@echo "Test with: open dist/WineSteam.app"

release: bundle
	cd dist && zip -r WineSteam.zip WineSteam.app
	@echo "Release archive: dist/WineSteam.zip"

# ── Cleanup ───────────────────────────────────────────────────────────

clean:
	rm -f steamwebhelper_wrapper.exe
	rm -f WineSteam.app/Contents/MacOS/WineSteamLauncher

bundle-clean:
	rm -rf dist/
