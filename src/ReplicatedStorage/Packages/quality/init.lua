local function readQuality()
	local settings = UserSettings():GetService("UserGameSettings")
	return settings.SavedQualityLevel.Value
end

return readQuality
