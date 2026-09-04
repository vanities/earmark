SCHEME   = Earmark
PROJECT  = Earmark.xcodeproj
SIM     ?= iPhone Air
DEST     = platform=iOS Simulator,name=$(SIM)

.PHONY: gen build test run lint fixtures install-fixtures icon clean archive upload testflight bump

gen:            ## Regenerate Earmark.xcodeproj from project.yml
	xcodegen generate

build: gen      ## Build for the simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' build | tail -20

test: gen       ## Run unit tests on the simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' test | tail -40

run: gen        ## Build, install, and launch on the simulator (uses xcodebuildmcp)
	xcodebuildmcp simulator build-and-run --project-path $(PROJECT) --scheme $(SCHEME) --simulator-name "$(SIM)"

lint:           ## SwiftLint
	swiftlint lint --quiet

fixtures:       ## Generate sample audiobooks (real speech via `say`) into ./fixtures
	scripts/make-fixtures.sh

install-fixtures: ## Copy fixtures into the booted simulator's "On My iPhone › Earmark"
	scripts/install-fixtures.sh

icon:           ## Re-render the app icon
	swift scripts/render-icon.swift Earmark/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png

clean:
	rm -rf build DerivedData

# ---------------------------------------------------------------------------
# TestFlight. Needs .env.appstore-connect (see .env.appstore-connect.example) and
# Config/Signing.xcconfig with your DEVELOPMENT_TEAM. Build numbers are managed by
# App Store Connect (manageAppVersionAndBuildNumber in ExportOptions.plist).
# ---------------------------------------------------------------------------
-include .env.appstore-connect
export
ARCHIVE = build/Earmark.xcarchive
# Only pass API-key auth when configured; otherwise xcodebuild uses the Apple ID signed into Xcode.
ASC_AUTH = $(if $(APPSTORE_CONNECT_KEY_ID),-authenticationKeyPath "$(abspath $(APPSTORE_CONNECT_KEY_FILE))" -authenticationKeyID "$(APPSTORE_CONNECT_KEY_ID)" -authenticationKeyIssuerID "$(APPSTORE_CONNECT_ISSUER_ID)",)

archive: gen    ## Release archive for iOS devices
	xcodebuild archive -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	  -destination 'generic/platform=iOS' -archivePath $(ARCHIVE) \
	  -allowProvisioningUpdates $(ASC_AUTH) | tail -20

# System PATH only: Xcode's IPA step runs Apple's rsync with -E, which breaks if Homebrew's rsync is found first.
upload:         ## Sign for App Store Connect and upload the archive (TestFlight)
	PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportOptionsPlist ExportOptions.plist \
	  -exportPath build/export -allowProvisioningUpdates $(ASC_AUTH) | tail -20

testflight: archive upload ## Archive + upload in one go
	@echo "Uploaded. Processing takes a few minutes; then: uv run --script scripts/testflight.py status"

bump:           ## Bump the marketing version, e.g. make bump V=0.2.0
	@test -n "$(V)" || (echo "usage: make bump V=0.2.0" && exit 1)
	sed -i '' 's/MARKETING_VERSION: .*/MARKETING_VERSION: $(V)/' project.yml && xcodegen generate
