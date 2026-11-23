local tests = 0
local failures = 0

local function fail(message, level)
	error(message, (level or 2) + 1)
end

local function assertTrue(value, message)
	if not value then
		fail(message or "expected a truthy value", 2)
	end
end

local function assertNil(value, message)
	if value ~= nil then
		fail((message or "expected nil") .. ", got " .. tostring(value), 2)
	end
end

local function assertEqual(actual, expected, message)
	if actual ~= expected then
		fail((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

local function assertMatch(value, pattern, message)
	if type(value) ~= "string" or not string.find(value, pattern, 1, true) then
		fail((message or "pattern mismatch") .. ": " .. tostring(value) .. " does not match " .. tostring(pattern), 2)
	end
end

local function test(name, callback)
	tests += 1
	local ok, err = pcall(callback)
	if ok then
		print("PASS " .. name)
	else
		failures += 1
		print("FAIL " .. name .. "\n     " .. tostring(err))
	end
end

local HASH_A = 2166136261
local HASH_B = 4278190080
local PRIME = 16777619
local MODULUS = 4294967296

local function mul32(a, b)
	local low = a % 65536
	local high = (a - low) / 65536
	return (low * b + (high * b % 65536) * 65536) % MODULUS
end

local function checksum(salt, counter, name)
	local data = salt .. ":" .. tostring(counter) .. ":" .. name
	local a, b = HASH_A, HASH_B
	for index = 1, #data do
		local byte = string.byte(data, index)
		a = mul32(bit32.bxor(a, byte), PRIME)
		b = mul32(bit32.bxor(b, byte + index), PRIME)
	end
	return string.format("%08x%08x", a, b)
end

local function checksumFor(seed, kind, counter, name)
	local salt = checksum(seed, "salt", kind)
	return checksum(salt, counter, name)
end

local function kicked(env)
	return Mock.kicked[env.player.UserId]
end

local function lastViolation()
	return Mock.violations[#Mock.violations]
end

local function violationReason()
	local violation = lastViolation()
	return violation and violation.reason or ""
end

local function payloadRejected(label, createValue, pattern)
	local env = Mock.setup()
	local calls = 0
	env.server:on("data", function()
		calls += 1
	end)
	env.client:fire("data", createValue())
	assertMatch(kicked(env), pattern, label .. ": kick")
	assertEqual(calls, 0, label .. ": handler calls")
end

test("event and function channels are separate", function()
	local env = Mock.setup()
	local eventCalls = 0
	local functionCalls = 0

	env.server:on("eventOnly", function(player, value)
		eventCalls += 1
		return value
	end)
	env.server:onCall("callOnly", function(player, value)
		functionCalls += 1
		return value * 2
	end)

	assertNil(env.client:fire("eventOnly", 5))
	assertEqual(eventCalls, 1)
	assertEqual(env.client:invoke("callOnly", 5), 10)
	assertEqual(functionCalls, 1)

	assertNil(env.client:invoke("eventOnly", 5), "events must not be callable")
	assertEqual(eventCalls, 1)
	assertNil(env.client:fire("callOnly", 5), "functions must not be fireable")
	assertEqual(functionCalls, 1)
	assertNil(kicked(env), "valid traffic must not kick")
end)

test("client only exposes event handlers", function()
	local env = Mock.setup()
	assertTrue(type(env.server.onCall) == "function")
	assertNil(env.server.invokeClient)
	assertNil(env.client.onCall)
	assertNil(env.client.invokeClient)
end)

test("server to client events", function()
	local env = Mock.setup()
	local messages = {}

	env.client:on("toast", function(message)
		messages[#messages + 1] = message
	end)

	env.server:fireClient(env.player, "toast", "one")
	env.server:fireAllClients("toast", "two")
	env.server:fireAllClientsExcept(env.player, "toast", "three")
	assertEqual(#messages, 2)
	assertEqual(messages[1], "one")
	assertEqual(messages[2], "two")

	local other = Mock.newPlayer("Player2", 2)
	Mock.players[2] = other
	env.server:fireAllClientsExcept(other, "toast", "four")
	assertEqual(#messages, 3)
	assertEqual(messages[3], "four")
end)

test("function results preserve multiple returns", function()
	local env = Mock.setup()
	env.server:onCall("multi", function()
		return 1, nil, 3
	end)
	local first, second, third = env.client:invoke("multi")
	assertEqual(first, 1)
	assertNil(second)
	assertEqual(third, 3)
end)

test("checksums are bound to the action name", function()
	local env = Mock.setup()
	local calls = 0
	env.server:on("alpha", function()
		calls += 1
	end)
	env.server:on("beta", function()
		calls += 1
	end)

	local event = Mock.remote("Event")
	event.OnServerEvent:Fire(env.player, 1, checksumFor(env.seed, "event", 1, "alpha"), "beta", 1)
	assertMatch(kicked(env), "bad checksum")
	assertEqual(calls, 0)

	local control = Mock.setup()
	local accepted = 0
	control.server:on("alpha", function()
		accepted += 1
	end)
	Mock.remote("Event").OnServerEvent:Fire(
		control.player,
		1,
		checksumFor(control.seed, "event", 1, "alpha"),
		"alpha",
		1
	)
	assertNil(kicked(control))
	assertEqual(accepted, 1)
end)

test("event and function salts are separate", function()
	local env = Mock.setup()
	env.server:on("eventOnly", function() end)
	env.server:onCall("callOnly", function()
		return true
	end)

	local eventChecksum = checksumFor(env.seed, "event", 1, "eventOnly")
	local result = Mock.remote("Function"):InvokeServer(1, eventChecksum, "callOnly")
	assertNil(result)
	assertMatch(kicked(env), "bad checksum")
end)

test("replayed counters are rejected", function()
	local env = Mock.setup()
	local calls = 0
	env.server:on("ping", function()
		calls += 1
	end)

	local event = Mock.remote("Event")
	local eventChecksum = checksumFor(env.seed, "event", 1, "ping")
	event.OnServerEvent:Fire(env.player, 1, eventChecksum, "ping")
	assertEqual(calls, 1)
	assertNil(kicked(env))

	event.OnServerEvent:Fire(env.player, 1, eventChecksum, "ping")
	assertMatch(kicked(env), "replayed counter")
	assertEqual(calls, 1)
end)

test("counters may arrive out of order inside the window", function()
	local env = Mock.setup()
	local total = 0
	env.server:on("ping", function(player, value)
		total += value
	end)

	local event = Mock.remote("Event")
	event.OnServerEvent:Fire(env.player, 2, checksumFor(env.seed, "event", 2, "ping"), "ping", 10)
	event.OnServerEvent:Fire(env.player, 1, checksumFor(env.seed, "event", 1, "ping"), "ping", 1)
	assertNil(kicked(env))
	assertEqual(total, 11)
end)

test("counters outside the window are rejected", function()
	local env = Mock.setup()
	env.server:on("ping", function() end)
	Mock.remote("Event").OnServerEvent:Fire(
		env.player,
		1001,
		checksumFor(env.seed, "event", 1001, "ping"),
		"ping"
	)
	assertMatch(kicked(env), "stale counter")
end)

test("malformed protocol fields are rejected", function()
	local cases = {
		{ label = "counter type", counter = "1", eventChecksum = "deadbeefdeadbeef", name = "ping", pattern = "malformed checksum" },
		{ label = "checksum length", counter = 1, eventChecksum = "short", name = "ping", pattern = "malformed checksum" },
		{ label = "fractional counter", counter = 1.5, eventChecksum = "deadbeefdeadbeef", name = "ping", pattern = "malformed checksum" },
		{ label = "zero counter", counter = 0, eventChecksum = "deadbeefdeadbeef", name = "ping", pattern = "malformed checksum" },
		{ label = "infinite counter", counter = math.huge, eventChecksum = "deadbeefdeadbeef", name = "ping", pattern = "malformed checksum" },
		{ label = "long action name", counter = 1, eventChecksum = "deadbeefdeadbeef", name = string.rep("x", 129), pattern = "malformed action name" },
		{ label = "empty action name", counter = 1, eventChecksum = "deadbeefdeadbeef", name = "", pattern = "malformed action name" },
	}

	for _, case in ipairs(cases) do
		local env = Mock.setup()
		env.server:on("ping", function() end)
		Mock.remote("Event").OnServerEvent:Fire(env.player, case.counter, case.eventChecksum, case.name)
		assertMatch(kicked(env), case.pattern, case.label)
	end
end)

test("NaN and infinity fail numeric validation", function()
	local function rejected(label, value)
		local env = Mock.setup()
		local calls = 0
		env.server:onCall("number", env.flux.validate({
			{ type = "number", name = "value", min = 0, max = 100 },
		}, function(player, number)
			calls += 1
			return number
		end))

		env.client:invoke("number", value)
		assertMatch(kicked(env), "finite", label)
		assertEqual(calls, 0, label)
	end

	rejected("NaN", math.huge - math.huge)
	rejected("infinity", math.huge)
	rejected("negative infinity", -math.huge)

	local env = Mock.setup()
	assertEqual(env.flux.check({ type = "number" }, math.huge - math.huge), false)
	assertEqual(env.flux.check({ type = "number" }, math.huge), false)
end)

test("payload limits", function()
	payloadRejected("long string", function()
		return string.rep("x", 4097)
	end, "string too long")

	payloadRejected("large table", function()
		local value = {}
		for index = 1, 300 do
			value[index] = index
		end
		return value
	end, "table too large")

	payloadRejected("deep table", function()
		local root = {}
		local cursor = root
		for _ = 1, 8 do
			cursor.next = {}
			cursor = cursor.next
		end
		return root
	end, "table too deep")

	payloadRejected("non finite number", function()
		return math.huge - math.huge
	end, "non-finite number")

	payloadRejected("total string bytes", function()
		local value = {}
		for index = 1, 5 do
			value[index] = string.rep("x", 4096)
		end
		return value
	end, "payload too large")

	local env = Mock.setup()
	local calls = 0
	env.server:on("data", function()
		calls += 1
	end)
	env.client:fire("data", string.rep("x", 4096))
	assertNil(kicked(env))
	assertEqual(calls, 1)

	local atLimit = Mock.setup()
	local atLimitCalls = 0
	atLimit.server:on("data", function()
		atLimitCalls += 1
	end)
	local strings = {}
	for index = 1, 4 do
		strings[index] = string.rep("x", 4096)
	end
	atLimit.client:fire("data", table.unpack(strings, 1, 4))
	assertNil(kicked(atLimit))
	assertEqual(atLimitCalls, 1)

	local many = Mock.setup()
	local manyCalls = 0
	many.server:on("data", function()
		manyCalls += 1
	end)
	local arguments = {}
	for index = 1, 33 do
		arguments[index] = index
	end
	many.client:fire("data", table.unpack(arguments, 1, 33))
	assertMatch(kicked(many), "too many arguments")
	assertEqual(manyCalls, 0)
end)

test("per action rate limits drop without kicking", function()
	local env = Mock.setup()
	local calls = 0
	env.server:on("spam", function()
		calls += 1
	end, { rate = { capacity = 3, window = 1 } })

	for index = 1, 3 do
		env.client:fire("spam", index)
	end
	assertEqual(calls, 3)
	assertNil(kicked(env))

	env.client:fire("spam", 4)
	assertEqual(calls, 3)
	assertNil(kicked(env))
	assertMatch(violationReason(), "rate limit exceeded")

	Mock.advance(1)
	env.client:fire("spam", 5)
	assertEqual(calls, 4)
	assertNil(kicked(env))
end)

test("global call limit drops without kicking", function()
	local env = Mock.setup()
	local calls = 0
	env.server:on("flood", function()
		calls += 1
	end, { rate = { capacity = 1000, window = 1 } })

	for index = 1, 120 do
		env.client:fire("flood", index)
	end
	assertEqual(calls, 120)
	assertNil(kicked(env))

	env.client:fire("flood", 121)
	assertEqual(calls, 120)
	assertNil(kicked(env))
	assertMatch(violationReason(), "global calls per second exceeded")

	Mock.advance(1)
	env.client:fire("flood", 122)
	assertEqual(calls, 121)
end)

test("secure runs schema, guard, and handler in order", function()
	local env = Mock.setup()
	local calls = 0

	env.server:onCall("buy", env.flux.secure({
		name = "buy",
		schema = {
			{ type = "string", name = "item" },
		},
		guard = function(player, item)
			if item == "sword" then
				return true
			end
			return false, "not allowed"
		end,
	}, function(player, item)
		calls += 1
		return item
	end))

	assertEqual(env.client:invoke("buy", "sword"), "sword")
	assertEqual(calls, 1)

	assertNil(env.client:invoke("buy", "potion"))
	assertEqual(calls, 1)
	assertMatch(violationReason(), "not allowed")
	assertNil(kicked(env))

	assertNil(env.client:invoke("buy", 5))
	assertEqual(calls, 1)
	assertMatch(violationReason(), "expected string")
	assertNil(kicked(env))
end)

test("guards fail closed", function()
	local env = Mock.setup()
	local calls = 0

	env.server:onCall("explode", env.flux.secure({
		name = "explode",
		guard = function()
			error("boom")
		end,
	}, function()
		calls += 1
	end))
	env.client:invoke("explode")
	assertEqual(calls, 0)
	assertMatch(violationReason(), "guard failed")
	assertMatch(violationReason(), "boom")
	assertNil(kicked(env))

	local denied = Mock.setup()
	local deniedCalls = 0
	denied.server:onCall("guarded", denied.flux.guard(function()
		return false
	end, function()
		deniedCalls += 1
	end, "guarded"))
	denied.client:invoke("guarded")
	assertEqual(deniedCalls, 0)
	assertMatch(violationReason(), "authorization denied")
	assertNil(kicked(denied))
end)

test("guards allow only boolean true", function()
	local env = Mock.setup()
	local calls = 0
	env.server:onCall("guarded", env.flux.guard(function()
		return "yes"
	end, function()
		calls += 1
	end, "guarded"))
	env.client:invoke("guarded")
	assertEqual(calls, 0)
	assertMatch(violationReason(), "authorization denied")
	assertNil(kicked(env))
end)

test("secure validation can be strict", function()
	local env = Mock.setup()
	local calls = 0
	env.server:onCall("strict", env.flux.secure({
		name = "strict",
		strict = true,
		schema = {
			{ type = "string" },
		},
	}, function()
		calls += 1
	end))
	env.client:invoke("strict", 1)
	assertEqual(calls, 0)
	assertMatch(kicked(env), "invalid argument")
end)

test("Instance rules check class and ancestor", function()
	local env = Mock.setup()
	local shop = Mock.newFolder("Shop")
	shop.Parent = Mock.services.Workspace
	local sword = Mock.newPart("Sword")
	sword.Parent = shop
	local calls = 0

	env.server:onCall("use", env.flux.validate({
		{ type = "Instance", className = "Part", ancestor = shop, name = "item" },
	}, function(player, item)
		calls += 1
		return item.Name
	end))

	assertEqual(env.client:invoke("use", sword), "Sword")
	assertEqual(calls, 1)
	assertNil(kicked(env))
	assertNil(kicked(env))

	local wrongClass = Mock.setup()
	local wrongClassShop = Mock.newFolder("Shop")
	wrongClassShop.Parent = Mock.services.Workspace
	local box = Mock.newFolder("Box")
	box.Parent = wrongClassShop
	wrongClass.server:onCall("use", wrongClass.flux.validate({
		{ type = "Instance", className = "Part", ancestor = wrongClassShop },
	}, function()
		error("must not run")
	end))
	wrongClass.client:invoke("use", box)
	assertMatch(kicked(wrongClass), "expected Part")

	local wrongAncestor = Mock.setup()
	local allowed = Mock.newFolder("Shop")
	allowed.Parent = Mock.services.Workspace
	local stray = Mock.newPart("Sword")
	stray.Parent = Mock.services.Workspace
	wrongAncestor.server:onCall("use", wrongAncestor.flux.validate({
		{ type = "Instance", className = "Part", ancestor = allowed },
	}, function()
		error("must not run")
	end))
	wrongAncestor.client:invoke("use", stray)
	assertMatch(kicked(wrongAncestor), "outside the allowed container")
end)

test("Player instance validation", function()
	local env = Mock.setup()
	env.server:onCall("who", env.flux.validate({
		{ type = "Player" },
	}, function(player, target)
		return target.UserId
	end))
	assertEqual(env.client:invoke("who", env.player), 1)
end)

test("validation helpers", function()
	local env = Mock.setup()
	assertEqual(env.flux.check({ type = "number", min = 1, max = 3 }, 2), true)
	assertEqual(env.flux.check({ type = "number", min = 1, max = 3 }, 4), false)
	assertEqual(env.flux.check({ type = "number", optional = true }, nil), true)
	assertEqual(env.flux.check({ type = "string", length = { min = 2, max = 4 } }, "a"), false)
	assertEqual(env.flux.check({ type = "string", pattern = "^%d+$" }, "12"), true)
	assertEqual(env.flux.check({ type = "string", pattern = "^%d+$" }, "x"), false)
	assertEqual(env.flux.check({ enum = { "a", "b" } }, "a"), true)
	assertEqual(env.flux.check({ enum = { "a", "b" } }, "c"), false)
	assertEqual(env.flux.check({ check = function()
		return false
	end }, 1), false)
	assertEqual(env.flux.check({ check = function()
		error("boom")
	end }, 1), false)
end)

test("strict and lenient validation", function()
	local strict = Mock.setup()
	local strictCalls = 0
	strict.server:onCall("strict", strict.flux.validate({
		{ type = "string" },
	}, function()
		strictCalls += 1
	end))
	strict.client:invoke("strict", 5)
	assertEqual(strictCalls, 0)
	assertMatch(kicked(strict), "invalid argument")

	local lenient = Mock.setup()
	local lenientCalls = 0
	lenient.server:onCall("lenient", lenient.flux.validateLenient({
		{ type = "string" },
	}, function()
		lenientCalls += 1
	end))
	lenient.client:invoke("lenient", 5)
	assertEqual(lenientCalls, 0)
	assertNil(kicked(lenient))
	assertMatch(violationReason(), "expected string")
end)

test("extra arguments are rejected", function()
	local strict = Mock.setup()
	local strictCalls = 0
	strict.server:onCall("strictExtra", strict.flux.validate({
		{ type = "string" },
	}, function()
		strictCalls += 1
	end))
	strict.client:invoke("strictExtra", "ok", "extra")
	assertEqual(strictCalls, 0)
	assertMatch(kicked(strict), "invalid argument count")

	local lenient = Mock.setup()
	local lenientCalls = 0
	lenient.server:onCall("lenientExtra", lenient.flux.validateLenient({
		{ type = "string" },
	}, function()
		lenientCalls += 1
	end))
	lenient.client:invoke("lenientExtra", "ok", "extra")
	assertEqual(lenientCalls, 0)
	assertNil(kicked(lenient))
	assertMatch(violationReason(), "invalid argument count")
end)

test("registration rejects invalid handlers", function()
	local env = Mock.setup()
	local callback = function() end

	assertEqual(pcall(env.server.on, env.server, "", callback), false)
	assertEqual(pcall(env.server.on, env.server, "x", nil), false)
	assertEqual(pcall(env.server.on, env.server, "x", callback, { rate = { capacity = 0, window = 1 } }), false)
	assertEqual(pcall(env.server.on, env.server, "x", callback, { rate = { capacity = math.huge, window = 1 } }), false)
	assertEqual(pcall(env.server.onCall, env.server, "x", callback), true)
	assertEqual(pcall(env.client.on, env.client, "x", nil), false)
	assertEqual(pcall(env.flux.validate, {}, nil), false)
	assertEqual(pcall(env.flux.validate, "schema", callback), false)
	assertEqual(pcall(env.flux.onViolation, "callback"), false)
	assertEqual(pcall(env.flux.secure, {}, nil), false)
	assertEqual(pcall(env.flux.secure, { guard = "guard" }, callback), false)
	assertEqual(pcall(env.flux.secure, { schema = "schema" }, callback), false)
	assertEqual(pcall(env.flux.guard, nil, callback), false)
end)

test("violation handler errors are contained", function()
	local env = Mock.setup()
	env.flux.onViolation(function()
		error("callback boom")
	end)
	env.client:invoke("missing")
	assertNil(kicked(env))
	assertTrue(#Mock.warnings > 0)
	assertMatch(Mock.warnings[#Mock.warnings], "violation handler failed")
end)

test("client action names are sanitized in logs", function()
	local env = Mock.setup()
	env.server:on("ping", function() end)
	env.client:fire("bad\nFAKE\\NAME")
	local violation = lastViolation()
	assertTrue(violation ~= nil)
	assertEqual(string.find(violation.action, "\n", 1, true), nil)
	assertMatch(violation.action, "\\x0a")
	assertMatch(violation.action, "\\\\")
end)

test("default violation logger aggregates repeated reasons", function()
	local env = Mock.setup()
	env.flux.onViolation(nil)
	env.server:on("ping", function() end)

	for index = 1, 5 do
		env.client:fire("missing" .. index)
	end

	local count = 0
	for _, warning in ipairs(Mock.warnings) do
		if string.find(warning, "unknown event", 1, true) then
			count += 1
		end
	end
	assertEqual(count, 1)

	Mock.advance(1)
	env.client:fire("missing6")
	assertMatch(Mock.warnings[#Mock.warnings], "4 similar suppressed")
end)

test("handshake failure raises instead of hanging", function()
	Mock.reset()
	Mock.bootServer()
	local handshake = Mock.remote("Handshake")
	handshake.OnServerInvoke = nil
	local clientFlux, clientImport = Mock.bootClient()
	local client = clientImport("network")
	assertTrue(clientFlux ~= nil)
	local ok, err = pcall(function()
		client:fire("anything")
	end)
	assertTrue(not ok)
	assertMatch(tostring(err), "handshake failed")
end)

test("duplicate handshake is rejected", function()
	local env = Mock.setup()
	local ok = pcall(function()
		Mock.remote("Handshake"):InvokeServer()
	end)
	assertTrue(ok)
	assertMatch(kicked(env), "duplicate handshake")
end)

test("removed player sessions are closed", function()
	local env = Mock.setup()
	env.server:on("ping", function() end)
	Mock.playersService.PlayerRemoving:Fire(env.player)
	Mock.remote("Event").OnServerEvent:Fire(
		env.player,
		1,
		checksumFor(env.seed, "event", 1, "ping"),
		"ping"
	)
	assertNil(kicked(env))
	assertMatch(violationReason(), "no session")
end)

test("salt rotation keeps traffic working", function()
	local env = Mock.setup()
	local legacy = nil
	env.server:onCall("echo", function(player, value)
		return value
	end)
	env.server:on("legacy", function(player, value)
		legacy = value
	end)

	assertEqual(env.client:invoke("echo", 1), 1)

	local rotate = Mock.remote("Rotate")
	Mock.advance(60)
	Mock.advance(0)
	assertTrue(rotate.lastArgs ~= nil)
	local nextSeed = rotate.lastArgs[1]
	local nextEpoch = rotate.lastArgs[2]
	assertTrue(nextSeed ~= env.seed)
	assertEqual(nextEpoch, 1)
	assertEqual(env.client:invoke("echo", 2), 2)

	rotate:FireClient(env.player, env.seed, 0)
	assertEqual(env.client:invoke("echo", 3), 3)

	Mock.advance(5)
	Mock.remote("Event").OnServerEvent:Fire(
		env.player,
		1,
		checksumFor(env.seed, "event", 1, "legacy"),
		"legacy",
		9
	)
	assertNil(kicked(env))
	assertEqual(legacy, 9)

	Mock.advance(6)
	Mock.remote("Event").OnServerEvent:Fire(
		env.player,
		2,
		checksumFor(env.seed, "event", 2, "legacy"),
		"legacy",
		10
	)
	assertMatch(kicked(env), "bad checksum")
end)

test("client clears shared handles", function()
	local env = Mock.setup()
	assertNil(shared.Flux)
	assertNil(shared.import)
	assertTrue(type(Mock.lastFlux) == "table")
	assertTrue(type(Mock.lastFlux.import) == "function")
	assertTrue(type(Mock.lastImport) == "function")
	assertEqual(env.client:invoke("missing"), nil)
end)

test("require loader scans server modules and Shared", function()
	Mock.reset()
	local loader = Mock.load("require")
	assertEqual(loader("CoreHandler").name, "CoreHandler")
	assertEqual(loader("Util").name, "Util")
	assertEqual(loader("Deep").name, "Deep")

	local util, deep = loader("Util", "Deep")
	assertEqual(util.name, "Util")
	assertEqual(deep.name, "Deep")

	local ok, err = pcall(loader, "Missing")
	assertTrue(not ok)
	assertMatch(tostring(err), "unknown module")
end)

test("require loader rejects duplicate modules", function()
	Mock.reset()
	local sharedFolder = Mock.services.ReplicatedStorage:FindFirstChild("Shared")
	local duplicate = Mock.newInstance("ModuleScript", "Util")
	duplicate._value = {}
	duplicate.Parent = sharedFolder
	local ok, err = pcall(Mock.load, "require")
	assertTrue(not ok)
	assertMatch(tostring(err), "duplicate module 'Util'")
end)

test("require loader uses the client script tree", function()
	Mock.reset()
	Mock.playersService.LocalPlayer = Mock.player
	local loader = Mock.load("require")
	assertEqual(loader("CoreHandler").name, "CoreHandler")
end)

test("asset package keeps ServerStorage on the server", function()
	Mock.reset()
	local serverAssets = Mock.newFolder("Assets")
	serverAssets.Parent = Mock.services.ServerStorage
	local sword = Mock.newPart("Sword")
	sword.Parent = serverAssets

	local sharedAssets = Mock.newFolder("Assets")
	sharedAssets.Parent = Mock.services.ReplicatedStorage
	local potion = Mock.newPart("Potion")
	potion.Parent = sharedAssets

	local asset = Mock.load("asset")
	assertEqual(asset("Sword"), sword)
	assertEqual(asset("Potion"), potion)
	assertEqual(asset("Potion", sharedAssets), potion)
	assertEqual(Mock.serviceCalls.ServerStorage, 1)

	Mock.reset()
	Mock.playersService.LocalPlayer = Mock.player
	local clientAssets = Mock.newFolder("Assets")
	clientAssets.Parent = Mock.services.ReplicatedStorage
	local gem = Mock.newPart("Gem")
	gem.Parent = clientAssets
	local clientAsset = Mock.load("asset")
	assertEqual(clientAsset("Gem"), gem)
	assertNil(Mock.serviceCalls.ServerStorage)
end)

test("asset package indexes nested assets and prefers shared names", function()
	Mock.reset()
	local serverAssets = Mock.newFolder("Assets")
	serverAssets.Parent = Mock.services.ServerStorage
	local serverSword = Mock.newPart("Sword")
	serverSword.Parent = serverAssets

	local sharedAssets = Mock.newFolder("Assets")
	sharedAssets.Parent = Mock.services.ReplicatedStorage
	local nested = Mock.newFolder("Nested")
	nested.Parent = sharedAssets
	local potion = Mock.newPart("Potion")
	potion.Parent = nested
	local sharedSword = Mock.newPart("Sword")
	sharedSword.Parent = sharedAssets

	local asset = Mock.load("asset")
	assertEqual(asset("Sword"), sharedSword)
	assertEqual(asset("Potion"), potion)
end)

test("tagged package collects instances by tag", function()
	Mock.reset()
	local collection = Mock.services.CollectionService
	local alpha = Mock.newPart("Alpha")
	local beta = Mock.newPart("Beta")
	collection:AddTag(alpha, "Loot")
	collection:AddTag(beta, "Loot")
	collection:AddTag(beta, "Interact")

	local tagged = Mock.load("tagged")
	local loot = tagged("Loot")
	assertEqual(#loot, 2)
	assertEqual(loot[1], alpha)
	assertEqual(loot[2], beta)

	local combined = tagged("Loot", "Interact")
	assertEqual(#combined, 3)
	assertEqual(combined[3], beta)
	assertEqual(#tagged("Missing"), 0)
end)

test("element package searches PlayerGui and follows selector chains", function()
	Mock.reset()
	Mock.playersService.LocalPlayer = Mock.player
	local gui = Mock.player:FindFirstChild("PlayerGui")
	local screen = Mock.newInstance("ScreenGui", "Main")
	screen.Parent = gui
	local early = Mock.newInstance("Frame", "Early")
	early.Parent = screen

	local element = Mock.load("element")
	local hud = Mock.newInstance("Frame", "HUD")
	hud.Parent = screen
	local button = Mock.newInstance("TextButton", "Play")
	button.Parent = hud
	local label = Mock.newInstance("TextLabel", "Title")
	label.Parent = button
	local first = Mock.newInstance("Frame", "Item")
	first.Parent = hud
	local second = Mock.newInstance("Frame", "Item")
	second.Parent = hud
	local tagged = Mock.newInstance("Frame", "#Tagged")
	tagged.Parent = hud

	assertEqual(element("$Early"), early)
	assertEqual(element("$HUD"), hud)
	assertEqual(element("%TextButton"), button)
	assertEqual(element("$HUD$Play"), button)
	assertEqual(element("$HUD#Tagged"), tagged)

	local items = element("$HUD$Item")
	assertEqual(#items, 2)
	assertEqual(items[1], first)
	assertEqual(items[2], second)

	assertEqual(element(gui, "$HUD"), hud)
	assertEqual(element(hud, "$Play"), button)
	assertEqual(#element("$Missing"), 0)
	assertEqual(#element("HUD"), 0)
end)

test("tween package replaces and forgets completed tweens", function()
	Mock.reset()
	local tween = Mock.load("tween")
	local part = Mock.newPart("Part")

	local first = tween(part, { Transparency = 1 }, 2)
	assertEqual(first.info.duration, 2)
	assertEqual(first.info.style, Enum.EasingStyle.Linear)
	assertEqual(first.info.direction, Enum.EasingDirection.Out)
	assertEqual(first.info.repeats, 0)
	assertEqual(first.info.reverses, false)
	assertEqual(first.info.delay, 0)
	assertTrue(first.played)

	local second = tween(part, { Transparency = 0 })
	assertTrue(first.cancelled)
	assertEqual(second.info.duration, 1)
	assertTrue(second.played)

	second.Completed:Fire()
	local third = tween(part, { Transparency = 0.5 }, 0.5)
	assertTrue(not second.cancelled)
	assertEqual(third.info.duration, 0.5)
	assertTrue(third.played)
end)

test("quality package reads the current saved level", function()
	Mock.reset()
	Mock.quality = 7
	local quality = Mock.load("quality")
	assertEqual(quality(), 7)
	Mock.quality = 3
	assertEqual(quality(), 3)
end)

test("package import caches modules and supports multiple names", function()
	local env = Mock.setup()
	local network, requirePackage = env.flux.import("network", "require")
	assertEqual(network, env.server)
	assertEqual(requirePackage, Mock.services.ReplicatedStorage.Packages.require._value)

	local counter = Mock.newInstance("ModuleScript", "counter")
	counter._value = {}
	counter.Parent = Mock.services.ReplicatedStorage.Packages
	local first = env.flux.import("counter")
	counter._value = {}
	assertEqual(env.flux.import("counter"), first)

	local ok, err = pcall(env.flux.import, "missing")
	assertTrue(not ok)
	assertMatch(tostring(err), "unknown package")
end)

print(string.format("%d tests, %d passed, %d failed", tests, tests - failures, failures))
if failures > 0 then
	error(string.format("%d test(s) failed", failures), 0)
end
