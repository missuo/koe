.PHONY: build build-rust build-xcode build-x86_64 generate clean run

ARCH := aarch64-apple-darwin
XCODE_ARCH := arm64

build: generate build-rust build-xcode

build-x86_64: generate
	cd KoeApp && xcodebuild -project Koe.xcodeproj -scheme Koe-x86 -configuration Release ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build

generate:
	cd KoeApp && xcodegen generate

build-rust:
	cargo build --manifest-path koe-core/Cargo.toml --release --target $(ARCH)

build-xcode:
	cd KoeApp && xcodebuild -project Koe.xcodeproj -scheme Koe -configuration Release ARCHS=$(XCODE_ARCH) build

clean:
	cargo clean
	cd KoeApp && xcodebuild -project Koe.xcodeproj -scheme Koe clean

run:
	open "$$(xcodebuild -project KoeApp/Koe.xcodeproj -scheme Koe -configuration Debug -showBuildSettings 2>/dev/null | grep ' BUILD_DIR' | head -1 | awk '{print $$3}')/Debug/Koe.app"
