#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/apps/android"
RUN_CONNECTED=0
BOOTSTRAP_LOG="$(mktemp -t codex-island-android-bootstrap.XXXXXX)"
trap 'rm -f "$BOOTSTRAP_LOG"' EXIT

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
    ./gradlew --no-daemon :app:connectedDebugAndroidTest
elif command -v adb >/dev/null 2>&1 && adb devices | awk 'NR > 1 && $2 == "device" { found = 1 } END { exit(found ? 0 : 1) }'; then
    ./gradlew --no-daemon :app:connectedDebugAndroidTest
else
    echo "skip connectedDebugAndroidTest: no booted emulator or attached device"
fi
popd >/dev/null
