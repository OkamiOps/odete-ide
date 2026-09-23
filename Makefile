SIM ?= iPad Air 11-inch (M4)
OS ?= 26.5
DEST = platform=iOS Simulator,name=$(SIM),OS=$(OS)
DERIVED = build
BUNDLE = com.okamiops.odete

.PHONY: gen build test unit run lint format check clean i18n i18n-limpa archive ipa upload

gen:
	xcodegen generate --spec project.yml

build: gen
	xcodebuild -project Odete.xcodeproj -scheme Odete -destination '$(DEST)' -derivedDataPath $(DERIVED) -quiet build

# Mostra só o resumo de cada pacote, mas falha se algum teste falhar: antes o `grep` no
# fim do pipe engolia o código de saída do xcodebuild e o CI ficava verde com teste vermelho.
unit:
	@falhou=""; for p in OdeteI18n OdeteCore OdeteFiles OdeteEditor OdeteGit OdeteAccounts OdeteRuntime OdeteNpm OdeteBundler OdeteShell OdetePreview OdeteAgent OdeteSwift OdeteUI OdeteApp; do \
	  echo "== $$p"; \
	  saida=$$(cd Packages/$$p && xcodebuild test -scheme $$p -destination '$(DEST)' -derivedDataPath ../../$(DERIVED) 2>&1); st=$$?; \
	  printf '%s\n' "$$saida" | grep -E "error:|✘|Test run with|TEST (SUCCEEDED|FAILED)"; \
	  [ $$st -eq 0 ] || falhou="$$falhou $$p"; \
	done; \
	if [ -n "$$falhou" ]; then echo "falharam:$$falhou"; exit 1; fi

test: gen
	xcodebuild -project Odete.xcodeproj -scheme Odete -destination '$(DEST)' -derivedDataPath $(DERIVED) -quiet test

run: build
	xcrun simctl boot "$(SIM)" 2>/dev/null || true
	open -a Simulator
	xcrun simctl install "$(SIM)" $(DERIVED)/Build/Products/Debug-iphonesimulator/Odete.app
	xcrun simctl launch "$(SIM)" $(BUNDLE)

# Caminho para a App Store. Precisa de uma conta Apple logada no Xcode
# (Settings → Accounts) com o time 7U9S5DB9K9: é ela que cria o App ID
# com.okamiops.odete, o contêiner iCloud e o perfil, no primeiro `make archive`.
ARCHIVE = $(DERIVED)/Odete.xcarchive

archive: gen
	xcodebuild -project Odete.xcodeproj -scheme Odete -configuration Release \
	  -destination 'generic/platform=iOS' -archivePath $(ARCHIVE) \
	  -allowProvisioningUpdates archive

ipa: archive
	rm -rf $(DERIVED)/ipa
	xcodebuild -exportArchive -archivePath $(ARCHIVE) \
	  -exportOptionsPlist ExportOptions.plist -exportPath $(DERIVED)/ipa \
	  -allowProvisioningUpdates
	@echo "ipa em $(DERIVED)/ipa/"

# Sobe para o App Store Connect. A chave fica em ~/.appstoreconnect/private_keys/
# (arquivo AuthKey_XXXX.p8); aqui só passam o id e o issuer, nunca o conteúdo dela.
#   make upload ASC_KEY=XXXXXXXXXX ASC_ISSUER=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
upload:
	@test -n "$(ASC_KEY)" || (echo "falta ASC_KEY (o id da chave do App Store Connect)"; exit 1)
	@test -n "$(ASC_ISSUER)" || (echo "falta ASC_ISSUER (o issuer id)"; exit 1)
	xcrun altool --validate-app -f $(DERIVED)/ipa/Odete.ipa -t ios \
	  --apiKey $(ASC_KEY) --apiIssuer $(ASC_ISSUER)
	xcrun altool --upload-app -f $(DERIVED)/ipa/Odete.ipa -t ios \
	  --apiKey $(ASC_KEY) --apiIssuer $(ASC_ISSUER)

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
