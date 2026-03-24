.PHONY: build build-arm64 build-x64 clean
.PHONY: build-rust-arm64 build-rust-x64
.PHONY: build-cmake-arm64 build-cmake-x64

build: build-arm64 build-x64

# ARM64
build-arm64: build-rust-arm64 build-cmake-arm64
build-rust-arm64:
	cargo build --manifest-path ../koe-core/Cargo.toml --release --target aarch64-pc-windows-msvc
build-cmake-arm64:
	cmake -B build-arm64 -S . -G "Visual Studio 17 2022" -A ARM64
	cmake --build build-arm64 --config Release

# x64
build-x64: build-rust-x64 build-cmake-x64
build-rust-x64:
	cargo build --manifest-path ../koe-core/Cargo.toml --release --target x86_64-pc-windows-msvc
build-cmake-x64:
	cmake -B build-x64 -S . -G "Visual Studio 17 2022" -A x64
	cmake --build build-x64 --config Release

clean:
	rm -rf build-arm64 build-x64
