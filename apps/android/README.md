# Codex Island Android Shell

Native Android shell for the shared Codex Island Rust engine.

This app is intentionally thin:

- Android owns UI, navigation, lifecycle, and platform integrations.
- Rust owns protocol, connection logic, state reduction, and host daemon
  interaction.

The current Android project now includes:

- host profile management with QR/manual input parsing
- secure local storage for host tokens and pairing state
- a thread/chat workspace shell with approval and user-input placeholders
- generated UniFFI bindings checked into `app/src/main/java/uniffi/codex_island_client/`
- two transport entry styles:
  - `host:7331` or `ws://...` for direct `hostd` websocket mode
  - `ssh://user@host` or `user@host` for SSH direct mode that launches remote `codex app-server`

The SSH direct path is the first Android step toward macOS-style remote parity.
The current implementation can also generate an RSA SSH keypair per SSH host
profile and surface a ready-to-copy `authorized_keys` install command in the
UI. Password auth remains available as a fallback; the existing `Auth token`
field acts as the SSH password when the host input is an SSH target.

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
- detect the newest installed Android NDK under the same SDK root
- write `apps/android/local.properties`
- warn if `platforms;android-35`, `build-tools;35.0.0`, `platform-tools`, or
  `ndk;27.0.12077973`
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

Start a real hostd endpoint on a same-tailnet macOS/Linux host for Android
acceptance:

```bash
./scripts/run-hostd-acceptance.sh --bind <tailscale-ip-or-hostname>:7331
```

The repository now includes:

- a Robolectric JVM test for `MainActivity`
- an instrumentation smoke test for `MainActivity`
- bootstrap workspace and thread/chat view-model tests
- automatic Rust Android `.so` packaging during Gradle `preBuild`
- Gradle wrapper files under `apps/android/`

## Suggested macOS Workflow

1. Install Android Studio.
2. Install SDK components `platforms;android-35`, `build-tools;35.0.0`, and
   `platform-tools`, plus one NDK side-by-side package such as
   `ndk;27.0.12077973`.
3. Create or boot an emulator from Android Studio Device Manager if you want to
   run `connectedDebugAndroidTest`.
4. Run `./scripts/android-test.sh`.
