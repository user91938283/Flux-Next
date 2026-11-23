local CollectionService = game:GetService("CollectionService")

return function(...)
	local tags = table.pack(...)
	local result = {}
	for position = 1, tags.n do
		local matches = CollectionService:GetTagged(tags[position])
		table.move(matches, 1, #matches, #result + 1, result)
	end
	return result
end
