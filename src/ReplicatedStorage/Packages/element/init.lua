local Players = game:GetService("Players")

local roots = {}

if Players.LocalPlayer then
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local children = playerGui:GetChildren()
	table.move(children, 1, #children, 1, roots)
	playerGui.ChildAdded:Connect(function(child)
		roots[#roots + 1] = child
	end)
end

local SYMBOLS = {
	["#"] = true,
	["$"] = true,
	["%"] = true,
}

local function parse(selector)
	local steps = {}
	local cursor = 1
	while cursor <= #selector do
		local symbol = selector:sub(cursor, cursor)
		if not SYMBOLS[symbol] then
			return nil
		end
		local stop = cursor + 1
		while stop <= #selector and not SYMBOLS[selector:sub(stop, stop)] do
			stop += 1
		end
		steps[#steps + 1] = {
			symbol = symbol,
			value = selector:sub(cursor + 1, stop - 1),
		}
		cursor = stop
	end
	return steps
end

local function accepts(instance, step)
	if step.symbol == "#" then
		return instance.Name == "#" .. step.value
	elseif step.symbol == "$" then
		return instance.Name == step.value
	end
	return instance:IsA(step.value)
end

local function search(root, step)
	local found = {}
	local pending = {}
	local children = root:GetChildren()
	for index = #children, 1, -1 do
		pending[#pending + 1] = children[index]
	end
	while #pending > 0 do
		local node = table.remove(pending)
		if accepts(node, step) then
			found[#found + 1] = node
		end
		local nested = node:GetChildren()
		for index = #nested, 1, -1 do
			pending[#pending + 1] = nested[index]
		end
	end
	return found
end

return function(first, second)
	local selector, current
	if type(first) == "string" then
		selector, current = first, roots
	else
		selector, current = second, { first }
	end

	local steps = parse(selector)
	if not steps or #steps == 0 then
		return {}
	end

	for index = 1, #steps do
		local step = steps[index]
		local found = {}
		for _, root in ipairs(current) do
			local batch = search(root, step)
			table.move(batch, 1, #batch, #found + 1, found)
		end
		if index == #steps then
			if #found == 1 then
				return found[1]
			end
			return found
		end
		current = found
	end
end
