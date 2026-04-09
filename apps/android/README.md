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
