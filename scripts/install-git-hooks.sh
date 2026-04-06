#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

chmod +x \
    "$ROOT_DIR/scripts/run-beads-hook.sh" \
    "$ROOT_DIR/scripts/swift-quality.sh" \
    "$ROOT_DIR/.githooks/post-checkout" \
    "$ROOT_DIR/.githooks/post-merge" \
    "$ROOT_DIR/.githooks/pre-commit" \
    "$ROOT_DIR/.githooks/pre-push" \
    "$ROOT_DIR/.githooks/prepare-commit-msg"
git config core.hooksPath .githooks

echo "Installed repository git hooks from .githooks/"
echo "Hooks keep beads integration and add ./scripts/swift-quality.sh --staged to pre-commit"
