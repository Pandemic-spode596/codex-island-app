#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    cat <<'EOF'
Usage: ./scripts/swift-quality.sh [--all|--staged]

Runs the repository Swift quality baseline:
  - SwiftFormat in lint mode
  - SwiftLint in strict mode

Options:
  --all     Lint CodexIsland/ and CodexIslandTests/ (default)
  --staged  Lint only staged Swift files for git hooks
EOF
}

ensure_command() {
    local command_name="$1"

    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi

    cat <<EOF >&2
Missing required tool: $command_name

Install with Homebrew:
  brew install $( [[ "$command_name" == "swiftformat" ]] && echo "swiftformat" || echo "swiftlint" )
EOF
    exit 1
}

mode="all"
case "${1:-}" in
    "")
        ;;
    --all)
        mode="all"
        ;;
    --staged)
        mode="staged"
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac

cd "$ROOT_DIR"

targets=()
if [[ "$mode" == "staged" ]]; then
    while IFS= read -r -d '' file; do
        targets+=("$file")
    done < <(git diff --cached --name-only --diff-filter=ACMR -z -- '*.swift')

    if [[ "${#targets[@]}" -eq 0 ]]; then
        echo "No staged Swift files to lint."
        exit 0
    fi

    echo "Running Swift quality checks on staged Swift files..."
else
    targets=("CodexIsland" "CodexIslandTests")
    echo "Running Swift quality checks on CodexIsland/ and CodexIslandTests/..."
fi

ensure_command swiftformat
ensure_command swiftlint

swiftformat --lint --config "$ROOT_DIR/.swiftformat" "${targets[@]}"

if [[ "$mode" == "staged" ]]; then
    export SCRIPT_INPUT_FILE_COUNT="${#targets[@]}"
    for index in "${!targets[@]}"; do
        export "SCRIPT_INPUT_FILE_$index=${targets[$index]}"
    done
    swiftlint lint --config "$ROOT_DIR/.swiftlint.yml" --use-script-input-files --strict
else
    swiftlint lint --config "$ROOT_DIR/.swiftlint.yml" --strict
fi
