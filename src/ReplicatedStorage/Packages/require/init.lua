local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local modules = {}

local function register(module)
	local name = module.Name
	local previous = modules[name]
	if previous and previous ~= module then
		error("Flux: duplicate module '" .. name .. "'")
	end
	modules[name] = module
end

local function index(root)
	local pending = { root }
	local cursor = 1
	while cursor <= #pending do
		local node = pending[cursor]
		cursor += 1
		for _, child in ipairs(node:GetChildren()) do
			if child:IsA("ModuleScript") then
				register(child)
			end
			pending[#pending + 1] = child
		end
	end
end

local entry
if Players.LocalPlayer then
	entry = Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Flux/client")
else
	entry = game:GetService("ServerScriptService"):WaitForChild("Flux/server")
end

index(entry)
index(ReplicatedStorage:WaitForChild("Shared"))

return function(...)
	local names = table.pack(...)
	local values = table.pack()
	for position = 1, names.n do
		local name = names[position]
		local module = modules[name]
		if not module then
			error("Flux: unknown module '" .. tostring(name) .. "'")
		end
		values[position] = require(module)
	end
	return table.unpack(values, 1, names.n)
end
