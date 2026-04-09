# Shell Adapter Contract

This document defines the stable boundary between the shared Rust engine and
the thin macOS / Android shells.

## Goal

UI layers must consume engine state and issue intents through the shared client
runtime only. Shell code should not reimplement engine reducers, reconnect
policy, or protocol-specific request bookkeeping.

## Stable Surface

The shell boundary is the UniFFI object exported from
`crates/island-client-ffi`:

- `EngineRuntime`
- `EngineRuntimeState`
- `EngineSnapshotRecord`
- `QueuedCommandRecord`
- `ReconnectStateRecord`
- `ConnectionDiagnosticsRecord`

Shells may treat the generated Kotlin/Swift bindings as platform-native DTOs,
but the source of truth is the Rust surface above.

## Shell Responsibilities

Platform shells own:

- UI rendering
- view-model / coordinator wiring
- local persistence for shell-only preferences
- transport plumbing to hostd / app-server sockets, streams, or background jobs
- timers that wake reconnect attempts when `reconnectPending` is true

Platform shells do not own:

- reducer logic for snapshots, pairing, or connection state
- reconnect backoff policy
- in-flight request tracking
- requeue-on-disconnect behavior
- protocol error classification

## Required Data Flow

The shell adapter loop should look like this:

1. Construct `EngineRuntime(clientName, clientVersion, authToken)`.
2. Call `requestConnection()` when the shell wants the engine online.
3. Drain `popNextCommandJson()` and send each JSON command over the active
   transport.
4. Feed every server message back through `applyServerEventJson(...)`.
5. If the transport drops, call `transportDisconnected(reason)`.
6. If `state().reconnect.reconnectPending` becomes `true`, wait for the shell's
   timer/background scheduler, then call `activateReconnectNow()`.
7. Repeat step 3 after reconnect activation or any queueing API call.

## Command Queue Contract

Shells may create protocol commands in two ways:

- direct JSON helpers, such as `helloCommandJson()` or
  `appServerRequestCommandJson(...)`
- queue-oriented helpers, such as `enqueueGetSnapshot()`,
  `enqueueAppServerRequest(...)`, and `popNextCommandJson()`

The adapter contract for production shells is:

- use queue-oriented APIs for normal runtime flow
- use direct JSON helpers only for debugging, tests, or migration tooling
- assume at most one in-flight command managed by the runtime
- inspect `pendingCommands` and `inFlightCommand` from `EngineRuntimeState`
  instead of duplicating queue state in the shell

## State Consumption Contract

Shell-facing state must be read from `EngineRuntimeState` only:

- `snapshot`: host health, pairing, paired devices, active thread/turn
- `connection`: disconnected / connecting / connected / error
- `pendingCommands` / `inFlightCommand`: command pipeline visibility
- `reconnect`: desired reconnect policy, pending retry, current backoff
- `diagnostics`: connect/disconnect counters, hello timings, error summaries
- `lastError` / `lastAppServerEventJson`: recent failure and opaque event payload

The shell should project this into UI-specific models, but should not mutate or
derive alternate engine truth outside the runtime.

## Platform Mapping

### Android

- Kotlin view-models may observe `EngineRuntimeState` and map it into Compose /
  Activity state.
- WorkManager, foreground services, or coroutine timers may own reconnect wakeup
  timing, but they must re-enter through `activateReconnectNow()`.
- Transport code should remain JSON-in / JSON-out around `popNextCommandJson()`
  and `applyServerEventJson(...)`.

### macOS

- Swift coordinators / observable objects may translate `EngineRuntimeState`
  into current UI models while the existing Swift shell is still in migration.
- `RemoteSessionMonitor` replacement work should consume `EngineSnapshotRecord`
  and queue APIs rather than talking protocol JSON directly.
- AppKit/SwiftUI code must not infer reconnect state from transport callbacks
  when the runtime already exposes it.

## Compatibility Rule

If shells need new behavior, add it to the Rust runtime and extend the UniFFI
surface. Do not add platform-only protocol branches that bypass `EngineRuntime`.
