<div align="center">
  <img src="CodexIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Codex Island logo" width="100" height="100">
  <h1 align="center">Codex Island</h1>
  <p align="center">
    A Dynamic Island-style macOS companion for Codex CLI.
  </p>
  <p align="center">
    <a href="./README.zh-CN.md">简体中文</a>
    ·
    <a href="https://github.com/Jarcis-cy/codex-island-app/releases/latest">Latest Release</a>
  </p>
  <p align="center">
    <strong>Keep local and remote Codex sessions visible from the notch.</strong><br>
    Handle approvals, switch threads, and recover context without living in terminal tabs.
  </p>
  <p align="center">
    macOS 15.6+ · Local hooks · SSH remote hosts · Approval flows · Transcript-aware chat
  </p>
  <p align="center">
    <img src="./docs/media/codex-island-hero.png" alt="Codex Island session overview" width="920">
  </p>
</div>

Codex Island is a macOS notch and menu bar companion for Codex CLI. It keeps local sessions visible, connects to remote hosts over SSH, and gives you a lightweight place to inspect chat state, approvals, and recent context without constant terminal context switches.

## See It In Action

<table>
  <tr>
    <td width="50%" align="center">
      <img src="./docs/media/remote-workflow.gif" alt="Remote Codex workflow in Codex Island" width="100%">
    </td>
    <td width="50%" align="center">
      <img src="./docs/media/local-workflow.gif" alt="Local Codex workflow in Codex Island" width="100%">
    </td>
  </tr>
  <tr>
    <td valign="top">
      <strong>Remote workflow</strong><br>
      Connect to a remote machine, resume threads, and work through SSH-backed Codex sessions from the same UI.
    </td>
    <td valign="top">
      <strong>Local workflow</strong><br>
      Track local sessions, surface plan-style interactions, and jump back into the right shell only when needed.
    </td>
  </tr>
</table>

## Highlights

- Watches Codex sessions through `~/.codex/hooks.json` and a local Unix socket.
- Connects to remote machines over SSH and talks to `codex app-server` over stdio.
- Shows recent conversation history with markdown rendering and active model/context details in chat headers.
- Supports approval flows directly from the app UI.
- Tracks multiple local sessions and remote threads, and lets you switch between them quickly.
- Lets you save SSH targets, optional default working directories, auto-connect remote hosts, and pick from `~/.ssh/config` host aliases in the app.
- Includes launch-at-login, screen selection, sound settings, and in-app updates.
- Falls back gracefully on Macs without a physical notch.

## What's New in 0.0.5

- Chat history now renders image attachments for both local and remote conversations.
- Remote thinking history filters out empty items so transcript playback is cleaner.
- Hook installation is safer: enabling hooks preserves `config.toml` formatting and avoids incorrect rewrites.
- Local session teardown and notch session matching are more precise, reducing stale state and false-positive local sessions.
- When `Remote Debug Logs` is enabled, chat headers now show a copyable session/thread identifier for diagnostics.
- The GitHub Actions Swift quality workflow now pins a stable Xcode selection and uses an isolated DerivedData path for build and test runs.

## Requirements

- macOS 15.6 or later
- Codex CLI installed locally
- SSH access to any remote machine you want to manage, with Codex CLI installed on that remote host
- Accessibility permission if you want the app to interact with window focus behavior
- `tmux` if you want tmux-aware messaging and approval workflows
- `yabai` if you want window focusing integrations

## Install

Download the latest release from GitHub, or build it locally with Xcode.

For a debug build:

```bash
xcodebuild -scheme CodexIsland -configuration Debug build
```

For a release build:

```bash
./scripts/build.sh
```

The exported app bundle is written to `build/export/Codex Island.app`.
If `exportArchive` cannot sign in the current environment, `./scripts/build.sh` now falls back to an unsigned zip at `build/release-assets/`.

## Remote Hosts Over SSH

Open `Remote Hosts` from the notch menu to add an SSH target, an optional default working directory, and an auto-connect preference for each remote machine. The `SSH Target` field accepts raw `user@host`, plain hostnames, or aliases discovered from your local `~/.ssh/config`.

When you connect a host, Codex Island launches:

```bash
ssh -T -o BatchMode=yes <target> codex app-server --listen stdio://
```

That means remote hosts currently expect non-interactive SSH authentication, and the remote machine must already have `codex` available on `PATH`. Once connected, you can list remote threads, start a new thread, reopen an existing thread, send messages, interrupt turns, and handle approvals from the app UI. The remote chat view supports both `/new` for explicitly starting a fresh thread and `/resume` for switching back to an older thread.

Remote app-server diagnostics are disabled by default. After you enable `Remote Debug Logs` from the menu, the app writes JSONL diagnostics to `~/Library/Application Support/Codex Island/Logs/remote-app-server.jsonl`.

## How It Works

On first launch, Codex Island installs a managed hook script into `~/.codex/hooks/` and updates `~/.codex/hooks.json`. The hook helper forwards local Codex hook events to the app over a Unix domain socket, and the app reconciles those events with transcript data to keep session state accurate.

Remote hosts use a separate path: the app opens an SSH stdio transport to `codex app-server` on the target machine and keeps remote thread state alongside the local hooks-first session model.

The current architecture is still hooks-first inside the macOS app process. The `sidecar/` directory is a reserved Rust scaffold for future work around transcript parsing, state aggregation, and IPC.

## Project Layout

- `CodexIsland/App/`: app lifecycle and window bootstrap
- `CodexIsland/Core/`: shared settings, geometry, and screen selection
- `CodexIsland/Services/`: hooks, local session parsing, remote app-server management, tmux integration, updates, and window management
- `CodexIsland/UI/`: notch views, menu UI, chat UI, and reusable components
- `CodexIsland/Resources/`: bundled scripts such as `codex-island-state.py`
- `scripts/`: build, signing, notarization, and release helpers
- `sidecar/`: future Rust sidecar scaffold

## Privacy

The app currently initializes Mixpanel for anonymous product analytics and Sparkle for app updates.

Tracked analytics are intended to cover app launch and session lifecycle metadata such as:

- app version and build number
- macOS version
- detected Codex version
- session start events

The repository does not claim to collect conversation content in analytics, but you should still review the source and decide whether that tradeoff matches your environment before distributing it broadly.

## Development

Open the project in Xcode for day-to-day work. The repository also includes release automation for signing, notarization, DMG creation, appcast generation, and optional GitHub release publishing:

```bash
brew install swiftformat swiftlint
./scripts/swift-quality.sh
./scripts/heuristic-quality-report.sh
./scripts/install-git-hooks.sh
./scripts/create-release.sh
```

`./scripts/swift-quality.sh` lints both `CodexIsland/` and `CodexIslandTests/` in one run. `./scripts/install-git-hooks.sh` switches Git to the repository's `.githooks/` wrappers, keeps existing beads hooks in the chain, and adds a staged-file Swift quality check to `pre-commit` so existing repository-wide debt does not block unrelated commits.

Heuristic `fuck-u-code` analysis is calibrated as a non-blocking audit signal rather than a CI gate because the current Swift parser frequently falls back to regex mode. Repository-specific thresholds and triage rules live in [`docs/quality-heuristics.md`](./docs/quality-heuristics.md).

If you change anything under `CodexIsland/Services/Hooks/` or `CodexIsland/Resources/codex-island-state.py`, treat it as user-impacting local environment behavior and verify it carefully.

## Acknowledgements

Codex Island builds on the original ideas and earlier implementation work from [`farouqaldori/claude-island`](https://github.com/farouqaldori/claude-island). Thanks to Farouq Aldori and the upstream contributors for laying the foundation this Codex-focused version continues from.

## License

Apache 2.0. See [`LICENSE.md`](./LICENSE.md).
