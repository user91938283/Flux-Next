# Flux-Next

Flux Next is an independent implementation of the Flux Framework layout and API. The original Flux Framework was created by AdministratorGnar and ThunderGemios10 under GameLoaded Entertainment.

This project is not affiliated with or endorsed by the original authors or GameLoaded Entertainment. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for provenance and licensing details.

## What it is

Flux Next keeps the original Flux layout: the framework lives inside one server script and one client script, and game code lives in their child folders.

In Roblox:

```
ServerScriptService
└─ "Flux/server" (Script)
   ├─ Core
   │  └─ CoreHandler (ModuleScript)
   ├─ Classes
   └─ Handlers

StarterPlayer.StarterPlayerScripts
└─ "Flux/client" (LocalScript)
   ├─ Core
   │  └─ CoreHandler (ModuleScript)
   ├─ Classes
   └─ Handlers

ReplicatedStorage
├─ Shared
└─ Packages
```

Modules under `Flux/server` are server-only. Modules under `Flux/client` are client-only. `Shared` is replicated to clients, so never put secrets, economy rules, drop rates, or anti-cheat checks there.

The client is untrusted. The server is authoritative for game state, rewards, purchases, and every decision that can be abused. Read [SECURITY.md](SECURITY.md) before writing gameplay code.

## Install

Sync the project with [Rojo](https://rojo.space):

```bash
rojo build -o FluxNext.rbxl
```

or run `rojo serve default.project.json` and connect from Studio.

Tagged releases include a prebuilt `FluxNext.rbxl` and `FluxNext.rbxl.sha256` on the repository's Releases page. Pushing a tag such as `v0.3.0` runs the release workflow.

In the source tree, `init.server.lua` and `init.client.lua` are Rojo's way to create a script with children:

```
src/ServerScriptService/Flux/init.server.lua       → Script "Flux/server"
src/StarterPlayer/.../Flux/init.client.lua         → LocalScript "Flux/client"
```

The source folder is named `Flux`, but in Roblox it is the script itself, not a folder.

## Quick start

Server game code goes in `["Flux/server"].Core.CoreHandler`:

```lua
local import = shared.import
local Flux = shared.Flux
local network = import("network")

network:on("joined", function(player)
	print(player.UserId .. " joined")
end)

network:onCall("hello", Flux.validate({
	{ type = "string", name = "name", length = { min = 1, max = 32 } },
}, function(player, name)
	return "Hi, " .. name
end))
```

Client game code goes in `["Flux/client"].Core.CoreHandler`:

```lua
local import = shared.import
local network = import("network")

network:on("toast", function(message)
	print(message)
end)

print(network:invoke("hello", "Bob"))
network:fire("joined")
```

`CoreHandler` runs once when `Flux/server` or `Flux/client` starts. Use it to load classes and handlers, register network handlers, and start game systems.

## Loading modules

`Packages/require` scans the entry script's children and `ReplicatedStorage.Shared` recursively. Inside `CoreHandler`:

```lua
local require = shared.import("require")

local PlayerHandler = require("PlayerHandler")
local PlayerClass = require("Player")
```

A module can be in any subfolder under `Flux/server`, `Flux/client`, or `Shared`. Duplicate module names are an error. Every ModuleScript must return exactly one value, as usual in Roblox.

`Flux.require(name)` is the same loader exposed on the `Flux` table.

On the client, `shared.import` and `shared.Flux` are removed after `CoreHandler` finishes. Capture them locally during module load:

```lua
local import = shared.import
local network = import("network")
```

After that, later LocalScripts cannot import the network link through `shared`. This is cleanup, not a security boundary: client code, client memory, and client-side checks can always be inspected or bypassed.

On the server, `shared.import` and `shared.Flux` stay available. Another server script that uses them should wait for the entry script:

```lua
while not shared.Flux do
	task.wait()
end
```

## API

### Flux

- `Flux.import(...)` — import built-in packages by name. `Flux.import("network")` returns the network link. Multiple names return multiple values.
- `Flux.require(name)` — require a module from the entry script or `Shared` using the recursive loader.
- `Flux.validate(schema, handler, label?)` — server only. Wrap a handler with strict argument validation. Invalid input kicks the player and reports a violation.
- `Flux.validateLenient(schema, handler, label?)` — server only. Same validation, but drops invalid calls instead of kicking.
- `Flux.check(rule, value)` — server only. Validate one value. Returns `true` or `false, reason`.
- `Flux.secure(options, handler)` — server only. Validate arguments, run an authorization guard, then call the handler. See below.
- `Flux.guard(guard, handler, label?)` — server only. Shorthand for `Flux.secure({ guard = guard, name = label }, handler)`.
- `Flux.onViolation(callback)` — server only. Replace the violation logger. Pass `nil` to restore the default.

### network

Client:

- `network:on(name, handler)` — handle an event sent by the server. The handler receives the event arguments.
- `network:fire(name, ...)` — send an event to the server.
- `network:invoke(name, ...)` — call a server function and return its result.
- `network:invokeClient` does not exist. Server-to-client requests must be event-based if a game ever needs them.

Server:

- `network:on(name, handler, options?)` — handle an event sent by the client. The handler receives `(player, ...)`.
- `network:onCall(name, handler, options?)` — handle a function called by the client. The handler receives `(player, ...)` and its return value goes back to the caller.
- `network:fireClient(player, name, ...)`
- `network:fireAllClients(name, ...)`
- `network:fireAllClientsExcept(exception, name, ...)`

Events and functions are separate channels. A client event cannot call a server function and a client function call cannot trigger a server event.

`options.rate` sets a per-action token bucket:

```lua
network:on("shoot", function(player)
	-- ...
end, { rate = { capacity = 10, window = 1 } })
```

The default is 60 calls per second per action. The global backstop is 120 calls per second per player. Rate-limit violations and unknown action names are dropped and reported, not kicked. Forged tokens, malformed protocol fields, and oversized payloads kick.

### Validation schema

Each rule is a type string or a table:

```lua
network:onCall("buy", Flux.validate({
	{ type = "string", name = "item", length = { min = 1, max = 32 } },
	{ type = "number", name = "count", integer = true, min = 1, max = 100 },
}, function(player, item, count)
	-- item and count are safe to use
end))
```

Rules:

- `type`: `"any"`, `"string"`, `"number"`, `"boolean"`, `"table"`, `"function"`, `"Instance"`, `"Player"`.
- `optional`: allow `nil`.
- `integer`, `min`, `max` for numbers. `NaN` and infinity are always rejected.
- `length = { min, max }` and `pattern` for strings.
- `enum = { ... }` for a fixed set of values.
- `className` and `ancestor` for `Instance`. `className` checks `IsA`; `ancestor` checks `IsDescendantOf`.
- `check = function(value) return boolean end` for custom rules.
- `name`: label used in error messages and violation reports.

`Flux.validate` is argument shape checking, not authorization. It does not know whether this player owns the item, is near the shop, is alive, or has enough currency. Use `Flux.secure` or a guard for that.

```lua
network:onCall("buy", Flux.secure({
	name = "buy",
	schema = {
		{ type = "string", name = "item", length = { min = 1, max = 32 } },
		{ type = "number", name = "count", integer = true, min = 1, max = 100 },
	},
	guard = function(player, item, count)
		if count > 10 then
			return false, "count too high"
		end
		return true
	end,
}, function(player, item, count)
	-- authorization passed; perform the purchase on the server
end))
```

A guard must return `true` to allow the call. Returning `false` or `nil` denies it. Returning `false, reason` records the reason. A guard that throws an error also denies the call. Denials are reported through `Flux.onViolation` and do not kick by default.

`Flux.secure` options:

- `name`: label used in reports.
- `schema`: optional argument schema.
- `guard`: optional authorization function.
- `strict`: when `true`, schema failures kick instead of being dropped. The default is `false`.

Errors are written with `warn` unless a game replaces the logger:

```lua
Flux.onViolation(function(player, action, reason)
	-- use player.UserId, not the display name
	analytics:track("flux_violation", {
		userId = player.UserId,
		action = action,
		reason = reason,
	})
end)
```

The handler is called through `pcall`; a broken logger cannot break the game. Do not log tokens, keys, or unrelated player data.

### Payload limits

The network layer rejects payloads that exceed:

- 32 arguments;
- 4096 bytes per string;
- 256 table entries, counting keys and values;
- 6 levels of table nesting;
- any `NaN` or infinity.

These limits apply before validation. Paginate or chunk large data instead of raising the limits globally.

### Protocol behavior

On join, the server issues a high-entropy master key, derives separate keys for events and functions, and discards the master. Every client-to-server message carries a counter and a digest bound to the event or function name. The server accepts out-of-order counters inside a 1000-step window and rejects reused counters. Keys rotate every 60 seconds; the previous key is accepted for 10 seconds for messages already in flight. An epoch prevents an older key from overriding a newer one.

A failed or rejected handshake does not leave the client waiting forever: the next `fire` or `invoke` raises `Flux: handshake failed`.

## Security

The token layer is protocol hygiene, not a security boundary. It stops accidental malformed traffic and naive replay, but a cheater who controls the client can read the keys from memory, call the network link directly, and produce valid messages. The digest is an FNV-style lightweight function, not a cryptographic MAC. Do not describe it as encryption or authentication.

The real boundary is server authority:

- validate shape, type, range, length, and `Instance` class or ancestor with `Flux.validate` or `Flux.secure`;
- authorize the action against server state: ownership, distance, cooldown, inventory, currency, alive state;
- never trust a client-provided price, reward, stat, cooldown, or success flag;
- keep economy, drop rates, and rule constants in server-only code;
- rate-limit expensive actions and chunk large payloads;
- use `UserId` in logs, not player names.

`ReplicatedStorage` and `Shared` are visible to clients. Server modules under `Flux/server` and `ServerStorage` are not. Removing `shared.import` on the client is only cleanup; it is not access control.

Kicks are a response to protocol violations, not a security guarantee. A determined cheater can rejoin. The server must stay correct even when a client sends valid-looking messages.

## Packages

The packages keep the original Flux API, but their implementations are independent. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

| Package | Runs on | Notes |
| --- | --- | --- |
| `require` | server and client | Recursive module loader for the entry script and `Shared`. |
| `tween` | server and client | `tween(object, properties, duration, style, direction, count, reverses, delay)`. |
| `element` | client | `element(selector)` searches `PlayerGui`; `element(root, selector)` searches a specific root. Selectors use `#name` (instance name is `#name`), `$name` (exact name), `%ClassName` (class), and can be chained. |
| `tagged` | server and client | `tagged(tag, ...)` returns instances with the given CollectionService tags. |
| `asset` | server and client | `asset(name, parent?)` returns an asset from `ReplicatedStorage.Assets`; on the server it also scans `ServerStorage.Assets`. The client never requests `ServerStorage`. |
| `quality` | client | `quality()` returns the saved graphics quality level. |

## Testing

Run the local test suite with Luau 0.748 or newer:

```bash
python tests/build.py
luau tests/.build/run.lua
```

The build script embeds the real server, client, and package sources into one test bundle. The suite covers event/function separation, token binding, replay and counter windows, NaN and payload limits, rate limits, guards, `Instance` rules, handshake failure, rotation, the module loader, every package, and server/client package boundaries.

CI runs the tests, compiles every `.lua` file, and builds the place file. The release workflow repeats the checks before publishing.

To verify a release download:

```bash
sha256sum -c FluxNext.rbxl.sha256
```

## License and provenance

The original code in this repository is licensed under the MIT License; see [LICENSE](LICENSE). The Flux name and the original Flux Framework are not licensed by this project. Historical releases before v0.3.0 were removed; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Security reports

See [SECURITY.md](SECURITY.md) for the threat model, scope, and reporting instructions. AI coding assistants working in this repository should follow [AGENTS.md](AGENTS.md).

## Layout

```
src/
  ReplicatedStorage/
    Packages/
      require/
        init.lua
      asset/
      element/
      quality/
      tagged/
      tween/
    Shared/
  ServerScriptService/
    Flux/
      init.server.lua
      Core/
        CoreHandler.lua
      Classes/
      Handlers/
  StarterPlayer/
    StarterPlayerScripts/
      Flux/
        init.client.lua
        Core/
          CoreHandler.lua
        Classes/
        Handlers/
```
