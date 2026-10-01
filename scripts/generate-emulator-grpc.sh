#!/bin/bash
# Regenerates the checked-in Swift client for the trimmed Android Emulator proto.
# Usage: scripts/generate-emulator-grpc.sh [--check]
#   --check  generate into .build/codegen-check and fail when it differs from the checked-in code.
# Needs protoc 35.1 (OFFSIDER_PROTOC overrides the protoc on PATH). Never run by swift build.

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROTOC_VERSION="35.1"
PROTOC="${OFFSIDER_PROTOC:-protoc}"
PROTO_DIR="${REPO_ROOT}/Sources/OffsiderAndroid/Grpc/Proto"
GENERATED_DIR="${REPO_ROOT}/Sources/OffsiderAndroid/Grpc/Generated"
SCRATCH="${REPO_ROOT}/.build/codegen"

MODE="write"
case "${1:-}" in
    "") ;;
    --check) MODE="check" ;;
    *) echo "Usage: $0 [--check]" >&2; exit 64 ;;
esac

PROTOC_PATH="$(command -v "$PROTOC" || true)"
if [ -z "$PROTOC_PATH" ]; then
    echo "Error: protoc not found. Install protoc ${PROTOC_VERSION} or set OFFSIDER_PROTOC." >&2
    exit 1
fi
FOUND_VERSION="$("$PROTOC_PATH" --version)"
if [ "$FOUND_VERSION" != "libprotoc ${PROTOC_VERSION}" ]; then
    echo "Error: ${PROTOC_PATH} is ${FOUND_VERSION}; the generated code is pinned to libprotoc ${PROTOC_VERSION}." >&2
    exit 1
fi
PROTOC_REAL="$(cd "$(dirname "$PROTOC_PATH")" && pwd -P)/$(basename "$PROTOC_PATH")"
if [ -L "$PROTOC_PATH" ]; then
    LINK="$(readlink "$PROTOC_PATH")"
    case "$LINK" in
        /*) PROTOC_REAL="$LINK" ;;
        *) PROTOC_REAL="$(cd "$(dirname "$PROTOC_PATH")/$(dirname "$LINK")" && pwd -P)/$(basename "$LINK")" ;;
    esac
fi
INCLUDE_DIR="$(cd "$(dirname "$PROTOC_REAL")/.." && pwd -P)/include"
if [ ! -f "${INCLUDE_DIR}/google/protobuf/empty.proto" ]; then
    echo "Error: ${INCLUDE_DIR} has no google/protobuf/empty.proto; reinstall protoc ${PROTOC_VERSION}." >&2
    exit 1
fi

echo "Building the protoc plugins from the pinned packages..."
cd "$REPO_ROOT"
swift build -c release --scratch-path "$SCRATCH" --product protoc-gen-swift
swift build -c release --scratch-path "$SCRATCH" --product protoc-gen-grpc-swift-2
BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)"

OUT_DIR="$GENERATED_DIR"
if [ "$MODE" = "check" ]; then
    OUT_DIR="${REPO_ROOT}/.build/codegen-check"
    rm -rf "$OUT_DIR"
fi
mkdir -p "$OUT_DIR"

"$PROTOC_PATH" \
    -I "$PROTO_DIR" \
    -I "$INCLUDE_DIR" \
    --plugin=protoc-gen-swift="${BIN_DIR}/protoc-gen-swift" \
    --swift_out=Visibility=Internal:"$OUT_DIR" \
    --plugin=protoc-gen-grpc-swift-2="${BIN_DIR}/protoc-gen-grpc-swift-2" \
    --grpc-swift-2_out=Visibility=Internal,Client=true,Server=false:"$OUT_DIR" \
    emulator_controller.proto

if [ "$MODE" = "check" ]; then
    if diff -r "$GENERATED_DIR" "$OUT_DIR"; then
        echo "Generated code matches ${GENERATED_DIR}."
    else
        echo "Error: the checked-in generated code differs; run $0 and commit the result." >&2
        exit 1
    fi
else
    echo "Wrote $(ls "$OUT_DIR" | tr '\n' ' ')to ${OUT_DIR}."
fi
