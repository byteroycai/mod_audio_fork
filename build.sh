#!/usr/bin/env bash
#
# Convenience wrapper around CMake for mod_audio_fork.
#
# Subcommands:
#   build    Configure and build (default).
#   install  Install the built module to ${FREESWITCH_MOD_DIR}.
#   clean    Remove the build directory.
#
# Override via environment:
#   BUILD_DIR             Build directory.            Default: build
#   BUILD_TYPE            CMake build type.           Default: Release
#   FREESWITCH_MOD_DIR    Module install destination. Default: /usr/local/freeswitch/mod
#   FREESWITCH_INCLUDE_DIR / FREESWITCH_LIBRARY  Forwarded to CMake if set.

set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR="${BUILD_DIR:-build}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
FREESWITCH_MOD_DIR="${FREESWITCH_MOD_DIR:-/usr/local/freeswitch/mod}"

cmd="${1:-build}"

cmake_args=(
    -S .
    -B "$BUILD_DIR"
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    -DFREESWITCH_MOD_DIR="$FREESWITCH_MOD_DIR"
)
[[ -n "${FREESWITCH_INCLUDE_DIR:-}" ]] && cmake_args+=(-DFREESWITCH_INCLUDE_DIR="$FREESWITCH_INCLUDE_DIR")
[[ -n "${FREESWITCH_LIBRARY:-}"     ]] && cmake_args+=(-DFREESWITCH_LIBRARY="$FREESWITCH_LIBRARY")

case "$cmd" in
    build)
        cmake "${cmake_args[@]}"
        cmake --build "$BUILD_DIR" --parallel
        ;;
    install)
        if [[ ! -d "$BUILD_DIR" ]]; then
            echo "No build directory yet — running build first."
            "$0" build
        fi
        cmake --install "$BUILD_DIR"
        ;;
    clean)
        rm -rf "$BUILD_DIR"
        ;;
    *)
        echo "Usage: $0 [build|install|clean]" >&2
        exit 1
        ;;
esac
