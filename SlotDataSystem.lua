--> This also uses suphi kaner's packet

local ServerScriptService = game:GetService('ServerScriptService')
local ServerMain = ServerScriptService.Server
local ServerStorage = game:GetService('ServerStorage')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local TextService = game:GetService('TextService')
local Network = ReplicatedStorage.Network
local NetworkConnections = require(Network.NetworkConnections)
local ServerModules = ServerStorage.Modules
local SharedModules = ReplicatedStorage.Modules
local Packages = ReplicatedStorage.Packages

--// Data
local PlayerState = Packages.PlayerState
local PlayerStateServer = require(PlayerState.PlayerStateServer)
--

local ReadyClients = {}

local function GetSlotData(Player, slotName)
	return PlayerStateServer.GetPath(Player, 'Server.PlayerData.Slots.' .. slotName)
end

local function FilterName(Player, Name)
	if type(Name) ~= "string" then return nil end
	if Name:match("[^%a]") then return nil end
	if #Name < 2 or #Name > 20 then return nil end

	local sanitized = Name:sub(1, 1):upper() .. Name:sub(2):lower()

	local ok, result = pcall(function()
		return TextService:FilterStringAsync(sanitized, Player.UserId)
	end)
	if not ok then return nil end

	local ok2, filtered = pcall(function()
		return result:GetNonChatStringForBroadcastAsync()
	end)
	if not ok2 then return nil end

	return filtered
end

local function BuildSlotAppearance(data)
	if type(data) ~= 'table' or data.Created ~= true then return nil end

	local stats = data.CharacterStats
	if type(stats) ~= 'table' then return nil end

	local appearance = {}

	local hc = stats.HairColor
	if type(hc) == 'table' and hc.R ~= nil then
		appearance.HairColor = { R = hc.R, G = hc.G, B = hc.B }
	end

	local outfits = ServerStorage.Assets.Outfits
	local clothing = stats.Clothing
	if type(clothing) == 'table' then
		local shirtFolder = clothing.Shirt and outfits:FindFirstChild(clothing.Shirt)
		local shirtObj = shirtFolder and shirtFolder:FindFirstChildWhichIsA('Shirt')
		if shirtObj then appearance.ShirtTemplate = shirtObj.ShirtTemplate end

		local pantsFolder = clothing.Pants and outfits:FindFirstChild(clothing.Pants)
		local pantsObj = pantsFolder and pantsFolder:FindFirstChildWhichIsA('Pants')
		if pantsObj then appearance.PantsTemplate = pantsObj.PantsTemplate end
	end

	return appearance
end

local function BuildSlotSummary(Player)
	local slots = PlayerStateServer.GetPath(Player, 'Server.PlayerData.Slots')
	local out = {}
	if type(slots) ~= 'table' then return out end

	for slotName, data in pairs(slots) do
		if type(data) == 'table' then
			out[slotName] = {
				Locked    = data.Locked == true,
				Created   = data.Created == true,
				Name      = data.Name and data.Name.First or nil,
				Race      = data.CharacterStats and data.CharacterStats.Race or nil,
				MaxHealth = data.CharacterStats and data.CharacterStats.MaxHealth or nil,
				Appearance = BuildSlotAppearance(data),  -- nil for empty/locked slots
			}
		else
			out[slotName] = { Locked = true, Created = false }
		end
	end
	return out
end

local function MigrateLegacy(Player)
	if PlayerStateServer.GetPath(Player, 'ClientData.CreatedCharacterPreviously') ~= true then return end
	if GetSlotData(Player, 'Slot1') and GetSlotData(Player, 'Slot1').Created == true then return end

	local oldName = PlayerStateServer.GetPath(Player, 'ClientData.Name')
		or PlayerStateServer.GetPath(Player, 'Server.PlayerData.Slots.Slot1.Name.First')
	if oldName then
		PlayerStateServer.SetPath(Player, 'Server.PlayerData.Slots.Slot1.Name.First', oldName)
	end
	PlayerStateServer.SetPath(Player, 'Server.PlayerData.Slots.Slot1.Created', true)
end

NetworkConnections.Events.ClientToServer.Ready.OnServerEvent:Connect(function(Player)
	if ReadyClients[Player] ~= nil then return end
	ReadyClients[Player] = true
end)

local function WaitUntilReady(Player, timeout)
	local elapsed = 0
	while ReadyClients[Player] == nil do
		if elapsed >= (timeout or 30) then
			return false
		end
		warn('Client Is not ready..')
		task.wait(0.1)
		elapsed += 0.1
	end
	return true
end

local function Do(Player)
	if not Player then
		return warn('no plr')
	end

	ReplicatedStorage.GUI.Main:Clone().Parent = Player:FindFirstChild('PlayerGui')
	if not WaitUntilReady(Player, 30) then
		return warn('client never became ready for', Player.Name)
	end

	NetworkConnections.Events.ServerToClient.SetupClient:FireClient(Player)
end

game.Players.PlayerAdded:Connect(function(player)
	local success = PlayerStateServer.Init(player)
	if success then
		warn('loaded data successfully!')
		MigrateLegacy(player)
		warn(PlayerStateServer.GetAll(player))
		Do(player)
	else
		warn("Failed to load data for", player.Name)
	end
end)

game.Players.PlayerRemoving:Connect(function(Player)
	if ReadyClients[Player] ~= nil then
		ReadyClients[Player] = nil
	end
end)

NetworkConnections.Events.ClientToServer.GetSlotsR.OnServerInvoke = function(Player)
	return BuildSlotSummary(Player)
end

NetworkConnections.Events.ClientToServer.SelectSlotR.OnServerInvoke = function(Player, slotName)
	if type(slotName) ~= 'string' then return { ok = false, reason = 'invalid' } end

	local data = GetSlotData(Player, slotName)
	if type(data) ~= 'table' then return { ok = false, reason = 'missing' } end
	if data.Locked == true then return { ok = false, reason = 'locked' } end

	Player:SetAttribute('Slot', slotName)

	if data.Created == true then
		Player:SetAttribute('CreatingCharacter', false)
		require(script.CreateCharacter):Create(Player)
		return {
			ok = true,
			created = true,
			data = {
				Name = data.Name and data.Name.First or nil,
				CharacterStats = data.CharacterStats,
			},
		}
	else
		Player:SetAttribute('CreatingCharacter', true)
		return { ok = true, created = false }
	end
end


NetworkConnections.Events.ClientToServer.SetupClientR.OnServerInvoke = function(Player, Name)
	local slotName = Player:GetAttribute('Slot')
	if not slotName then return false end

	local data = GetSlotData(Player, slotName)
	if type(data) ~= 'table' or data.Locked == true or data.Created == true then
		return false
	end

	local filtered = FilterName(Player, Name)
	if not filtered then return false end
	return filtered
end

NetworkConnections.Events.ClientToServer.ConfirmName.OnServerEvent:Connect(function(Player, Name)
	if Player:GetAttribute('CreatingCharacter') ~= true then return end

	local slotName = Player:GetAttribute('Slot')
	if not slotName then return end

	local data = GetSlotData(Player, slotName)
	if type(data) ~= 'table' or data.Locked == true or data.Created == true then return end

	local filtered = FilterName(Player, Name)
	if not filtered then return end

	local base = 'Server.PlayerData.Slots.' .. slotName
	PlayerStateServer.SetPath(Player, base .. '.Name.First', filtered)
	PlayerStateServer.SetPath(Player, base .. '.Created', true)
	Player:SetAttribute('CreatingCharacter', false)
	
	require(script.CreateCharacter):Create(Player)
end)

NetworkConnections.Events.ServerToClient.Ping.OnClientInvoke = nil