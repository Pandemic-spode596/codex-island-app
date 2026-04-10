# Android V1 Acceptance Matrix

Last updated: 2026-04-10

## Scope

This matrix tracks Android direct-connect shell v1 validation across:

- Android shell build and local UI smoke
- shared hostd/app-server harness coverage
- same-tailnet macOS and Linux host flows
- reconnect and upstream recovery behavior

## Current Outcome

- Android local build, JVM tests, and instrumentation smoke are passing on the local `codex-island-api35` emulator.
- Android now auto-packages the shared Rust FFI library during Gradle `preBuild`, and instrumentation smoke confirms the runtime loads on-device.
- Android live websocket transport is wired for pair, thread list/start/resume, send/steer, approval response, request-user-input response, interrupt, and reconnect state handling.
- `codex-island-hostd` integration coverage is passing for pair/auth, thread list, send, interrupt, approval, request-user-input, restart recovery, and a real `codex app-server --listen stdio://` initialize-plus-follow-up handshake.
- Real same-tailnet macOS/Linux validation is still blocked only by the absence of configured acceptance hosts in the current local environment.

## Matrix

| Area | Scenario | Environment | Status | Evidence |
| --- | --- | --- | --- | --- |
| Android shell | `assembleDebug` + JVM tests | Local macOS dev machine | Passed | `./scripts/android-test.sh` |
| Android shell | Instrumentation smoke (`MainActivity` + native runtime load) | `codex-island-api35` emulator | Passed | `./scripts/android-test.sh --connected` |
| Host daemon | Pair/auth token persistence | Rust unit/integration tests | Passed | `cargo test -p codex-island-hostd` |
| Host daemon | Thread list/send/interrupt harness | Rust unit/integration tests | Passed | `cargo test -p codex-island-hostd` |
| Host daemon | Approval + request_user_input harness | Rust unit/integration tests | Passed | `cargo test -p codex-island-hostd` |
| Host daemon | Upstream restart recovery | Rust unit/integration tests | Passed | `cargo test -p codex-island-hostd` |
| Host daemon | Real `codex app-server` initialize + JSONL follow-up | Rust unit/integration tests | Passed | `cargo test -p codex-island-hostd` |
| macOS host real flow | Pair Android shell to same-tailnet macOS host | Real host not configured | Blocked | Requires configured same-tailnet macOS host |
| Linux host real flow | Pair Android shell to same-tailnet Linux host | Real host not configured | Blocked | Requires configured same-tailnet Linux host |
| Android reconnect | Foreground reconnect after host/profile restore | Same-tailnet host not configured | Blocked | Android live transport is wired; pending real host rerun |
| Upstream recovery | Android sees hostd/app-server restart and recovers | Same-tailnet host not configured | Blocked | Hostd harness passes; pending Android live host rerun |

## Notes

- The Android shell now includes host profile management, thread/chat workspace state, approval/user-input cards, command previews, and Android-packaged shared native libraries.
- The connected Android test currently validates app install/launch and the top-level UI smoke only; it does not cover same-tailnet traffic.
- Use `./scripts/run-hostd-acceptance.sh --bind <tailscale-ip-or-hostname>:7331` on a macOS or Linux host to start a real hostd endpoint for Android acceptance runs.
- After Android native packaging landed, the remaining rerun target is:
  - one macOS host on the same tailnet
  - one Linux host on the same tailnet
  - the existing `codex-island-api35` emulator or a real Android device

## Recommended Next Run

1. On each macOS/Linux acceptance host, run `./scripts/run-hostd-acceptance.sh --bind <tailscale-ip-or-hostname>:7331`.
2. Save that `<host>:7331` address into the Android shell, or import it through the existing `codex-island://pair?...` payload flow.
3. Repeat:
   - pair start / confirm
   - thread list
   - thread start / resume
   - send / steer
   - approval allow / deny
   - request_user_input response
   - interrupt
   - hostd restart / app-server restart recovery
