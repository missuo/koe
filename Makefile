.PHONY: build build-mlx build-rust build-xcode generate clean run install-cli install-app

ARCH := aarch64-apple-darwin
XCODE_ARCH := arm64

build: generate build-rust build-xcode install-cli

build-mlx: generate
	cd KoeApp && xcodebuild -project Koe.xcodeproj -scheme Koe-MLX -configuration Release -skipPackagePluginValidation -skipMacroValidation ARCHS=$(XCODE_ARCH) build

generate:
	cd KoeApp && xcodegen generate

build-rust:
	cargo build --manifest-path koe-core/Cargo.toml --release --target $(ARCH) --no-default-features --features "apple-speech"
	cargo build --package koe-cli --release --target $(ARCH)

build-xcode:
	cd KoeApp && xcodebuild -project Koe.xcodeproj -scheme Koe -configuration Release -skipPackagePluginValidation -skipMacroValidation ARCHS=$(XCODE_ARCH) build

install-cli:
	@APP_ROOT=$$(xcodebuild -project KoeApp/Koe.xcodeproj -scheme Koe -configuration Release -showBuildSettings 2>/dev/null | grep ' TARGET_BUILD_DIR' | head -1 | awk '{print $$3}')/Koe.app; \
	APP_DIR="$$APP_ROOT/Contents/MacOS"; \
	cp target/$(ARCH)/release/koe "$$APP_DIR/koe-cli"; \
	chmod +x "$$APP_DIR/koe-cli"; \
	ENT="KoeApp/Koe/Koe.entitlements"; \
	if security find-identity -p codesigning -v 2>/dev/null | grep -q "Koe Dev"; then \
		echo "Signing with stable identity 'Koe Dev' (Hardened Runtime — TCC permissions survive upgrades)"; \
		codesign --force --deep --sign "Koe Dev" --options runtime --entitlements "$$ENT" --timestamp=none "$$APP_ROOT"; \
	else \
		echo "No 'Koe Dev' identity in keychain — ad-hoc signing (TCC re-prompts every build; run scripts/setup-codesign-identity.sh once to fix)"; \
		codesign --force --deep --sign - "$$APP_ROOT"; \
	fi; \
	codesign --verify --deep --strict --verbose=2 "$$APP_ROOT"; \
	echo "Installed koe-cli into $$APP_DIR and re-signed $$APP_ROOT"

install-app:
	@APP_ROOT=$$(xcodebuild -project KoeApp/Koe.xcodeproj -scheme Koe -configuration Release -showBuildSettings 2>/dev/null | grep ' TARGET_BUILD_DIR' | head -1 | awk '{print $$3}')/Koe.app; \
	if [ ! -d "$$APP_ROOT" ]; then \
		echo "Release app not found at $$APP_ROOT. Run 'make build' or 'make build-mlx' first."; \
		exit 1; \
	fi; \
	codesign --verify --deep --strict --verbose=2 "$$APP_ROOT"; \
	rm -rf "/Applications/Koe.app"; \
	ditto "$$APP_ROOT" "/Applications/Koe.app"; \
	codesign --verify --deep --strict --verbose=2 "/Applications/Koe.app"; \
	echo "Installed /Applications/Koe.app from $$APP_ROOT"

clean:
	cargo clean
	cd KoeApp && xcodebuild -project Koe.xcodeproj -scheme Koe clean

run:
	open "$$(xcodebuild -project KoeApp/Koe.xcodeproj -scheme Koe -configuration Debug -showBuildSettings 2>/dev/null | grep ' BUILD_DIR' | head -1 | awk '{print $$3}')/Debug/Koe.app"
