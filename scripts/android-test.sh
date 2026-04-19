#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/apps/android"
RUN_CONNECTED=0
BOOTSTRAP_LOG="$(mktemp -t codex-island-android-bootstrap.XXXXXX)"
trap 'rm -f "$BOOTSTRAP_LOG"' EXIT

wait_for_android_test_device() {
    local timeout_secs="${1:-120}"
    local deadline=$((SECONDS + timeout_secs))

    if ! command -v adb >/dev/null 2>&1; then
        echo "adb is not available in PATH" >&2
        exit 1
    fi

    adb wait-for-device >/dev/null 2>&1 || true

    while (( SECONDS < deadline )); do
        local boot_completed
        boot_completed="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | tr -d '\n' || true)"

        if [[ "$boot_completed" == "1" ]] &&
            adb shell cmd package list packages >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    echo "timed out waiting for Android package service to become ready" >&2
    adb devices >&2 || true
    adb shell getprop sys.boot_completed >&2 || true
    adb shell service list | head -n 20 >&2 || true
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --connected)
            RUN_CONNECTED=1
            shift
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 1
            ;;
    esac
done

"$ROOT_DIR/scripts/android-bootstrap.sh" --strict >"$BOOTSTRAP_LOG"

JAVA_HOME_VALUE="$(grep '^JAVA_HOME=' "$BOOTSTRAP_LOG" | cut -d= -f2-)"
ANDROID_SDK_VALUE="$(grep '^ANDROID_SDK_ROOT=' "$BOOTSTRAP_LOG" | cut -d= -f2-)"

export JAVA_HOME="$JAVA_HOME_VALUE"
export ANDROID_SDK_ROOT="$ANDROID_SDK_VALUE"
export PATH="$JAVA_HOME/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"

pushd "$ANDROID_DIR" >/dev/null
./gradlew --no-daemon :app:assembleDebug :app:testDebugUnitTest

if (( RUN_CONNECTED == 1 )); then
    wait_for_android_test_device 180
    ./gradlew --no-daemon :app:connectedDebugAndroidTest
elif command -v adb >/dev/null 2>&1 && adb devices | awk 'NR > 1 && $2 == "device" { found = 1 } END { exit(found ? 0 : 1) }'; then
    wait_for_android_test_device 180
    ./gradlew --no-daemon :app:connectedDebugAndroidTest
else
    echo "skip connectedDebugAndroidTest: no booted emulator or attached device"
fi
popd >/dev/null
