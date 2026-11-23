local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HASH_A = 2166136261
local HASH_B = 4278190080
local PRIME = 16777619
local MODULUS = 4294967296

local function mul32(a, b)
	local low = a % 65536
	local high = (a - low) / 65536
	return (low * b + (high * b % 65536) * 65536) % MODULUS
end

-- Non-cryptographic checksum for envelope hygiene, not a MAC.
local function checksum(salt, counter, name)
	local data = salt .. ":" .. tostring(counter) .. ":" .. name
	local a, b = HASH_A, HASH_B
	for i = 1, #data do
		local byte = string.byte(data, i)
		a = mul32(bit32.bxor(a, byte), PRIME)
		b = mul32(bit32.bxor(b, byte + i), PRIME)
	end
	return string.format("%08x%08x", a, b)
end

local function deriveSalts(seed)
	return {
		event = checksum(seed, "salt", "event"),
		["function"] = checksum(seed, "salt", "function"),
	}
end

local eventHandlers = {}
local counters = { event = 0, ["function"] = 0 }
local salts
local epoch = -1
local event, func
local ready = Instance.new("BindableEvent")
local settled = false

local function apply(seed, version)
	version = tonumber(version) or 0
	if version > epoch and type(seed) == "string" and #seed == 64 then
		salts = deriveSalts(seed)
		epoch = version
	end
end

task.spawn(function()
	local folder = ReplicatedStorage:WaitForChild("Network")
	local handshake = folder:WaitForChild("Handshake")
	local rotate = folder:WaitForChild("Rotate")
	event = folder:WaitForChild("Event")
	func = folder:WaitForChild("Function")

	rotate.OnClientEvent:Connect(apply)

	event.OnClientEvent:Connect(function(name, ...)
		local handler = eventHandlers[name]
		if handler then
			handler(...)
		end
	end)

	local ok, seed, version = pcall(handshake.InvokeServer, handshake)
	if ok then
		apply(seed, version)
	end
	settled = true
	ready:Fire()
end)

local function awaitReady()
	if not settled then
		ready.Event:Wait()
	end
	if not salts then
		error("Flux: handshake failed")
	end
end

local function nextChecksum(kind, name)
	local counter = counters[kind] + 1
	counters[kind] = counter
	return counter, checksum(salts[kind], counter, name)
end

local network = {}

function network.on(_, name, handler)
	if type(name) ~= "string" or name == "" or type(handler) ~= "function" then
		error("Flux: invalid event handler")
	end
	eventHandlers[name] = handler
end

function network.fire(_, name, ...)
	awaitReady()
	local counter, digest = nextChecksum("event", name)
	event:FireServer(counter, digest, name, ...)
end

function network.invoke(_, name, ...)
	awaitReady()
	local counter, digest = nextChecksum("function", name)
	return func:InvokeServer(counter, digest, name, ...)
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
}

shared.Flux = Flux
shared.import = import

local requireModule = import("require")
Flux.require = requireModule

local ok, err = pcall(requireModule, "CoreHandler")
shared.import = nil
shared.Flux = nil
if not ok then
	error(err, 0)
end
