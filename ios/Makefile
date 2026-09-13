SIM ?= iPad Air 11-inch (M4)
OS ?= 26.5
DEST = platform=iOS Simulator,name=$(SIM),OS=$(OS)
DERIVED = build
BUNDLE = com.okamiops.odete

.PHONY: gen build test unit run lint format clean

gen:
	xcodegen generate --spec project.yml

build: gen
	xcodebuild -project Odete.xcodeproj -scheme Odete -destination '$(DEST)' -derivedDataPath $(DERIVED) -quiet build

unit:
	cd Packages/OdeteCore && swift test 2>&1 | tail -20
	cd Packages/OdeteFiles && swift test 2>&1 | tail -20

test: gen
	xcodebuild -project Odete.xcodeproj -scheme Odete -destination '$(DEST)' -derivedDataPath $(DERIVED) -quiet test

run: build
	xcrun simctl boot "$(SIM)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(SIM)" $(DERIVED)/Build/Products/Debug-iphonesimulator/Odete.app
	xcrun simctl launch "$(SIM)" $(BUNDLE)

lint:
	swiftformat --lint .
	swiftlint --quiet

format:
	swiftformat .

clean:
	rm -rf $(DERIVED) Odete.xcodeproj
