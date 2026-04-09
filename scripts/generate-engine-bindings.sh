#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$ROOT_DIR/engine"
ANDROID_OUT_DIR="$ROOT_DIR/apps/android/app/src/main/java"
SWIFT_OUT_DIR="$ROOT_DIR/apps/macos/Generated/Engine"

cd "$ENGINE_DIR"

cargo build --release -p codex-island-client-ffi

LIB_PATH="$ENGINE_DIR/target/release/libcodex_island_client_ffi.dylib"
if [[ ! -f "$LIB_PATH" ]]; then
    echo "missing UniFFI dynamic library at $LIB_PATH" >&2
    exit 1
fi

mkdir -p "$ANDROID_OUT_DIR" "$SWIFT_OUT_DIR"
rm -rf "$ANDROID_OUT_DIR/uniffi/codex_island_client" "$SWIFT_OUT_DIR"/*

cargo run -p codex-island-client-ffi --bin uniffi-bindgen --features bindgen -- \
    generate \
    --library "$LIB_PATH" \
    --language kotlin \
    --out-dir "$ANDROID_OUT_DIR"

cargo run -p codex-island-client-ffi --bin uniffi-bindgen --features bindgen -- \
    generate \
    --library "$LIB_PATH" \
    --language swift \
    --out-dir "$SWIFT_OUT_DIR"

SWIFT_BINDING_FILE="$SWIFT_OUT_DIR/codex_island_client.swift"
if command -v swiftformat >/dev/null 2>&1 && [[ -f "$SWIFT_BINDING_FILE" ]]; then
    swiftformat "$SWIFT_BINDING_FILE" >/dev/null
fi
