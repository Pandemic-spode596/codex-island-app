#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/apps/android"
LOCAL_PROPERTIES="$ANDROID_DIR/local.properties"
STRICT=0

if [[ "${1:-}" == "--strict" ]]; then
    STRICT=1
fi

find_java_home() {
    if [[ -n "${JAVA_HOME:-}" ]]; then
        echo "$JAVA_HOME"
        return 0
    fi

    if command -v /usr/libexec/java_home >/dev/null 2>&1; then
        for version in 17 21; do
            if /usr/libexec/java_home -v "$version" >/dev/null 2>&1; then
                /usr/libexec/java_home -v "$version"
                return 0
            fi
        done
    fi

    return 1
}

find_android_sdk() {
    if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "${ANDROID_SDK_ROOT}" ]]; then
        echo "$ANDROID_SDK_ROOT"
        return 0
    fi

    if [[ -n "${ANDROID_HOME:-}" && -d "${ANDROID_HOME}" ]]; then
        echo "$ANDROID_HOME"
        return 0
    fi

    if [[ -d "$HOME/Library/Android/sdk" ]]; then
        echo "$HOME/Library/Android/sdk"
        return 0
    fi

    return 1
}

JAVA_HOME_VALUE="$(find_java_home || true)"
if [[ -z "$JAVA_HOME_VALUE" ]]; then
    echo "missing supported JDK. Install JDK 17 or 21 and set JAVA_HOME." >&2
    exit 1
fi

ANDROID_SDK_VALUE="$(find_android_sdk || true)"
if [[ -z "$ANDROID_SDK_VALUE" ]]; then
    echo "missing Android SDK. Set ANDROID_SDK_ROOT or install Android Studio SDK components to ~/Library/Android/sdk." >&2
    exit 1
fi

mkdir -p "$ANDROID_DIR"
printf 'sdk.dir=%s\n' "$ANDROID_SDK_VALUE" > "$LOCAL_PROPERTIES"

echo "JAVA_HOME=$JAVA_HOME_VALUE"
echo "ANDROID_SDK_ROOT=$ANDROID_SDK_VALUE"
echo "local.properties -> $LOCAL_PROPERTIES"

missing=()
[[ -d "$ANDROID_SDK_VALUE/platforms/android-35" ]] || missing+=("platforms;android-35")
[[ -d "$ANDROID_SDK_VALUE/build-tools/35.0.0" ]] || missing+=("build-tools;35.0.0")
[[ -d "$ANDROID_SDK_VALUE/platform-tools" ]] || missing+=("platform-tools")

if (( ${#missing[@]} > 0 )); then
    echo "missing SDK components: ${missing[*]}" >&2
    echo "install with sdkmanager: sdkmanager \"${missing[0]}\"${missing[@]:1:+ ...}" >&2
    if (( STRICT == 1 )); then
        exit 1
    fi
fi
