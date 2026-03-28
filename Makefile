.PHONY: build test run app run-app deploy clean

BUNDLE_NAME = ClaudeBoard.app
BUNDLE_DIR = build/$(BUNDLE_NAME)
BUNDLE_ID = com.ciro.claudeboard
VERSION ?= 0.1.1
CONFIG ?= debug
SIGN_IDENTITY ?= Apple Development: ciro.guariglia@gmail.com (55TC9DYT4L)
ARCH := $(shell uname -m)
BUILD_DIR = .build/$(ARCH)-apple-macosx/$(CONFIG)

build:
	swift build

test:
	swift test

run:
	swift run ClaudeBoard

app: build
	@mkdir -p $(BUNDLE_DIR)/Contents/MacOS
	@mkdir -p $(BUNDLE_DIR)/Contents/Resources
	@cp $(BUILD_DIR)/ClaudeBoard $(BUNDLE_DIR)/Contents/MacOS/ClaudeBoard
	@# Active session marker app (detected by Amphetamine etc.)
	@mkdir -p $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app/Contents/MacOS
	@cp $(BUILD_DIR)/kanban-code-active-session $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app/Contents/MacOS/kanban-code-active-session
	@/bin/echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>kanban-code-active-session</string><key>CFBundleIdentifier</key><string>com.kanban-code.active-session</string><key>CFBundleName</key><string>kanban-code-active-session</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>$(VERSION)</string><key>LSUIElement</key><true/></dict></plist>' > $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app/Contents/Info.plist
	@codesign --force --sign "$(SIGN_IDENTITY)" $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app
	@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f $(BUNDLE_DIR)/Contents/Helpers/kanban-code-active-session.app 2>/dev/null || true
	@cp Sources/ClaudeBoard/Resources/AppIcon.icns $(BUNDLE_DIR)/Contents/Resources/AppIcon.icns
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<plist version="1.0"><dict>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleExecutable</key><string>ClaudeBoard</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleName</key><string>ClaudeBoard</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleVersion</key><string>$(VERSION)</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleShortVersionString</key><string>$(VERSION)</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundlePackageType</key><string>APPL</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>LSMinimumSystemVersion</key><string>14.0</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>NSHighResolutionCapable</key><true/>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>LSUIElement</key><false/>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleIconFile</key><string>AppIcon</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleIconName</key><string>AppIcon</string>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.kanban-code</string><key>CFBundleURLSchemes</key><array><string>kanbancode</string></array></dict></array>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@echo '</dict></plist>' >> $(BUNDLE_DIR)/Contents/Info.plist
	@# Copy SPM bundle resources
	@if [ -d $(BUILD_DIR)/ClaudeBoard_ClaudeBoard.bundle ]; then \
		cp -R $(BUILD_DIR)/ClaudeBoard_ClaudeBoard.bundle $(BUNDLE_DIR)/Contents/Resources/; \
	fi
	@# Code sign with Developer ID so macOS remembers permissions
	@codesign --force --sign "$(SIGN_IDENTITY)" $(BUNDLE_DIR)
	@# Register with Launch Services so macOS picks up the icon
	@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f $(BUNDLE_DIR) 2>/dev/null || true
	@echo "Built $(BUNDLE_DIR)"

run-app: app
	open $(BUNDLE_DIR)

deploy: app
	@echo "Stopping ClaudeBoard..."
	@pkill -x ClaudeBoard 2>/dev/null; sleep 1
	@echo "Deploying to /Applications..."
	@rm -rf /Applications/$(BUNDLE_NAME)
	@cp -R $(BUNDLE_DIR) /Applications/$(BUNDLE_NAME)
	@echo "Registering with Launch Services..."
	@/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/$(BUNDLE_NAME) 2>/dev/null || true
	@echo "Launching /Applications/$(BUNDLE_NAME)..."
	@open /Applications/$(BUNDLE_NAME)
	@echo "Deployed and running from /Applications."

clean:
	swift package clean
	rm -rf build
