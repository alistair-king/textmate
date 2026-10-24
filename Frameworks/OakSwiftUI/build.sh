#!/bin/bash
# Builds OakSwiftUI dynamic library and copies to TextMate's build directory.
# Usage: ./build.sh [debug|release] [build-dir]
# Incremental: swift build handles caching, only rebuilds changed sources.

set -euo pipefail

CONFIG="${1:-debug}"
CALLER_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve BUILD_DIR relative to caller's CWD, not script location
if [ -n "${2:-}" ]; then
    case "$2" in
        /*) BUILD_DIR="$2" ;;
        *)  BUILD_DIR="${CALLER_DIR}/$2" ;;
    esac
else
    BUILD_DIR="${CALLER_DIR}/build-${CONFIG}"
fi
LIB_DIR="${BUILD_DIR}/lib"

cd "$SCRIPT_DIR"

case "$CONFIG" in
    debug)   SWIFT_CONFIG="debug" ;;
    release) SWIFT_CONFIG="release" ;;
    *)       echo "Usage: $0 [debug|release] [build-dir]"; exit 1 ;;
esac

echo "Building OakSwiftUI ($SWIFT_CONFIG)..."
swift build -c "$SWIFT_CONFIG" --disable-sandbox --product OakSwiftUI 2>&1

DYLIB_PATH=".build/${SWIFT_CONFIG}/libOakSwiftUI.dylib"

if [ ! -f "$DYLIB_PATH" ]; then
    echo "Error: $DYLIB_PATH not found after build"
    exit 1
fi

mkdir -p "$LIB_DIR"
cp "$DYLIB_PATH" "$LIB_DIR/"

# Set install name for @rpath resolution at runtime
install_name_tool -id "@rpath/libOakSwiftUI.dylib" "$LIB_DIR/libOakSwiftUI.dylib"

# Stage the generated ObjC bridging header where CMake expects it
# (.build/<triple>/<config>/OakSwiftUI.build/include). SwiftPM's output
# layout moved between toolchain versions, so locate the header wherever
# this toolchain put it and copy it to the stable path.
STABLE_HDR=".build/arm64-apple-macosx/${SWIFT_CONFIG}/OakSwiftUI.build/include/OakSwiftUI-Swift.h"
for CAND in \
    ".build/out/Intermediates.noindex/OakSwiftUI.build/${SWIFT_CONFIG}"/OakSwiftUI-t.build/Objects-normal/*/OakSwiftUI-Swift.h \
    ".build/out/Intermediates.noindex/GeneratedModuleMaps/OakSwiftUI-Swift.h"
do
    if [ -f "$CAND" ] && [ "$CAND" != "$STABLE_HDR" ]; then
        mkdir -p "$(dirname "$STABLE_HDR")"
        cp "$CAND" "$STABLE_HDR"
        break
    fi
done

if [ ! -f "$STABLE_HDR" ]; then
    echo "Error: generated OakSwiftUI-Swift.h not found after build"
    exit 1
fi

echo "OakSwiftUI built: $LIB_DIR/libOakSwiftUI.dylib"
