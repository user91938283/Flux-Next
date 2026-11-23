# AGENTS.md

Instructions for AI coding assistants working on Flux-Next. This file follows the OpenSSF guidance for security-focused AI instructions.

## Non-negotiable rules

- The server is authoritative. Never move a gameplay decision, reward, price, cooldown, drop rate, or success check to the client.
- Treat every remote payload as hostile. Validate shape, type, range, length, and `Instance` class or ancestor on the server.
- Validation is not authorization. Check ownership, distance, inventory, currency, cooldown, and alive state in a guard before mutating server state.
- Never put secrets, server-only rules, or anti-cheat parameters in `ReplicatedStorage`, `Shared`, `Packages`, or `["Flux/client"]`.
- Do not rely on tokens, key rotation, `shared.import = nil`, client-side hiding, or kicks as a security boundary.
- Do not add server-to-client `InvokeClient`. Use events for server-to-client messages and client-to-server functions only for request/response calls that need a return value.
- Keep event and function handlers separate. Do not merge `network:on` and `network:onCall`.
- Rate-limit expensive actions. Drop and report rate-limit and unknown-action violations. Kick only for protocol violations such as a forged token, malformed fields, or an oversized payload.
- Log with `UserId`, the action, and the reason. Never log tokens, keys, or unrelated player data.

## Layout

- Framework server code: `src/ServerScriptService/Flux/init.server.lua`.
- Framework client code: `src/StarterPlayer/StarterPlayerScripts/Flux/init.client.lua`.
- Game server code: `["Flux/server"].Core`, `["Flux/server"].Classes`, `["Flux/server"].Handlers`.
- Game client code: `["Flux/client"].Core`, `["Flux/client"].Classes`, `["Flux/client"].Handlers`.
- Shared code only: `src/ReplicatedStorage/Shared`.
- Packages: `src/ReplicatedStorage/Packages`.
- Use bracket notation for runtime paths that contain `/`, for example `["Flux/server"].Core.CoreHandler`.

## Style

- Luau and Roblox APIs only.
- Tabs for indentation.
- Simple APIs, minimal comments, English only.
- Keep the single-script layout: one `Script` and one `LocalScript` with child folders.
- Preserve performance-sensitive paths. Avoid allocations in per-call handlers when a reusable table or value works.

## Security-sensitive changes

When changing the network layer, validation, rate limits, payload limits, key rotation, or authorization helpers:

- update `README.md` and `SECURITY.md` when behavior or guarantees change;
- add or update tests under `tests/`;
- keep the documented limits and violation behavior accurate;
- check that `InvokeClient` stays removed;
- check that `ServerStorage` is never requested on the client;
- check that no server-only constant or secret is replicated.

## Testing and CI

Run before committing:

```bash
python tests/build.py
luau tests/.build/run.lua
```

Compile every `.lua` file with `luau-compile`, then build the place file with Rojo. CI runs the same checks. Security-relevant fixes need a regression test.

## Supply chain

- Pin GitHub Actions to full commit SHAs, with a version comment.
- Verify downloaded binaries with a SHA-256 checksum.
- Do not add a dependency without checking its maintenance, license, and release integrity.
- Publish `FluxNext.rbxl.sha256` with every release asset.

## Documentation

- Update the API section when a public function or argument changes.
- Explain limitations honestly. Do not describe the token layer as encryption, authentication, or a cryptographic MAC.
- Include server-authority examples, not client-side security examples.
