--[[
Exploit defenses:
1. Client-supplied prices, costs, currency values, or purchase quantities are ignored because every price, balance change, and quantity is calculated from server-owned configuration and profile data.
2. Unknown item IDs and forged item fields are rejected because purchases use an exact server-side shop allowlist instead of remote arguments as definitions.
3. Currency, generator counts, inventory, passive income, and prestige rewards cannot be forged because none of them are accepted from the client and all mutations happen on the server.
4. Remote spam is limited with a per-player request window, preventing purchase and prestige flooding from becoming a server-side denial of service.
5. Concurrent remote calls are serialized per profile, preventing double-spend races and overlapping mutations from charging one purchase while granting another.
6. Two servers loading one profile cannot both own it because the lock is acquired atomically inside UpdateAsync with an owner token and an expiring lease.
7. Server crashes and abandoned sessions cannot permanently duplicate or strand a profile because locks expire, are refreshed while active, and are released with UpdateAsync when possible.
8. Offline-income inflation is prevented because elapsed time comes from server timestamps, negative elapsed time is ignored, and credited downtime is capped.
9. Invalid numeric data such as NaN, infinity, negative balances, and oversized counts is rejected or clamped during normalization before it reaches gameplay calculations.
10. Prestige argument tampering is prevented because the remote accepts no gameplay parameters; the server checks the current balance, resets only defined fields, and computes the permanent multiplier itself.
11. Unsaved or cancelled DataStore writes are not treated as successful because every UpdateAsync result is checked for nil and retried with bounded exponential backoff.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "EconomyService must run on the server")

local EconomyService = {}
EconomyService.__index = EconomyService

local MAX_CURRENCY = 1000000000000000
local MAX_GENERATOR_COUNT = 1000000000
local MAX_INVENTORY_COUNT = 1000000000
local MAX_PRESTIGE_COUNT = 1000
local MAX_REQUEST_WINDOW = 1

local DEFAULT_CONFIG = {
	DataStoreName = "EconomyProfiles_v1",
	RemoteFolderName = "EconomyRemotes",
	MaxRetries = 8,
	RetryBaseDelay = 1,
	RetryMaxDelay = 12,
	LockDuration = 120,
	HeartbeatInterval = 30,
	AutosaveInterval = 60,
	OfflineIncomeCapSeconds = 8 * 60 * 60,
	MaxRequestsPerSecond = 8,
	PrestigeBaseCost = 100000,
	PrestigeCostGrowth = 2.5,
	PrestigeMultiplierPerRebirth = 1.25,
}

local GENERATOR_TYPES = {
	BasicGenerator = {
		IncomePerSecond = 1,
	},
	SteelGenerator = {
		IncomePerSecond = 8,
	},
	QuantumGenerator = {
		IncomePerSecond = 40,
	},
}

local SHOP_ITEMS = {
	BasicGenerator = {
		Cost = 50,
		Kind = "Generator",
		GeneratorType = "BasicGenerator",
	},
	SteelGenerator = {
		Cost = 300,
		Kind = "Generator",
		GeneratorType = "SteelGenerator",
	},
	QuantumGenerator = {
		Cost = 2000,
		Kind = "Generator",
		GeneratorType = "QuantumGenerator",
	},
	ResearchToken = {
		Cost = 1000,
		Kind = "Inventory",
		InventoryId = "ResearchToken",
	},
}

local function isFiniteNumber(value)
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function clampCurrency(value)
	if not isFiniteNumber(value) then
		return 0
	end

	return math.clamp(math.floor(math.max(0, value) * 100 + 0.5) / 100, 0, MAX_CURRENCY)
end

local function clampInteger(value, minimum, maximum)
	if not isFiniteNumber(value) then
		return minimum
	end

	return math.clamp(math.floor(value), minimum, maximum)
end

local function clone(value)
	if type(value) ~= "table" then
		return value
	end

	local copy = {}
	for key, child in pairs(value) do
		copy[key] = clone(child)
	end

	return copy
end

local function mergeConfig(overrides)
	local config = clone(DEFAULT_CONFIG)

	if type(overrides) == "table" then
		for key, value in pairs(overrides) do
			if config[key] ~= nil and typeof(value) == typeof(config[key]) then
				config[key] = value
			end
		end
	end

	config.MaxRetries = math.max(1, math.floor(config.MaxRetries))
	config.RetryBaseDelay = math.max(0.1, config.RetryBaseDelay)
	config.RetryMaxDelay = math.max(config.RetryBaseDelay, config.RetryMaxDelay)
	config.LockDuration = math.max(30, math.floor(config.LockDuration))
	config.HeartbeatInterval = math.max(5, math.floor(config.HeartbeatInterval))
	config.AutosaveInterval = math.max(15, math.floor(config.AutosaveInterval))
	config.OfflineIncomeCapSeconds = math.max(0, math.floor(config.OfflineIncomeCapSeconds))
	config.MaxRequestsPerSecond = math.max(1, math.floor(config.MaxRequestsPerSecond))
	config.PrestigeBaseCost = clampCurrency(config.PrestigeBaseCost)
	config.PrestigeCostGrowth = math.max(1, config.PrestigeCostGrowth)
	config.PrestigeMultiplierPerRebirth = math.max(1, config.PrestigeMultiplierPerRebirth)

	return config
end

local function calculatePrestigeMultiplier(prestigeCount, config)
	local multiplier = 1

	for _ = 1, prestigeCount do
		if multiplier >= MAX_CURRENCY / config.PrestigeMultiplierPerRebirth then
			return MAX_CURRENCY
		end

		multiplier *= config.PrestigeMultiplierPerRebirth
	end

	return multiplier
end

local function makeDefaultData(now, config)
	local generators = {}
	for generatorType in pairs(GENERATOR_TYPES) do
		generators[generatorType] = 0
	end

	return {
		SchemaVersion = 1,
		Currency = 0,
		Inventory = {},
		Generators = generators,
		PrestigeCount = 0,
		PrestigeMultiplier = calculatePrestigeMultiplier(0, config),
		LifetimeEarned = 0,
		LastSeen = now,
		Session = nil,
	}
end

local function normalizeSession(rawSession)
	if type(rawSession) ~= "table" or type(rawSession.LockId) ~= "string" then
		return nil
	end

	return {
		LockId = string.sub(rawSession.LockId, 1, 128),
		JobId = type(rawSession.JobId) == "string" and string.sub(rawSession.JobId, 1, 128) or "",
		PlaceId = clampInteger(rawSession.PlaceId, 0, MAX_CURRENCY),
		ExpiresAt = clampInteger(rawSession.ExpiresAt, 0, MAX_CURRENCY),
	}
end

local function normalizeInventory(rawInventory)
	local inventory = {}

	if type(rawInventory) ~= "table" then
		return inventory
	end

	for itemId, rawCount in pairs(rawInventory) do
		if type(itemId) == "string" and #itemId <= 64 then
			local count = clampInteger(rawCount, 0, MAX_INVENTORY_COUNT)
			if count > 0 then
				inventory[itemId] = count
			end
		end
	end

	return inventory
end

local function normalizeData(rawData, now, config)
	local data = makeDefaultData(now, config)

	if type(rawData) ~= "table" then
		return data
	end

	data.SchemaVersion = 1
	data.Currency = clampCurrency(rawData.Currency)
	data.Inventory = normalizeInventory(rawData.Inventory)
	data.PrestigeCount = clampInteger(rawData.PrestigeCount, 0, MAX_PRESTIGE_COUNT)
	data.PrestigeMultiplier = calculatePrestigeMultiplier(data.PrestigeCount, config)
	data.LifetimeEarned = clampCurrency(rawData.LifetimeEarned)
	data.LastSeen = clampInteger(rawData.LastSeen, 0, MAX_CURRENCY)

	if type(rawData.Generators) == "table" then
		for generatorType in pairs(GENERATOR_TYPES) do
			data.Generators[generatorType] = clampInteger(rawData.Generators[generatorType], 0, MAX_GENERATOR_COUNT)
		end
	end

	data.Session = normalizeSession(rawData.Session)

	return data
end

local function makeSession(lockId, now, config)
	return {
		LockId = lockId,
		JobId = game.JobId,
		PlaceId = game.PlaceId,
		ExpiresAt = now + config.LockDuration,
	}
end

local function isSessionOwned(data, lockId, now)
	return data.Session ~= nil
		and data.Session.LockId == lockId
		and data.Session.ExpiresAt > now
end

local function calculateIncomePerSecond(data)
	local baseIncome = 0

	for generatorType, generatorConfig in pairs(GENERATOR_TYPES) do
		local count = data.Generators[generatorType] or 0
		baseIncome += count * generatorConfig.IncomePerSecond
		if baseIncome >= MAX_CURRENCY then
			return MAX_CURRENCY
		end
	end

	return math.min(MAX_CURRENCY, baseIncome * data.PrestigeMultiplier)
end

local function calculateOfflineIncome(data, now, config)
	local elapsed = now - data.LastSeen
	if elapsed <= 0 or config.OfflineIncomeCapSeconds <= 0 then
		return 0
	end

	elapsed = math.min(elapsed, config.OfflineIncomeCapSeconds)
	return clampCurrency(calculateIncomePerSecond(data) * elapsed)
end

local function retryDataStore(config, random, operationName, operation)
	local lastError = operationName .. " failed"

	for attempt = 1, config.MaxRetries do
		local ok, result = pcall(operation)
		if ok and result ~= nil then
			return true, result
		end

		if ok then
			lastError = operationName .. " returned nil and cancelled the write"
		else
			lastError = tostring(result)
		end

		if attempt < config.MaxRetries then
			local delay = math.min(config.RetryMaxDelay, config.RetryBaseDelay * 2 ^ (attempt - 1))
			task.wait(delay + random:NextNumber(0, math.min(0.5, delay * 0.25)))
		end
	end

	return false, lastError
end

local function createRemoteFunction(parent, name)
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteFunction"), name .. " must be a RemoteFunction")
		return existing
	end

	local remote = Instance.new("RemoteFunction")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function beginOperation(profile)
	if profile.Operating or profile.Unloading or profile.LockLost or profile.DataStoreBusy then
		return false
	end

	profile.Operating = true
	return true
end

local function finishOperation(profile)
	profile.Operating = false
end

function EconomyService.new(overrides)
	local self = setmetatable({}, EconomyService)

	self.config = mergeConfig(overrides)
	self.store = DataStoreService:GetDataStore(self.config.DataStoreName)
	self.random = Random.new()
	self.profiles = {}
	self.loading = {}
	self.connections = {}
	self.started = false
	self.shuttingDown = false
	self.remoteFolder = nil

	return self
end

function EconomyService:_getProfile(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end

	return self.profiles[player.UserId]
end

function EconomyService:_consumeRequest(profile)
	local now = time()

	if now - profile.RequestWindowStarted >= MAX_REQUEST_WINDOW then
		profile.RequestWindowStarted = now
		profile.RequestCount = 0
	end

	profile.RequestCount += 1
	return profile.RequestCount <= self.config.MaxRequestsPerSecond
end

function EconomyService:_accrueOnlineIncome(profile)
	if profile.DataStoreBusy then
		return 0
	end

	local now = time()
	local elapsed = now - profile.LastAccrualClock
	if elapsed <= 0 then
		return 0
	end

	profile.LastAccrualClock = now

	local earned = clampCurrency(calculateIncomePerSecond(profile.data) * elapsed)
	if earned <= 0 then
		return 0
	end

	profile.data.Currency = clampCurrency(profile.data.Currency + earned)
	profile.data.LifetimeEarned = clampCurrency(profile.data.LifetimeEarned + earned)
	profile.dirty = true

	return earned
end

function EconomyService:_saveProfile(profile, operationName)
	if profile.DataStoreBusy or profile.LockLost then
		return false, "profile is not writable"
	end

	profile.DataStoreBusy = true
	local now = os.time()
	local payload = clone(profile.data)
	payload.LastSeen = now
	payload.Session = makeSession(profile.Token, now, self.config)

	local success, result = retryDataStore(self.config, self.random, operationName, function()
		local updated = self.store:UpdateAsync(profile.Key, function(rawData)
			if type(rawData) ~= "table" then
				return nil
			end

			local callbackNow = os.time()
			local current = normalizeData(rawData, callbackNow, self.config)
			if not isSessionOwned(current, profile.Token, callbackNow) then
				return nil
			end

			local nextData = clone(payload)
			nextData.LastSeen = callbackNow
			nextData.Session = makeSession(profile.Token, callbackNow, self.config)
			return nextData
		end)

		if updated == nil then
			error(operationName .. " returned nil and cancelled the write")
		end

		return updated
	end)

	profile.DataStoreBusy = false

	if not success then
		profile.LockLost = true
		return false, result
	end

	profile.data = normalizeData(result, now, self.config)
	profile.LockExpiresAt = profile.data.Session and profile.data.Session.ExpiresAt or now
	profile.dirty = false

	return true, result
end

function EconomyService:_refreshSession(profile)
	if profile.DataStoreBusy or profile.Operating or profile.Unloading or profile.LockLost then
		return false
	end

	local now = os.time()
	if profile.LockExpiresAt - now > self.config.HeartbeatInterval then
		return true
	end

	profile.DataStoreBusy = true

	local success, result = retryDataStore(self.config, self.random, "session heartbeat", function()
		local updated = self.store:UpdateAsync(profile.Key, function(rawData)
			if type(rawData) ~= "table" then
				return nil
			end

			local callbackNow = os.time()
			local current = normalizeData(rawData, callbackNow, self.config)
			if not isSessionOwned(current, profile.Token, callbackNow) then
				return nil
			end

			current.Session = makeSession(profile.Token, callbackNow, self.config)
			return current
		end)

		if updated == nil then
			error("session heartbeat returned nil and cancelled the write")
		end

		return updated
	end)

	profile.DataStoreBusy = false

	if not success then
		profile.LockLost = true
		if profile.Player.Parent == Players then
			profile.Player:Kick("Your data session expired. Please rejoin.")
		end
		return false, result
	end

	local refreshed = normalizeData(result, os.time(), self.config)
	profile.LockExpiresAt = refreshed.Session and refreshed.Session.ExpiresAt or now
	return true
end

function EconomyService:_releaseProfile(profile)
	if profile.Released then
		return true
	end

	profile.Released = true
	local now = os.time()

	local success = retryDataStore(self.config, self.random, "session release", function()
		local updated = self.store:UpdateAsync(profile.Key, function(rawData)
			if type(rawData) ~= "table" then
				return nil
			end

			local callbackNow = os.time()
			local current = normalizeData(rawData, callbackNow, self.config)
			if current.Session == nil or current.Session.LockId ~= profile.Token then
				return nil
			end

			current.Session = nil
			current.LastSeen = callbackNow
			return current
		end)

		if updated == nil then
			error("session release returned nil and cancelled the write")
		end

		return updated
	end)

	return success
end

function EconomyService:_loadPlayer(player)
	if self.shuttingDown or player.Parent ~= Players or self.loading[player.UserId] or self.profiles[player.UserId] then
		return false, "player is already loading"
	end

	self.loading[player.UserId] = true
	local token = HttpService:GenerateGUID(false)
	local key = "Player_" .. tostring(player.UserId)

	local success, result = retryDataStore(self.config, self.random, "profile load", function()
		local updated = self.store:UpdateAsync(key, function(rawData)
			local callbackNow = os.time()
			if rawData ~= nil and type(rawData) ~= "table" then
				return nil
			end

			local current = normalizeData(rawData, callbackNow, self.config)
			if current.Session ~= nil and current.Session.LockId ~= token and current.Session.ExpiresAt > callbackNow then
				return nil
			end

			local offlineIncome = calculateOfflineIncome(current, callbackNow, self.config)
			current.Currency = clampCurrency(current.Currency + offlineIncome)
			current.LifetimeEarned = clampCurrency(current.LifetimeEarned + offlineIncome)
			current.LastSeen = callbackNow
			current.Session = makeSession(token, callbackNow, self.config)

			return current
		end)

		if updated == nil then
			error("profile load returned nil and cancelled the write")
		end

		return updated
	end)

	self.loading[player.UserId] = nil

	if not success then
		return false, result
	end

	local now = os.time()
	local loadedData = normalizeData(result, now, self.config)
	local profile = {
		Player = player,
		Key = key,
		Token = token,
		data = loadedData,
		LastAccrualClock = time(),
		LockExpiresAt = loadedData.Session and loadedData.Session.ExpiresAt or now,
		RequestWindowStarted = time(),
		RequestCount = 0,
		DataStoreBusy = false,
		Operating = false,
		Unloading = false,
		LockLost = false,
		Released = false,
		dirty = false,
	}

	self.profiles[player.UserId] = profile

	if player.Parent ~= Players then
		task.spawn(function()
			self:_unloadPlayer(player)
		end)
	end

	return true, profile
end

function EconomyService:_unloadPlayer(player)
	local profile = self.profiles[player.UserId]
	if not profile or profile.Unloading then
		return true
	end

	profile.Unloading = true
	while profile.Operating or profile.DataStoreBusy do
		task.wait()
	end

	self:_accrueOnlineIncome(profile)
	local saveSuccess = true
	if not profile.LockLost then
		saveSuccess = self:_saveProfile(profile, "profile save")
	end

	local releaseSuccess = self:_releaseProfile(profile)
	self.profiles[player.UserId] = nil

	return saveSuccess and releaseSuccess
end

function EconomyService:_runAutosave()
	while self.started and not self.shuttingDown do
		task.wait(self.config.AutosaveInterval)

		for _, profile in pairs(self.profiles) do
			if not profile.Unloading and not profile.Operating and not profile.LockLost and not profile.DataStoreBusy then
				self:_accrueOnlineIncome(profile)
				self:_saveProfile(profile, "automatic profile save")
			end
		end
	end
end

function EconomyService:_runHeartbeat()
	while self.started and not self.shuttingDown do
		task.wait(self.config.HeartbeatInterval)

		for _, profile in pairs(self.profiles) do
			if not profile.Unloading and not profile.Operating and not profile.LockLost and not profile.DataStoreBusy then
				task.spawn(function()
					self:_refreshSession(profile)
				end)
			end
		end
	end
end

function EconomyService:_publicState(profile)
	local data = profile.data
	return {
		Currency = data.Currency,
		Inventory = clone(data.Inventory),
		Generators = clone(data.Generators),
		PrestigeCount = data.PrestigeCount,
		PrestigeMultiplier = data.PrestigeMultiplier,
		IncomePerSecond = calculateIncomePerSecond(data),
		PrestigeCost = self:_getPrestigeCost(data.PrestigeCount),
	}
end

function EconomyService:_getPrestigeCost(prestigeCount)
	local cost = self.config.PrestigeBaseCost

	for _ = 1, prestigeCount do
		if cost >= MAX_CURRENCY / self.config.PrestigeCostGrowth then
			return MAX_CURRENCY
		end

		cost *= self.config.PrestigeCostGrowth
	end

	return clampCurrency(cost)
end

function EconomyService:GetState(player)
	local profile = self:_getProfile(player)
	if not profile or profile.LockLost then
		return {
			Success = false,
			Error = "PROFILE_NOT_READY",
		}
	end

	if profile.Unloading or profile.Operating or profile.DataStoreBusy then
		return {
			Success = false,
			Error = "PROFILE_BUSY",
		}
	end

	if not self:_consumeRequest(profile) then
		return {
			Success = false,
			Error = "TOO_MANY_REQUESTS",
		}
	end

	self:_accrueOnlineIncome(profile)
	local state = self:_publicState(profile)
	state.Success = true
	return state
end

function EconomyService:GetShop()
	local shop = {}

	for itemId, item in pairs(SHOP_ITEMS) do
		shop[itemId] = {
			Cost = item.Cost,
			Kind = item.Kind,
		}
	end

	return shop
end

function EconomyService:Purchase(player, itemId)
	local profile = self:_getProfile(player)
	if not profile or profile.LockLost then
		return {
			Success = false,
			Error = "PROFILE_NOT_READY",
		}
	end

	if not self:_consumeRequest(profile) then
		return {
			Success = false,
			Error = "TOO_MANY_REQUESTS",
		}
	end

	if typeof(itemId) ~= "string" or #itemId > 64 then
		return {
			Success = false,
			Error = "INVALID_ITEM",
		}
	end

	local item = SHOP_ITEMS[itemId]
	if not item then
		return {
			Success = false,
			Error = "INVALID_ITEM",
		}
	end

	if not beginOperation(profile) then
		return {
			Success = false,
			Error = "PROFILE_BUSY",
		}
	end

	self:_accrueOnlineIncome(profile)
	local before = clone(profile.data)
	local beforeDirty = profile.dirty

	local success
	local response
	if profile.data.Currency < item.Cost then
		response = {
			Success = false,
			Error = "INSUFFICIENT_FUNDS",
			State = self:_publicState(profile),
		}
	else
		profile.data.Currency = clampCurrency(profile.data.Currency - item.Cost)

		if item.Kind == "Generator" then
			local generatorCount = profile.data.Generators[item.GeneratorType] or 0
			profile.data.Generators[item.GeneratorType] = clampInteger(generatorCount + 1, 0, MAX_GENERATOR_COUNT)
		elseif item.Kind == "Inventory" then
			local inventoryCount = profile.data.Inventory[item.InventoryId] or 0
			profile.data.Inventory[item.InventoryId] = clampInteger(inventoryCount + 1, 0, MAX_INVENTORY_COUNT)
		end

		profile.dirty = true
		success = self:_saveProfile(profile, "purchase save")
		if not success then
			profile.data = before
			profile.dirty = beforeDirty
			response = {
				Success = false,
				Error = "SAVE_FAILED",
			}
		else
			response = self:_publicState(profile)
			response.Success = true
			response.ItemId = itemId
		end
	end

	finishOperation(profile)
	return response
end

function EconomyService:Prestige(player)
	local profile = self:_getProfile(player)
	if not profile or profile.LockLost then
		return {
			Success = false,
			Error = "PROFILE_NOT_READY",
		}
	end

	if not self:_consumeRequest(profile) then
		return {
			Success = false,
			Error = "TOO_MANY_REQUESTS",
		}
	end

	if not beginOperation(profile) then
		return {
			Success = false,
			Error = "PROFILE_BUSY",
		}
	end

	self:_accrueOnlineIncome(profile)
	local before = clone(profile.data)
	local beforeDirty = profile.dirty
	local cost = self:_getPrestigeCost(profile.data.PrestigeCount)

	if profile.data.Currency < cost then
		local response = {
			Success = false,
			Error = "INSUFFICIENT_FUNDS",
			State = self:_publicState(profile),
		}
		finishOperation(profile)
		return response
	end

	profile.data.Currency = 0
	for generatorType in pairs(GENERATOR_TYPES) do
		profile.data.Generators[generatorType] = 0
	end

	profile.data.PrestigeCount = clampInteger(profile.data.PrestigeCount + 1, 0, MAX_PRESTIGE_COUNT)
	profile.data.PrestigeMultiplier = calculatePrestigeMultiplier(profile.data.PrestigeCount, self.config)
	profile.dirty = true

	local success = self:_saveProfile(profile, "prestige save")
	if not success then
		profile.data = before
		profile.dirty = beforeDirty
		finishOperation(profile)
		return {
			Success = false,
			Error = "SAVE_FAILED",
		}
	end

	local response = self:_publicState(profile)
	response.Success = true
	response.Prestiged = true
	finishOperation(profile)
	return response
end

function EconomyService:Start()
	if self.started then
		return self
	end

	self.started = true
	self.shuttingDown = false

	local remoteFolder = ReplicatedStorage:FindFirstChild(self.config.RemoteFolderName)
	if remoteFolder then
		assert(remoteFolder:IsA("Folder"), self.config.RemoteFolderName .. " must be a Folder")
	else
		remoteFolder = Instance.new("Folder")
		remoteFolder.Name = self.config.RemoteFolderName
		remoteFolder.Parent = ReplicatedStorage
	end

	self.remoteFolder = remoteFolder
	self.purchaseRemote = createRemoteFunction(remoteFolder, "Purchase")
	self.stateRemote = createRemoteFunction(remoteFolder, "GetState")
	self.shopRemote = createRemoteFunction(remoteFolder, "GetShop")
	self.prestigeRemote = createRemoteFunction(remoteFolder, "Prestige")

	self.purchaseRemote.OnServerInvoke = function(player, itemId)
		return self:Purchase(player, itemId)
	end

	self.stateRemote.OnServerInvoke = function(player)
		return self:GetState(player)
	end

	self.shopRemote.OnServerInvoke = function()
		return self:GetShop()
	end

	self.prestigeRemote.OnServerInvoke = function(player)
		return self:Prestige(player)
	end

	table.insert(self.connections, Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			self:_loadPlayer(player)
		end)
	end))

	table.insert(self.connections, Players.PlayerRemoving:Connect(function(player)
		task.spawn(function()
			self:_unloadPlayer(player)
		end)
	end))

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:_loadPlayer(player)
		end)
	end

	task.spawn(function()
		self:_runAutosave()
	end)

	task.spawn(function()
		self:_runHeartbeat()
	end)

	game:BindToClose(function()
		self.shuttingDown = true
		self.started = false

		local pending = 0
		for _, player in ipairs(Players:GetPlayers()) do
			pending += 1
			task.spawn(function()
				self:_unloadPlayer(player)
				pending -= 1
			end)
		end

		local deadline = time() + math.max(10, self.config.LockDuration / 2)
		while pending > 0 and time() < deadline do
			task.wait()
		end
	end)

	return self
end

function EconomyService:Destroy()
	if not self.started and not self.shuttingDown then
		return
	end

	self.shuttingDown = true
	self.started = false

	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	self.connections = {}
end

return EconomyService

