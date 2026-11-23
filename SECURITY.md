# Security policy

## Supported versions

Security fixes land on `main` and in the latest tagged release. Older releases are not maintained. Use the newest `FluxNext.rbxl` and verify its `FluxNext.rbxl.sha256` before opening it.

## Reporting a vulnerability

Do not open a public issue for details that could let someone exploit players or games. Use GitHub private vulnerability reporting:

https://github.com/user91938283/Flux-Next/security/advisories/new

Include:

- the affected commit or release;
- the impact and which trust boundary is crossed;
- reproduction steps or a minimal proof of concept;
- whether the issue is client-only, server-impacting, or supply-chain related.

We aim to acknowledge reports within three business days and to coordinate disclosure after a fix is available. Please do not publish exploit details before that coordination.

## Threat model

Trusted:

- server scripts in `ServerScriptService`, especially `["Flux/server"]` and its modules;
- `ServerStorage`;
- server-only code and constants;
- the Roblox engine and the platform's replication rules.

Untrusted:

- every LocalScript, including `["Flux/client"]` and its modules;
- `StarterPlayer`, `ReplicatedStorage`, `Shared`, and `Packages`, all of which replicate to clients;
- every value received from a remote;
- client memory, client timing, `Instance` references, and client-side checks;
- tokens, keys, epochs, and counters held by the client.

The client is hostile. A cheater can read and modify anything that runs on their device, call remotes directly, and produce well-formed messages. Security must not depend on hiding code, hiding keys, clearing `shared`, or trusting a client-side check.

## Framework properties

Flux Next provides these server-side protections:

- strict argument validation with `Flux.validate`, non-kicking `Flux.validateLenient`, and single-value `Flux.check`;
- authorization hooks with `Flux.secure` and `Flux.guard`;
- `Instance` checks for class and ancestor;
- rejection of `NaN` and infinity;
- payload caps for argument count, string length, table size, and table depth;
- per-action token buckets and a global per-player call limit;
- rotating event and function keys, name-bound digests, replay rejection, and an out-of-order counter window;
- a violation hook, `Flux.onViolation`, that contains logger errors;
- separate event and function channels, with no server-side `InvokeClient`.

These are defense-in-depth. The only real authorization boundary is server code that checks server state.

## What the token layer does and does not do

The token layer rejects malformed traffic, accidental reordering beyond its window, replay, and naive tampering. It is not encryption, not authentication, and not a cryptographic MAC. The digest is deliberately lightweight. The keys are derived on the server but delivered to the client so the client can build requests; a cheater who controls the client can recover them.

Therefore:

- do not treat possession of a valid token as proof of authorization;
- do not put prices, rewards, drop rates, cooldowns, or success flags in replicated code;
- do not rely on `shared.import` or `shared.Flux` being cleared;
- do not rely on a kick to stop a determined cheater.

## Security expectations for game code

Every remote handler should:

1. validate shape and limits with `Flux.validate` or `Flux.secure`;
2. authorize the action against server state, for example ownership, distance, inventory, currency, cooldown, and alive state;
3. mutate server state, never a client-supplied copy;
4. rate-limit expensive work;
5. log with `UserId`, action, and reason, never with tokens or keys.

Keep economy logic, rule constants, and anti-cheat checks in `ServerScriptService` or `ServerStorage`. Treat `ReplicatedStorage`, `Shared`, and `Packages` as public.

## In scope

Reports are in scope when they show:

- a framework gap that lets a client bypass server-side validation or authorization;
- a way to exceed the documented payload or rate limits;
- a remote protocol flaw that causes unauthorized state changes, server errors, or a practical denial of service;
- exposure of server-only secrets through framework code, examples, or the release process;
- a supply-chain or release integrity problem in the repository workflows;
- a test or CI gap that allows a known security regression to ship.

## Out of scope

- client-side cheats that only change local rendering, UI, or camera behavior;
- extracting keys or tokens from client memory and sending valid messages, which is expected because the token layer is not an authorization boundary;
- bypassing the removal of `shared.import` or `shared.Flux`;
- game code that openly trusts client-provided prices, rewards, or outcomes;
- vulnerabilities in Roblox itself or in third-party packages not maintained here;
- account compromise, social engineering, or physical access.

## Release integrity

Release tags are built by GitHub Actions. The workflow pins third-party actions to commit SHAs, verifies the Rojo archive checksum, runs the test suite, builds `FluxNext.rbxl`, and publishes `FluxNext.rbxl.sha256` next to the place file. Verify the checksum before use:

```bash
sha256sum -c FluxNext.rbxl.sha256
```
