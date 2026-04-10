#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$ROOT_DIR/engine"
BUILD_PROFILE="release"
BIND_ADDR="${HOSTD_BIND_ADDR:-0.0.0.0:7331}"
SHELL_PATH="${SHELL:-/bin/zsh}"
STATE_DIR="${HOSTD_STATE_DIR:-$HOME/.codex-island/hostd-acceptance}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bind)
            BIND_ADDR="${2:?missing bind address}"
            shift 2
            ;;
        --shell)
            SHELL_PATH="${2:?missing shell path}"
            shift 2
            ;;
        --state-dir)
            STATE_DIR="${2:?missing state dir}"
            shift 2
            ;;
        --debug)
            BUILD_PROFILE="debug"
            shift
            ;;
        --release)
            BUILD_PROFILE="release"
            shift
            ;;
        *)
            echo "unknown option: $1" >&2
            echo "usage: $0 [--bind host:port] [--shell /bin/zsh] [--state-dir /path] [--debug|--release]" >&2
            exit 1
            ;;
    esac
done

if ! command -v codex >/dev/null 2>&1; then
    echo "missing required command: codex" >&2
    exit 1
fi

mkdir -p "$STATE_DIR"

pushd "$ENGINE_DIR" >/dev/null
if [[ "$BUILD_PROFILE" == "release" ]]; then
    cargo build --release -p codex-island-hostd
    HOSTD_BIN="$ENGINE_DIR/target/release/codex-island-hostd"
else
    cargo build -p codex-island-hostd
    HOSTD_BIN="$ENGINE_DIR/target/debug/codex-island-hostd"
fi
popd >/dev/null

if [[ ! -x "$HOSTD_BIN" ]]; then
    echo "hostd binary is missing at $HOSTD_BIN" >&2
    exit 1
fi

echo "Starting codex-island-hostd for Android same-tailnet acceptance"
echo "  bind address : $BIND_ADDR"
echo "  shell        : $SHELL_PATH"
echo "  state dir    : $STATE_DIR"
echo "  hostd binary : $HOSTD_BIN"
echo
echo "Android host input example:"
echo "  $BIND_ADDR"
echo
echo "Keep this process running while the Android shell performs pair/refresh/thread/chat flows."

exec "$HOSTD_BIN" serve "$BIND_ADDR" "$SHELL_PATH" "$STATE_DIR"
