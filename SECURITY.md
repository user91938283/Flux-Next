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
- the session seed, channel salts, epochs, and counters held by the client.

The client is hostile. A cheater can read and modify anything that runs on their device, call remotes directly, and produce well-formed messages. Security must not depend on hiding code, hiding the seed or salts, clearing `shared`, or trusting a client-side check.

## Framework properties

Flux Next provides these server-side protections:

- strict argument validation with `Flux.validate`, non-kicking `Flux.validateLenient`, and single-value `Flux.check`;
- authorization hooks with `Flux.secure` and `Flux.guard`;
- `Instance` checks for class, ancestor, and ownership patterns;
- rejection of `NaN` and infinity;
- payload caps for argument count, total string bytes, string length, table size, and table depth;
- per-action token buckets and a global per-player call limit;
- a violation hook, `Flux.onViolation`, that contains logger errors;
- separate event and function channels, with no server-side `InvokeClient`.

Protocol hygiene, not authorization:

- a per-session seed and separate event and function channel salts;
- a counter and a name-bound non-cryptographic checksum on every client-to-server message;
- a 1000-step out-of-order window and replay rejection inside it;
- salt rotation every 60 seconds with a 10-second grace period and a rotation epoch.

The checksum does not cover the arguments. The seed and salts are delivered to the client and are not secrets.

These are defense-in-depth. The only real authorization boundary is server code that checks server state.

## What the checksum layer does and does not do

The checksum layer rejects malformed envelopes, counters outside its window, replayed counters, and checksum mismatches for the action name and counter. It does not detect argument tampering, because the arguments are not part of the checksum. It is not encryption, not authentication, and not a cryptographic MAC. The checksum is deliberately lightweight. The seed is delivered to the client so the client can derive the salts; a cheater who controls the client can recover them.

Flux does not manage accounts, authentication, or session tokens. Roblox's `Player` object is the only identity. Flux does not encrypt network traffic; the Roblox platform handles transport security.

Therefore:

- do not treat possession of a valid checksum as proof of authorization;
- do not put prices, rewards, drop rates, cooldowns, or success flags in replicated code;
- do not rely on `shared.import` or `shared.Flux` being cleared;
- do not rely on a kick to stop a determined cheater.

## Security expectations for game code

Every remote handler should:

1. validate shape and limits with `Flux.validate` or `Flux.secure`; the schema must cover every positional argument;
2. authorize the action against server state, for example ownership, distance, inventory, currency, cooldown, and alive state;
3. compare a client-supplied `Player` or `Instance` with the caller and check ownership, not just type or ancestry;
4. mutate server state, never a client-supplied copy;
5. rate-limit expensive work and avoid yielding before authorization;
6. sanitize text before storing, displaying, or broadcasting it; validation is not sanitization;
7. log with `UserId`, action, and reason, never with seeds, salts, checksums, or payloads. The default logger escapes control characters and aggregates repeated reasons; custom loggers must do the same.

Keep economy logic, rule constants, and anti-cheat checks in `ServerScriptService` or `ServerStorage`. Treat `ReplicatedStorage`, `Shared`, and `Packages` as public.

## Guidance alignment

Flux Next does not claim OGSF or OWASP certification. This table records what the framework provides and what remains the game's responsibility.

| Guidance | Status |
| --- | --- |
| OGSF 1.3, 2.4.1 — server authority and server-side access control | Supported by design; game code must enforce it. |
| OGSF 2.3 — session management | Not applicable. Roblox owns player sessions; Flux does not issue session tokens. |
| OGSF 4.2.1 — sequence numbers and replay rejection | Supported with a per-channel counter window. |
| OGSF 4.2.2 — authenticated packets | Not provided. The checksum is client-known and is not an HMAC. |
| OGSF 4.2.3 — packet size and structure validation | Supported with argument, byte, table, and depth limits. |
| OGSF 4.3.2 — rate limiting | Supported for remote calls; game code must rate-limit its own expensive work. |
| OGSF 5.4.1 — input sanitization | Not provided. Validation is not sanitization; game code must sanitize text. |
| OGSF 7.3.1–7.3.2 — server-side logging without secrets | Supported by the violation hook; central aggregation and retention are deployment concerns. |

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
- extracting the session seed or channel salts from client memory and sending valid checksums, which is expected because the checksum layer is not an authorization boundary;
- bypassing the removal of `shared.import` or `shared.Flux`;
- game code that openly trusts client-provided prices, rewards, or outcomes;
- vulnerabilities in Roblox itself or in third-party packages not maintained here;
- account compromise, social engineering, or physical access.

## Release integrity

Release tags are built by GitHub Actions. The workflow pins third-party actions to commit SHAs, verifies the Rojo archive checksum, runs the test suite, builds `FluxNext.rbxl`, and publishes `FluxNext.rbxl.sha256` next to the place file. Verify the checksum before use:

```bash
sha256sum -c FluxNext.rbxl.sha256
```
