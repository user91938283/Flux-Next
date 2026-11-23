local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local function deriveKeys(master)
	return {
		event = token(master, "key", "event"),
		["function"] = token(master, "key", "function"),
	}
end

local eventHandlers = {}
local counters = { event = 0, ["function"] = 0 }
local keys
local epoch = -1
local event, func
local ready = Instance.new("BindableEvent")
local settled = false

local function apply(master, version)
	version = tonumber(version) or 0
	if version > epoch and type(master) == "string" and #master == 64 then
		keys = deriveKeys(master)
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

	local ok, master, version = pcall(handshake.InvokeServer, handshake)
	if ok then
		apply(master, version)
	end
	settled = true
	ready:Fire()
end)

local function awaitReady()
	if not settled then
		ready.Event:Wait()
	end
	if not keys then
		error("Flux: handshake failed")
	end
end

local function nextToken(kind, name)
	local counter = counters[kind] + 1
	counters[kind] = counter
	return counter, token(keys[kind], counter, name)
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
	local counter, proof = nextToken("event", name)
	event:FireServer(counter, proof, name, ...)
end

function network.invoke(_, name, ...)
	awaitReady()
	local counter, proof = nextToken("function", name)
	return func:InvokeServer(counter, proof, name, ...)
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
