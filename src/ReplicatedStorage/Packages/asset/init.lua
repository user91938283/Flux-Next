local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local assets = {}

local function index(root)
	if not root then
		return
	end
	local pending = {}
	local children = root:GetChildren()
	for position = #children, 1, -1 do
		pending[#pending + 1] = children[position]
	end
	while #pending > 0 do
		local node = table.remove(pending)
		if not node:IsA("Folder") then
			assets[node.Name] = node
		end
		local nested = node:GetChildren()
		for position = #nested, 1, -1 do
			pending[#pending + 1] = nested[position]
		end
	end
end

if not Players.LocalPlayer then
	index(game:GetService("ServerStorage"):FindFirstChild("Assets"))
end
index(ReplicatedStorage:FindFirstChild("Assets"))

return function(name, parent)
	if parent then
		return parent[name]
	end
	return assets[name]
end
