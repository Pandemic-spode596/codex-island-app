#!/bin/sh
set -eu

hook_name="${1:?hook name is required}"
shift || true

if ! command -v bd >/dev/null 2>&1; then
    exit 0
fi

export BD_GIT_HOOK=1
bd_timeout="${BEADS_HOOK_TIMEOUT:-30}"

if command -v timeout >/dev/null 2>&1; then
    timeout "$bd_timeout" bd hooks run "$hook_name" "$@"
    bd_exit=$?
    if [ "$bd_exit" -eq 124 ]; then
        echo >&2 "beads: hook '$hook_name' timed out after ${bd_timeout}s - continuing without beads"
        exit 0
    fi
else
    bd hooks run "$hook_name" "$@"
    bd_exit=$?
fi

if [ "${bd_exit:-0}" -eq 3 ]; then
    echo >&2 "beads: database not initialized - skipping hook '$hook_name'"
    exit 0
fi

exit "${bd_exit:-0}"
