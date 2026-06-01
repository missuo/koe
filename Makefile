.PHONY: build build-lite build-rust build-xcode build-x86_64 generate clean run install-cli install-app

ARCH := aarch64-apple-darwin
XCODE_ARCH := arm64

build: generate build-rust build-xcode install-cli

build-lite:
	cd KoeApp && xcodegen generate --spec project-lite.yml
	cd KoeApp && xcodebuild -project Koe.xcodeproj -scheme Koe-lite -configuration Release ARCHS=arm64 build

build-x86_64: generate
	cd KoeApp && xcodebuild -project Koe.xcodeproj -scheme Koe-x86 -configuration Release ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build

generate:
	cd KoeApp && xcodegen generate

build-rust:
	cargo build --manifest-path koe-core/Cargo.toml --release --target $(ARCH)
	cargo build --package koe-cli --release --target $(ARCH)

build-xcode:
	cd KoeApp && xcodebuild -project Koe.xcodeproj -scheme Koe -configuration Release ARCHS=$(XCODE_ARCH) build

install-cli:
	@APP_ROOT=$$(xcodebuild -project KoeApp/Koe.xcodeproj -scheme Koe -configuration Release -showBuildSettings 2>/dev/null | grep ' TARGET_BUILD_DIR' | head -1 | awk '{print $$3}')/Koe.app; \
	APP_DIR="$$APP_ROOT/Contents/MacOS"; \
	cp target/$(ARCH)/release/koe "$$APP_DIR/koe-cli"; \
	chmod +x "$$APP_DIR/koe-cli"; \
	codesign --force --deep --sign - "$$APP_ROOT"; \
	codesign --verify --deep --strict --verbose=2 "$$APP_ROOT"; \
	echo "Installed koe-cli into $$APP_DIR and re-signed $$APP_ROOT"

install-app:
	@SCHEME=Koe; \
	if ! xcodebuild -project KoeApp/Koe.xcodeproj -list 2>/dev/null | grep -qx '[[:space:]]*Koe'; then \
		if xcodebuild -project KoeApp/Koe.xcodeproj -list 2>/dev/null | grep -qx '[[:space:]]*Koe-lite'; then \
			SCHEME=Koe-lite; \
		fi; \
	fi; \
	APP_ROOT=$$(xcodebuild -project KoeApp/Koe.xcodeproj -scheme "$$SCHEME" -configuration Release -showBuildSettings 2>/dev/null | grep ' TARGET_BUILD_DIR' | head -1 | awk '{print $$3}')/Koe.app; \
	if [ ! -d "$$APP_ROOT" ]; then \
		echo "Release app not found at $$APP_ROOT. Run 'make build' or 'make build-lite' first."; \
		exit 1; \
	fi; \
	codesign --verify --deep --strict --verbose=2 "$$APP_ROOT"; \
	rm -rf "/Applications/Koe.app"; \
	ditto "$$APP_ROOT" "/Applications/Koe.app"; \
	codesign --verify --deep --strict --verbose=2 "/Applications/Koe.app"; \
	echo "Installed /Applications/Koe.app from $$SCHEME"

clean:
	cargo clean
	cd KoeApp && xcodebuild -project Koe.xcodeproj -scheme Koe clean

run:
	open "$$(xcodebuild -project KoeApp/Koe.xcodeproj -scheme Koe -configuration Debug -showBuildSettings 2>/dev/null | grep ' BUILD_DIR' | head -1 | awk '{print $$3}')/Debug/Koe.app"
