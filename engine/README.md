# codex-island-engine

Shared Rust workspace for the cross-platform Codex Island engine.

This workspace is now the stable home for:

- engine protocol definitions
- shared client runtime and reducers
- host daemon process management
- future Kotlin / Swift FFI bindings

## Client bindings

`crates/island-client-ffi` now exports a UniFFI object surface for the shared
client runtime. The generated bindings are checked in for the two shell
targets:

- Kotlin: `apps/android/app/src/main/java/uniffi/codex_island_client/`
- Swift: `apps/macos/Generated/Engine/`

Regenerate them with:

```bash
./scripts/generate-engine-bindings.sh
```
