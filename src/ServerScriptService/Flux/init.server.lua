local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RATE_LIMIT = 120
local DEFAULT_RATE_CAPACITY = 60
local DEFAULT_RATE_WINDOW = 1
local TOKEN_WINDOW = 1000
local ROTATE_INTERVAL = 60
local ROTATE_GRACE = 10
local MAX_NAME = 128
local MAX_ARGS = 32
local MAX_STRING_BYTES = 4096
local MAX_TABLE_ENTRIES = 256
local MAX_TABLE_DEPTH = 6

local SEED_A = 2166136261
local SEED_B = 4278190080
local PRIME = 16777619
local MODULUS = 4294967296

local function mul32(a, b)
	local low = a % 65536
	local high = (a - low) / 65536
	return (low * b + (high * b % 65536) * 65536) % MODULUS
end

local function token(key, counter, name)
	local data = key .. ":" .. tostring(counter) .. ":" .. name
	local a, b = SEED_A, SEED_B
	for i = 1, #data do
		local byte = string.byte(data, i)
		a = mul32(bit32.bxor(a, byte), PRIME)
		b = mul32(bit32.bxor(b, byte + i), PRIME)
	end
	return string.format("%08x%08x", a, b)
end

local function generateKey()
	local rng = Random.new()
	local key = ""
	for _ = 1, 32 do
		key ..= string.format("%02x", rng:NextInteger(0, 255))
	end
	return key
end

local function deriveKeys(master)
	return {
		event = token(master, "key", "event"),
		["function"] = token(master, "key", "function"),
	}
end

local networkFolder = Instance.new("Folder")
networkFolder.Name = "Network"
networkFolder.Parent = ReplicatedStorage

local handshake = Instance.new("RemoteFunction")
handshake.Name = "Handshake"
handshake.Parent = networkFolder

local event = Instance.new("RemoteEvent")
event.Name = "Event"
event.Parent = networkFolder

local func = Instance.new("RemoteFunction")
func.Name = "Function"
func.Parent = networkFolder

local rotate = Instance.new("RemoteEvent")
rotate.Name = "Rotate"
rotate.Parent = networkFolder

local sessions = {}
local eventHandlers = {}
local functionHandlers = {}

local function defaultViolation(player, action, reason)
	warn(string.format(
		"Flux: %s from %s: %s",
		tostring(action),
		tostring(player and player.UserId or 0),
		tostring(reason)
	))
end

local violationHandler = defaultViolation

local function reportViolation(player, action, reason)
	local ok, err = pcall(violationHandler, player, action, reason)
	if not ok then
		warn("Flux: violation handler failed: " .. tostring(err))
	end
end

local function reject(player, action, reason)
	reportViolation(player, action, reason)
	pcall(function()
		player:Kick("Flux: " .. reason)
	end)
end

local function drop(player, action, reason)
	reportViolation(player, action, reason)
end

local function allowCall(session)
	local now = os.clock()
	if now - session.window >= 1 then
		session.window = now
		session.calls = 0
	end
	session.calls += 1
	return session.calls <= RATE_LIMIT
end

local function allowAction(session, name, rate)
	local capacity = rate and rate.capacity or DEFAULT_RATE_CAPACITY
	local window = rate and rate.window or DEFAULT_RATE_WINDOW
	local now = os.clock()
	local bucket = session.actions[name]
	if not bucket then
		bucket = { tokens = capacity, last = now }
		session.actions[name] = bucket
	else
		local elapsed = now - bucket.last
		if elapsed > 0 then
			bucket.tokens = math.min(capacity, bucket.tokens + elapsed * (capacity / window))
			bucket.last = now
		end
	end
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

local function rotateLater(player, session)
	task.delay(ROTATE_INTERVAL, function()
		if sessions[player] ~= session then
			return
		end
		local master = generateKey()
		session.previous = session.keys
		session.keys = deriveKeys(master)
		session.graceUntil = os.clock() + ROTATE_GRACE
		session.epoch += 1
		if not pcall(rotate.FireClient, rotate, player, master, session.epoch) then
			sessions[player] = nil
			return
		end
		rotateLater(player, session)
	end)
end

local function validateToken(session, kind, counter, proof, name)
	if type(counter) ~= "number" or not math.isfinite(counter) or counter % 1 ~= 0 or counter < 1 then
		return false, "malformed token"
	end
	if type(proof) ~= "string" or #proof ~= 16 then
		return false, "malformed token"
	end
	local last = session.counters[kind]
	if counter <= last - TOKEN_WINDOW or counter > last + TOKEN_WINDOW then
		return false, "stale token"
	end
	local seen = session.seen[kind]
	if seen[counter] then
		return false, "replayed token"
	end
	local ok = proof == token(session.keys[kind], counter, name)
	if not ok then
		local previous = session.previous
		if not previous or os.clock() > session.graceUntil or proof ~= token(previous[kind], counter, name) then
			return false, "bad token"
		end
	end
	seen[counter] = true
	if counter > last then
		session.counters[kind] = counter
		local lower = counter - TOKEN_WINDOW
		for value in pairs(seen) do
			if value <= lower then
				seen[value] = nil
			end
		end
	end
	return true
end

local function checkPayload(value, depth, budget, visited)
	local valueType = type(value)
	if valueType == "string" then
		if #value > MAX_STRING_BYTES then
			return false, "string too long"
		end
	elseif valueType == "number" then
		if not math.isfinite(value) then
			return false, "non-finite number"
		end
	elseif valueType == "table" then
		if depth > MAX_TABLE_DEPTH then
			return false, "table too deep"
		end
		if visited[value] then
			return true
		end
		visited[value] = true
		for key, item in pairs(value) do
			budget.entries += 1
			if budget.entries > MAX_TABLE_ENTRIES then
				return false, "table too large"
			end
			local ok, reason = checkPayload(key, depth + 1, budget, visited)
			if not ok then
				return false, reason
			end
			ok, reason = checkPayload(item, depth + 1, budget, visited)
			if not ok then
				return false, reason
			end
		end
	end
	return true
end

local function checkPayloadArgs(...)
	if select("#", ...) > MAX_ARGS then
		return false, "too many arguments"
	end
	local budget = { entries = 0 }
	local visited = {}
	for i = 1, select("#", ...) do
		local ok, reason = checkPayload(select(i, ...), 1, budget, visited)
		if not ok then
			return false, reason
		end
	end
	return true
end

local function handleCall(kind, player, counter, proof, name, ...)
	local session = sessions[player]
	if not session then
		drop(player, kind, "no session")
		return
	end
	if not allowCall(session) then
		local now = os.clock()
		if now - session.limitLog >= 1 then
			session.limitLog = now
			drop(player, "rate limit", "global calls per second exceeded")
		end
		return
	end
	if type(name) ~= "string" or name == "" or #name > MAX_NAME then
		reject(player, kind, "malformed action name")
		return
	end
	local channel = kind == "event" and eventHandlers or functionHandlers
	local entry = channel[name]
	if not entry then
		drop(player, name, "unknown " .. kind)
		return
	end
	local ok, reason = validateToken(session, kind, counter, proof, name)
	if not ok then
		reject(player, "token", reason)
		return
	end
	local payloadOk, payloadReason = checkPayloadArgs(...)
	if not payloadOk then
		reject(player, "payload", payloadReason)
		return
	end
	if not allowAction(session, name, entry.rate) then
		drop(player, name, "rate limit exceeded")
		return
	end
	return entry.handler(player, ...)
end

handshake.OnServerInvoke = function(player)
	if sessions[player] then
		reject(player, "handshake", "duplicate handshake")
		return
	end
	local master = generateKey()
	local session = {
		keys = deriveKeys(master),
		counters = { event = 0, ["function"] = 0 },
		seen = { event = {}, ["function"] = {} },
		actions = {},
		calls = 0,
		window = os.clock(),
		limitLog = -math.huge,
		epoch = 0,
		graceUntil = 0,
	}
	sessions[player] = session
	rotateLater(player, session)
	return master, session.epoch
end

event.OnServerEvent:Connect(function(player, counter, proof, name, ...)
	handleCall("event", player, counter, proof, name, ...)
end)

func.OnServerInvoke = function(player, counter, proof, name, ...)
	return handleCall("function", player, counter, proof, name, ...)
end

Players.PlayerRemoving:Connect(function(player)
	sessions[player] = nil
end)

local network = {}

local function makeEntry(name, handler, options)
	if type(name) ~= "string" or name == "" or #name > MAX_NAME then
		error("Flux: invalid action name")
	end
	if type(handler) ~= "function" then
		error("Flux: handler must be a function")
	end
	local rate = options and options.rate
	if rate ~= nil then
		if type(rate) ~= "table"
			or type(rate.capacity) ~= "number"
			or not math.isfinite(rate.capacity)
			or rate.capacity < 1
			or type(rate.window) ~= "number"
			or not math.isfinite(rate.window)
			or rate.window <= 0
		then
			error("Flux: rate must have a positive capacity and window")
		end
	end
	return { handler = handler, rate = rate }
end

function network.on(_, name, handler, options)
	eventHandlers[name] = makeEntry(name, handler, options)
end

function network.onCall(_, name, handler, options)
	functionHandlers[name] = makeEntry(name, handler, options)
end

function network.fireClient(_, player, name, ...)
	event:FireClient(player, name, ...)
end

function network.fireAllClients(_, name, ...)
	event:FireAllClients(name, ...)
end

function network.fireAllClientsExcept(_, exception, name, ...)
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= exception then
			event:FireClient(other, name, ...)
		end
	end
end

local function matches(value, expected)
	if expected == "any" then
		return true
	end
	if expected == "Player" then
		return typeof(value) == "Instance" and value:IsA("Player")
	end
	if expected == "Instance" then
		return typeof(value) == "Instance"
	end
	return typeof(value) == expected
end

local function check(rule, value)
	local ruleType = type(rule) == "string" and rule or rule.type or "any"
	if rule.optional and value == nil then
		return true
	end
	if not matches(value, ruleType) then
		return false, "expected " .. tostring(ruleType)
	end
	if ruleType == "number" then
		if not math.isfinite(value) then
			return false, "expected a finite number"
		end
		if rule.integer and value % 1 ~= 0 then
			return false, "expected an integer"
		end
		if rule.min and value < rule.min then
			return false, "below minimum"
		end
		if rule.max and value > rule.max then
			return false, "above maximum"
		end
	end
	if ruleType == "string" then
		if rule.length then
			if rule.length.min and #value < rule.length.min then
				return false, "too short"
			end
			if rule.length.max and #value > rule.length.max then
				return false, "too long"
			end
		end
		if rule.pattern and not string.find(value, rule.pattern) then
			return false, "invalid format"
		end
	end
	if ruleType == "Instance" then
		if rule.className and not value:IsA(rule.className) then
			return false, "expected " .. tostring(rule.className)
		end
		if rule.ancestor and not value:IsDescendantOf(rule.ancestor) then
			return false, "outside the allowed container"
		end
	end
	if rule.enum and not table.find(rule.enum, value) then
		return false, "not an allowed value"
	end
	if rule.check then
		local ok, result = pcall(rule.check, value)
		if not ok or not result then
			return false, "rejected"
		end
	end
	return true
end

local function validateCall(player, schema, label, strict, ...)
	for i, rule in ipairs(schema) do
		local ok, reason = check(rule, select(i, ...))
		if not ok then
			local field = type(rule) == "table" and rule.name or i
			local message = "invalid argument " .. tostring(field) .. " (" .. tostring(reason) .. ")"
			reportViolation(player, label, message)
			if strict then
				pcall(function()
					player:Kick("Flux: " .. message)
				end)
			end
			return false
		end
	end
	return true
end

local function validateArgs(schema, handler, strict, label)
	if type(schema) ~= "table" then
		error("Flux: schema must be a table")
	end
	if type(handler) ~= "function" then
		error("Flux: handler must be a function")
	end
	label = label or "arguments"
	return function(player, ...)
		if not validateCall(player, schema, label, strict, ...) then
			return
		end
		return handler(player, ...)
	end
end

local function secure(options, handler)
	if type(options) ~= "table" then
		error("Flux: secure options must be a table")
	end
	if type(handler) ~= "function" then
		error("Flux: handler must be a function")
	end
	local schema = options.schema
	local guard = options.guard
	local label = options.name or "handler"
	local strict = options.strict == true
	if schema ~= nil and type(schema) ~= "table" then
		error("Flux: schema must be a table")
	end
	if guard ~= nil and type(guard) ~= "function" then
		error("Flux: guard must be a function")
	end
	return function(player, ...)
		if schema and not validateCall(player, schema, label, strict, ...) then
			return
		end
		if guard then
			local result = table.pack(pcall(guard, player, ...))
			if not result[1] then
				reportViolation(player, label, "guard failed: " .. tostring(result[2]))
				return
			end
			if not result[2] then
				reportViolation(player, label, tostring(result[3] or "authorization denied"))
				return
			end
		end
		return handler(player, ...)
	end
end

local packageCache = {}

local function resolvePackage(name)
	if name == "network" then
		return network
	end

	local cached = packageCache[name]
	if cached ~= nil then
		return cached
	end

	local root = ReplicatedStorage:FindFirstChild("Packages")
	local module = root and root:FindFirstChild(name)
	if not module then
		error("Flux: unknown package '" .. tostring(name) .. "'")
	end

	local loaded = require(module)
	packageCache[name] = loaded
	return loaded
end

local function import(...)
	local names = table.pack(...)
	local values = table.pack()
	for position = 1, names.n do
		values[position] = resolvePackage(names[position])
	end
	return table.unpack(values, 1, names.n)
end

local Flux = {
	import = import,
	validate = function(schema, handler, label)
		return validateArgs(schema, handler, true, label)
	end,
	validateLenient = function(schema, handler, label)
		return validateArgs(schema, handler, false, label)
	end,
	check = check,
	secure = secure,
	guard = function(guard, handler, label)
		if type(guard) ~= "function" then
			error("Flux: guard must be a function")
		end
		return secure({ guard = guard, name = label }, handler)
	end,
	onViolation = function(callback)
		if callback == nil then
			violationHandler = defaultViolation
		elseif type(callback) == "function" then
			violationHandler = callback
		else
			error("Flux: onViolation expects a function or nil")
		end
	end,
}

local requireModule = import("require")
Flux.require = requireModule

shared.Flux = Flux
shared.import = import

requireModule("CoreHandler")
