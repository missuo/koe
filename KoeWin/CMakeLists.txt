cmake_minimum_required(VERSION 3.20)
project(Koe LANGUAGES CXX C)
set(CMAKE_CXX_STANDARD 17)

# Determine Rust target from the -A flag (CMAKE_GENERATOR_PLATFORM)
# CMAKE_SYSTEM_PROCESSOR always reflects the host, not the target
if(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64")
    set(RUST_TARGET "aarch64-pc-windows-msvc")
else()
    set(RUST_TARGET "x86_64-pc-windows-msvc")
endif()

# Rust lib is built to workspace root target/, header is in koe-core/target/
set(RUST_LIB_DIR "${CMAKE_SOURCE_DIR}/../target/${RUST_TARGET}/release")
set(RUST_INCLUDE_DIR "${CMAKE_SOURCE_DIR}/../koe-core/target")

# SQLite amalgamation (compiled as C)
add_library(sqlite3 STATIC src/sqlite3.c)
target_compile_definitions(sqlite3 PRIVATE SQLITE_THREADSAFE=1)

add_executable(Koe WIN32
    src/main.cpp
    src/app.cpp
    src/bridge.cpp
    src/audio.cpp
    src/hotkey.cpp
    src/clipboard.cpp
    src/paste.cpp
    src/cue.cpp
    src/tray.cpp
    src/overlay.cpp
    src/history.cpp
)

target_include_directories(Koe PRIVATE
    ${RUST_INCLUDE_DIR}
    src
)

# Rust static library + its runtime deps + Windows APIs
target_link_libraries(Koe PRIVATE
    ${RUST_LIB_DIR}/koe_core.lib
    sqlite3
    ws2_32          # Winsock (tokio networking)
    userenv         # Rust stdlib
    bcrypt          # ring crypto
    ntdll           # Rust stdlib
    advapi32        # Registry, security
    crypt32         # Certificates (rustls)
    ole32           # COM (WASAPI)
    winmm           # PlaySound
    gdiplus         # GDI+ (icons, overlay)
    shell32         # Shell_NotifyIcon, ShellExecute
)

target_compile_options(Koe PRIVATE /utf-8)
