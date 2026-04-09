# Codex Island Android Shell

Native Android shell for the shared Codex Island Rust engine.

This app is intentionally thin:

- Android owns UI, navigation, lifecycle, and platform integrations.
- Rust owns protocol, connection logic, state reduction, and host daemon
  interaction.

The current Android project is only a bootstrap skeleton. It will consume the
shared engine through generated bindings checked into
`app/src/main/java/uniffi/codex_island_client/`.

Regenerate the Kotlin and Swift UniFFI bindings from the repository root with:

```bash
./scripts/generate-engine-bindings.sh
```

## macOS Test Environment

On macOS, use JDK `17` or `21`. The helper scripts prefer `17`, then fall back
to `21`. Avoid running this project with JDK `25`; the current Gradle Kotlin
DSL toolchain fails early on that version.

Bootstrap the local Android environment with:

```bash
./scripts/android-bootstrap.sh
```

The script will:

- detect a supported JDK
- detect the Android SDK from `ANDROID_SDK_ROOT`, `ANDROID_HOME`, or
  `~/Library/Android/sdk`
- write `apps/android/local.properties`
- warn if `platforms;android-35`, `build-tools;35.0.0`, or `platform-tools`
  are missing

If you need a template, copy `apps/android/local.properties.example`.

## Test Entry Points

Run build + JVM tests:

```bash
./scripts/android-test.sh
```

Run build + JVM tests + device/emulator instrumentation tests:

```bash
./scripts/android-test.sh --connected
```

The repository now includes:

- a Robolectric JVM test for `MainActivity`
- an instrumentation smoke test for `MainActivity`
- Gradle wrapper files under `apps/android/`

## Suggested macOS Workflow

1. Install Android Studio.
2. Install SDK components `platforms;android-35`, `build-tools;35.0.0`, and
   `platform-tools`.
3. Create or boot an emulator from Android Studio Device Manager if you want to
   run `connectedDebugAndroidTest`.
4. Run `./scripts/android-test.sh`.
