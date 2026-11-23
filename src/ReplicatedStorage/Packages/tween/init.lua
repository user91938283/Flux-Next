local TweenService = game:GetService("TweenService")

local active = setmetatable({}, { __mode = "k" })

local DEFAULTS = {
	duration = 1,
	style = Enum.EasingStyle.Linear,
	direction = Enum.EasingDirection.Out,
	repeats = 0,
	reverses = false,
	delay = 0,
}

return function(object, properties, duration, style, direction, repeats, reverses, delay)
	local previous = active[object]
	if previous then
		previous:Cancel()
	end

	local tween = TweenService:Create(object, TweenInfo.new(
		duration or DEFAULTS.duration,
		style or DEFAULTS.style,
		direction or DEFAULTS.direction,
		repeats or DEFAULTS.repeats,
		reverses or DEFAULTS.reverses,
		delay or DEFAULTS.delay
	), properties)

	active[object] = tween
	tween.Completed:Connect(function()
		if active[object] == tween then
			active[object] = nil
		end
	end)
	tween:Play()
	return tween
end
