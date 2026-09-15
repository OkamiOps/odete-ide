SIM ?= iPad Air 11-inch (M4)
OS ?= 26.5
DEST = platform=iOS Simulator,name=$(SIM),OS=$(OS)
DERIVED = build
BUNDLE = com.okamiops.odete

.PHONY: gen build test unit run lint format check clean i18n i18n-limpa

gen:
	xcodegen generate --spec project.yml

build: gen
	xcodebuild -project Odete.xcodeproj -scheme Odete -destination '$(DEST)' -derivedDataPath $(DERIVED) -quiet build

unit:
	@for p in OdeteI18n OdeteCore OdeteFiles OdeteGit OdeteAccounts OdeteRuntime OdeteNpm OdeteBundler OdeteShell OdetePreview OdeteAgent OdeteSwift OdeteUI OdeteApp; do \
	  (cd Packages/$$p && xcodebuild test -scheme $$p -destination '$(DEST)' -derivedDataPath ../../$(DERIVED) 2>&1 | grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)") ; \
	done

test: gen
	xcodebuild -project Odete.xcodeproj -scheme Odete -destination '$(DEST)' -derivedDataPath $(DERIVED) -quiet test

run: build
	xcrun simctl boot "$(SIM)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(SIM)" $(DERIVED)/Build/Products/Debug-iphonesimulator/Odete.app
	xcrun simctl launch "$(SIM)" $(BUNDLE)

# Confere o catálogo de tradução contra o código.
i18n:
	python3 scripts/i18n.py

i18n-limpa:
	python3 scripts/i18n.py --limpa

# Tudo que a CI roda, de uma vez, antes de commitar.
check: lint i18n build unit

lint:
	swiftformat --lint .
	swiftlint --quiet

format:
	swiftformat .

clean:
	rm -rf $(DERIVED) Odete.xcodeproj
