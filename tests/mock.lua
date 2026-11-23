local Mock = {}

local rawType = type
local rawTypeof = typeof

local function isInstance(value)
	return rawType(value) == "table" and rawget(value, "_isInstance") == true
end

__type = function(value)
	if isInstance(value) then
		return "userdata"
	end
	return rawType(value)
end

__typeof = function(value)
	if isInstance(value) then
		return "Instance"
	end
	return rawTypeof(value)
end

type = __type
typeof = __typeof

local SHIM = "local type, typeof = __type, __typeof\n"

local sharedStore = {}

shared = setmetatable({}, {
	__index = function(_, key)
		return sharedStore[key]
	end,
	__newindex = function(_, key, value)
		sharedStore[key] = value
		if key == "Flux" and value ~= nil then
			Mock.lastFlux = value
		elseif key == "import" and value ~= nil then
			Mock.lastImport = value
		end
	end,
})

local Signal = {}
Signal.__index = Signal

local function newSignal()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(callback)
	table.insert(self._handlers, callback)
	return {
		Disconnect = function() end,
	}
end

function Signal:Wait()
	error("Mock: Wait would block", 2)
end

function Signal:Fire(...)
	for index = 1, #self._handlers do
		self._handlers[index](...)
	end
end

local inheritance = {
	Part = { "BasePart", "PVInstance" },
	Model = { "PVInstance" },
	Script = { "BaseScript" },
	LocalScript = { "BaseScript" },
}

local InstanceClass = {}
InstanceClass.__index = InstanceClass

local function newInstance(className, name)
	return setmetatable({
		_isInstance = true,
		ClassName = className,
		Name = name or "",
		_children = {},
		ChildAdded = newSignal(),
	}, {
		__index = function(self, key)
			local method = InstanceClass[key]
			if method ~= nil then
				return method
			end
			return self:FindFirstChild(key)
		end,
		__newindex = function(self, key, value)
			local old = rawget(self, key)
			rawset(self, key, value)
			if key == "Parent" then
				if old then
					local index = table.find(old._children, self)
					if index then
						table.remove(old._children, index)
					end
				end
				if value then
					table.insert(value._children, self)
					value.ChildAdded:Fire(self)
				end
			end
		end,
	})
end

function InstanceClass:FindFirstChild(childName)
	for index = 1, #self._children do
		if self._children[index].Name == childName then
			return self._children[index]
		end
	end
	return nil
end

function InstanceClass:WaitForChild(childName)
	local child = self:FindFirstChild(childName)
	if not child then
		error("Mock: missing child " .. tostring(childName), 2)
	end
	return child
end

function InstanceClass:GetChildren()
	local result = {}
	for index = 1, #self._children do
		result[index] = self._children[index]
	end
	return result
end

function InstanceClass:IsA(className)
	if self.ClassName == className or className == "Instance" then
		return true
	end
	local parents = inheritance[self.ClassName]
	return parents ~= nil and table.find(parents, className) ~= nil
end

function InstanceClass:IsDescendantOf(ancestor)
	local node = self.Parent
	while node do
		if node == ancestor then
			return true
		end
		node = node.Parent
	end
	return false
end

local function setupRemote(object)
	if object.ClassName == "RemoteEvent" then
		object.OnServerEvent = newSignal()
		object.OnClientEvent = newSignal()
		object.FireServer = function(self, ...)
			self.OnServerEvent:Fire(Mock.player, ...)
		end
		object.FireClient = function(self, player, ...)
			self.lastArgs = table.pack(...)
			self.OnClientEvent:Fire(...)
		end
		object.FireAllClients = function(self, ...)
			self.lastArgs = table.pack(...)
			self.OnClientEvent:Fire(...)
		end
	elseif object.ClassName == "RemoteFunction" then
		object.InvokeServer = function(self, ...)
			local result = table.pack(self.OnServerInvoke(Mock.player, ...))
			self.lastResult = result
			return table.unpack(result, 1, result.n)
		end
		object.InvokeClient = function()
			error("Mock: InvokeClient is not supported")
		end
	elseif object.ClassName == "BindableEvent" then
		object.Event = newSignal()
		object.Fire = function(self, ...)
			self.Event:Fire(...)
		end
	end
end

local function createInstance(className, name)
	local object = newInstance(className, name)
	setupRemote(object)
	return object
end

function Mock.newPlayer(name, userId)
	local player = createInstance("Player", name)
	player.UserId = userId
	player.Kick = function(self, reason)
		Mock.kicked[self.UserId] = reason
	end

	local scripts = createInstance("Folder", "PlayerScripts")
	scripts.Parent = player

	local playerGui = createInstance("Folder", "PlayerGui")
	playerGui.Parent = player

	local fluxClient = createInstance("LocalScript", "Flux/client")
	fluxClient.Parent = scripts

	local core = createInstance("Folder", "Core")
	core.Parent = fluxClient

	local handler = createInstance("ModuleScript", "CoreHandler")
	handler._value = { name = "CoreHandler" }
	handler.Parent = core

	local classes = createInstance("Folder", "Classes")
	classes.Parent = fluxClient

	local handlers = createInstance("Folder", "Handlers")
	handlers.Parent = fluxClient

	return player
end

function Mock.reset()
	Mock.time = 0
	Mock.players = {}
	Mock.kicked = {}
	Mock.warnings = {}
	Mock.violations = {}
	Mock.delayed = {}
	Mock.randomState = 0
	Mock.serviceCalls = {}
	Mock.quality = 5
	Mock.lastFlux = nil
	Mock.lastImport = nil

	for key in pairs(sharedStore) do
		sharedStore[key] = nil
	end

	local replicated = createInstance("Folder", "ReplicatedStorage")

	local packages = createInstance("Folder", "Packages")
	packages.Parent = replicated
	local requirePackage = createInstance("ModuleScript", "require")
	requirePackage._value = function()
		return {}
	end
	requirePackage.Parent = packages

	local sharedFolder = createInstance("Folder", "Shared")
	sharedFolder.Parent = replicated
	local util = createInstance("ModuleScript", "Util")
	util._value = { name = "Util" }
	util.Parent = sharedFolder
	local nested = createInstance("Folder", "Nested")
	nested.Parent = sharedFolder
	local deep = createInstance("ModuleScript", "Deep")
	deep._value = { name = "Deep" }
	deep.Parent = nested

	local serverScriptService = createInstance("Folder", "ServerScriptService")
	local fluxServer = createInstance("Script", "Flux/server")
	fluxServer.Parent = serverScriptService
	local serverCore = createInstance("Folder", "Core")
	serverCore.Parent = fluxServer
	local serverHandler = createInstance("ModuleScript", "CoreHandler")
	serverHandler._value = { name = "CoreHandler" }
	serverHandler.Parent = serverCore
	local classes = createInstance("Folder", "Classes")
	classes.Parent = fluxServer
	local handlers = createInstance("Folder", "Handlers")
	handlers.Parent = fluxServer

	local serverStorage = createInstance("Folder", "ServerStorage")
	local workspace = createInstance("Folder", "Workspace")
	local runService = createInstance("Folder", "RunService")
	local starterPlayer = createInstance("Folder", "StarterPlayer")

	local playersService = createInstance("Folder", "Players")
	playersService.GetPlayers = function()
		return Mock.players
	end
	playersService.PlayerRemoving = newSignal()

	local collectionService = createInstance("Folder", "CollectionService")
	collectionService._tags = {}
	collectionService.GetTagged = function(self, tag)
		return self._tags[tag] or {}
	end
	collectionService.AddTag = function(self, instance, tag)
		local list = self._tags[tag]
		if not list then
			list = {}
			self._tags[tag] = list
		end
		list[#list + 1] = instance
	end

	local tweenService = createInstance("Folder", "TweenService")
	tweenService.Create = function(_, object, info, properties)
		local tween = {
			object = object,
			info = info,
			properties = properties,
			played = false,
			cancelled = false,
			Completed = newSignal(),
		}
		function tween:Play()
			self.played = true
		end
		function tween:Cancel()
			self.cancelled = true
		end
		return tween
	end

	Mock.services = {
		Players = playersService,
		ReplicatedStorage = replicated,
		ServerScriptService = serverScriptService,
		ServerStorage = serverStorage,
		Workspace = workspace,
		RunService = runService,
		StarterPlayer = starterPlayer,
		CollectionService = collectionService,
		TweenService = tweenService,
	}
	Mock.playersService = playersService

	Mock.player = Mock.newPlayer("Player1", 1)
	Mock.players[1] = Mock.player
end

function Mock.remote(name)
	local network = Mock.services.ReplicatedStorage:FindFirstChild("Network")
	assert(network, "Network folder is missing")
	local remote = network:FindFirstChild(name)
	assert(remote, "remote is missing: " .. tostring(name))
	return remote
end

function Mock.load(name)
	local chunk = assert(loadstring(SHIM .. Sources[name], name))
	return chunk()
end

function Mock.bootServer()
	local chunk = assert(loadstring(SHIM .. Sources.server, "server"))
	chunk()
	return sharedStore.Flux, sharedStore.import("network")
end

function Mock.bootClient()
	Mock.lastFlux = nil
	Mock.lastImport = nil
	Mock.playersService.LocalPlayer = Mock.player
	local chunk = assert(loadstring(SHIM .. Sources.client, "client"))
	chunk()
	return Mock.lastFlux, Mock.lastImport
end

function Mock.setup()
	Mock.reset()
	local serverFlux, server = Mock.bootServer()
	serverFlux.onViolation(function(player, action, reason)
		Mock.violations[#Mock.violations + 1] = {
			player = player,
			action = action,
			reason = reason,
		}
	end)
	local clientFlux, clientImport = Mock.bootClient()
	local client = clientImport("network")
	local handshake = Mock.remote("Handshake")
	return {
		flux = serverFlux,
		server = server,
		client = client,
		clientFlux = clientFlux,
		player = Mock.player,
		seed = handshake.lastResult[1],
	}
end

function Mock.advance(seconds)
	Mock.time += seconds
	local ran = true
	while ran do
		ran = false
		for index, item in ipairs(Mock.delayed) do
			if item.at <= Mock.time then
				table.remove(Mock.delayed, index)
				item.fn(table.unpack(item.args, 1, item.args.n))
				ran = true
				break
			end
		end
	end
end

function Mock.newInstance(className, name)
	return createInstance(className, name)
end

function Mock.newFolder(name)
	return createInstance("Folder", name)
end

function Mock.newPart(name)
	return createInstance("Part", name)
end

Instance = {
	new = function(className, parent)
		local object = createInstance(className)
		if parent then
			object.Parent = parent
		end
		return object
	end,
}

game = {
	GetService = function(_, name)
		Mock.serviceCalls[name] = (Mock.serviceCalls[name] or 0) + 1
		local service = Mock.services[name]
		if not service then
			error("Mock: unknown service " .. tostring(name))
		end
		return service
	end,
}

os = {
	clock = function()
		return Mock.time
	end,
}

task = {
	spawn = function(callback, ...)
		callback(...)
	end,
	defer = function(callback, ...)
		callback(...)
	end,
	delay = function(seconds, callback, ...)
		Mock.delayed[#Mock.delayed + 1] = {
			at = Mock.time + seconds,
			fn = callback,
			args = table.pack(...),
		}
	end,
	wait = function()
		return 0
	end,
}

Random = {
	new = function()
		return {
			NextInteger = function(_, minimum, maximum)
				Mock.randomState = (Mock.randomState * 1664525 + 1013904223) % 4294967296
				return minimum + (Mock.randomState % (maximum - minimum + 1))
			end,
		}
	end,
}

Enum = {
	EasingStyle = { Linear = "Linear" },
	EasingDirection = { Out = "Out" },
}

TweenInfo = {
	new = function(duration, style, direction, repeats, reverses, delay)
		return {
			duration = duration,
			style = style,
			direction = direction,
			repeats = repeats,
			reverses = reverses,
			delay = delay,
		}
	end,
}

UserSettings = function()
	return {
		GetService = function(_, name)
			if name ~= "UserGameSettings" then
				error("Mock: unknown user settings service " .. tostring(name))
			end
			return {
				SavedQualityLevel = { Value = Mock.quality },
			}
		end,
	}
end

warn = function(...)
	local parts = {}
	for index = 1, select("#", ...) do
		parts[index] = tostring(select(index, ...))
	end
	Mock.warnings[#Mock.warnings + 1] = table.concat(parts, " ")
end

require = function(module)
	if not isInstance(module) or module.ClassName ~= "ModuleScript" then
		error("Mock: require expects a ModuleScript", 2)
	end
	if module._value == nil then
		error("Mock: module has no value: " .. tostring(module.Name), 2)
	end
	return module._value
end

Mock.reset()
