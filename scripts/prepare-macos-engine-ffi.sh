#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$ROOT_DIR/engine"
GENERATED_DIR="$ROOT_DIR/apps/macos/Generated/Engine"
OUT_DIR="${1:-}"
USER_HOME="${HOME:-$(eval echo "~$(id -un)")}"

ensure_rust_toolchain() {
    if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
        return 0
    fi

    if [[ -r "$USER_HOME/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "$USER_HOME/.cargo/env"
    fi

    if [[ -d "$USER_HOME/.cargo/bin" ]]; then
        export PATH="$USER_HOME/.cargo/bin:$PATH"
    fi

    if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
        return 0
    fi

    echo "Rust toolchain not found. Install Rust with rustup or ensure cargo/rustc are on PATH for Xcode build scripts." >&2
    echo "Checked PATH=$PATH" >&2
    echo "Expected rustup env at $USER_HOME/.cargo/env" >&2
    exit 127
}

if [[ -z "$OUT_DIR" ]]; then
    echo "usage: $0 <frameworks-output-dir>" >&2
    exit 1
fi

ensure_rust_toolchain

cd "$ENGINE_DIR"

cargo build --release -p codex-island-client-ffi >/dev/null
cargo build --release -p codex-island-hostd >/dev/null

LIB_PATH="$ENGINE_DIR/target/release/libcodex_island_client_ffi.dylib"
HOSTD_PATH="$ENGINE_DIR/target/release/codex-island-hostd"
if [[ ! -f "$LIB_PATH" ]]; then
    echo "missing UniFFI dynamic library at $LIB_PATH" >&2
    exit 1
fi
if [[ ! -f "$HOSTD_PATH" ]]; then
    echo "missing hostd binary at $HOSTD_PATH" >&2
    exit 1
fi

mkdir -p "$GENERATED_DIR" "$OUT_DIR"

if [[ -f "$GENERATED_DIR/codex_island_clientFFI.modulemap" ]]; then
    cp "$GENERATED_DIR/codex_island_clientFFI.modulemap" "$GENERATED_DIR/module.modulemap"
fi

temp_lib="$(mktemp "${TMPDIR:-/tmp}/codex_island_client_ffi.XXXXXX.dylib")"
cp "$LIB_PATH" "$temp_lib"
install_name_tool -id "@rpath/libcodex_island_client_ffi.dylib" "$temp_lib"
cp "$temp_lib" "$OUT_DIR/libcodex_island_client_ffi.dylib"
rm -f "$temp_lib"

engine_resource_dir="$(cd "$OUT_DIR/.." && pwd)/Resources/Engine"
mkdir -p "$engine_resource_dir"
cp "$HOSTD_PATH" "$engine_resource_dir/codex-island-hostd"
chmod +x "$engine_resource_dir/codex-island-hostd"
