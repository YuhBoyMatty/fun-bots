---@class BotManager
---@overload fun():BotManager
BotManager = class('BotManager')

require('Bot')

---@type Utilities
local m_Utilities = require('__shared/Utilities')
local m_Vehicles = require("Vehicles")
---@type Logger
local m_Logger = Logger("BotManager", Debug.Server.BOT)

function BotManager:__init()
	---@type Bot[]
	self._Bots = {}
	---@type table<string, Bot>
	---`[Player.name] -> Bot`
	self._BotsByName = {}
	---@type table<integer, Bot[]>
	self._BotsByTeam = { {}, {}, {}, {}, {} } -- neutral, team1, team2, team3, team4
	---@type table<integer, EntryInput>
	---`[Player.id] -> EntryInput`
	self._BotInputs = {}
	---@type string[]
	---`playerName:string[]`
	self._ActivePlayers = {}
	self._BotAttackBotTimer = 0.0
	self._DestroyBotsTimer = 0.0
	---@type string[]
	---`BotName[]`
	self._BotsToDestroy = {}

	---@type string[]
	---`BotName[]`
	self._BotBotAttackList = {}
	self._RaycastsPerActivePlayer = 0
	---@type table<string, boolean>
	---`[BotName] -> boolean`
	self._BotCheckState = {}

	---@type table<string, boolean>
	---`[botPlayer.id .. "-" .. enemyBotPlayer.id] -> boolean`
	self._ConnectionCheckState = {}

	self._LastBotCheckIndex = 1
	self._LastPlayerCheckIndex = 1
	self._InitDone = false
end

-- =============================================
-- Events
-- =============================================

---VEXT Shared Level:Destroy Event
function BotManager:OnLevelDestroy()
	m_Logger:Write("destroyLevel")

	self:ResetAllBots()
	self._ActivePlayers = {}
	self._InitDone = false
end

---VEXT Shared UpdateManager:Update Event
---@param p_DeltaTime number
---@param p_UpdatePass UpdatePass|integer
function BotManager:OnUpdateManagerUpdate(p_DeltaTime, p_UpdatePass)
	if p_UpdatePass ~= UpdatePass.UpdatePass_PostFrame then
		return
	end

	for _, l_Bot in pairs(self._Bots) do
		l_Bot:OnUpdatePassPostFrame(p_DeltaTime)
	end

	if Config.BotsAttackBots and self._InitDone then
		if self._BotAttackBotTimer >= Registry.GAME_RAYCASTING.BOT_BOT_CHECK_INTERVAL then
			self._BotAttackBotTimer = 0.0
			self:_CheckForBotBotAttack()
		end

		self._BotAttackBotTimer = self._BotAttackBotTimer + p_DeltaTime
	end

	if #self._BotsToDestroy > 0 then
		if self._DestroyBotsTimer >= 0.05 then
			self._DestroyBotsTimer = 0.0
			self:DestroyBot(table.remove(self._BotsToDestroy))
		end

		self._DestroyBotsTimer = self._DestroyBotsTimer + p_DeltaTime
	end
end

---VEXT Server Player:Left Event
---@param p_Player Player
function BotManager:OnPlayerLeft(p_Player)
	-- Remove all references of player.
	for _, l_Bot in pairs(self._Bots) do
		l_Bot:ClearPlayer(p_Player)
	end

	for l_Index, l_PlayerName in pairs(self._ActivePlayers) do
		if l_PlayerName == p_Player.name then
			table.remove(self._ActivePlayers, l_Index)
			break
		end
	end

	-- Check if player used a Bot-Name.
	if Registry.COMMON.ALLOW_PLAYER_BOT_NAMES then
		for l_Index, l_BotNameToIgnore in pairs(Globals.IgnoreBotNames) do
			if l_BotNameToIgnore == p_Player.name then
				table.remove(Globals.IgnoreBotNames, l_Index)
				m_Logger:Write("Bot-Name " .. l_BotNameToIgnore .. " usable again")
			end
		end
	end
end

---@param p_BotName string
function BotManager:OnBotAbortWait(p_BotName)
	local s_Bot = self:GetBotByName(p_BotName)

	if s_Bot ~= nil then
		s_Bot:ResetVehicleTimer()
	end
end

---@param p_BotName string
function BotManager:OnBotExitVehicle(p_BotName)
	local s_Bot = self:GetBotByName(p_BotName)

	if s_Bot ~= nil then
		s_Bot:ExitVehicle()
	end
end

---VEXT Server Vehicle:Damage Event
---@param p_VehicleEntity Entity @`ControllableEntity`
---@param p_Damage number
---@param p_DamageGiverInfo DamageGiverInfo|nil
function BotManager:OnVehicleDamage(p_VehicleEntity, p_Damage, p_DamageGiverInfo)
	-- Ignore healing.
	if p_Damage <= 0.0 then
		return
	end

	-- Ignore if no damage giver.
	if not p_DamageGiverInfo or not p_DamageGiverInfo.giver then
		return
	end

	-- Detect if we need to shoot back.
	if not Config.ShootBackIfHit then
		return
	end

	p_VehicleEntity = ControllableEntity(p_VehicleEntity)
	---@cast p_VehicleEntity ControllableEntity

	-- Loop all seats / entries.
	for l_EntryId = 0, p_VehicleEntity.entryCount - 1 do
		local s_Player = p_VehicleEntity:GetPlayerInEntry(l_EntryId)

		-- Make sure it's a bot.
		if s_Player and m_Utilities:isBot(s_Player) then
			local s_Bot = self:GetBotByName(s_Player.name)

			if not s_Bot then
				m_Logger:Error("Could not find Bot for bot player " .. s_Player.name)
				return
			end

			-- Shoot back.
			s_Bot:ShootAt(p_DamageGiverInfo.giver, true)
		end
	end
end

-- =============================================
-- Hooks
-- =============================================

---VEXT Server Soldier:Damage Hook
---@param p_HookCtx HookContext
---@param p_Soldier SoldierEntity
---@param p_Info DamageInfo
---@param p_GiverInfo DamageGiverInfo|nil
function BotManager:OnSoldierDamage(p_HookCtx, p_Soldier, p_Info, p_GiverInfo)
	-- Soldier → soldier damage only.

	-- Ignore if there is no player for this soldier.
	if not p_Soldier.player then
		return
	end

	-- Ignore healing.
	if p_Info.damage <= 0.0 then
		return
	end

	-- This is a bot.
	if m_Utilities:isBot(p_Soldier.player) then
		if p_GiverInfo and p_GiverInfo.giver then
			-- Detect if we need to shoot back.
			if Config.ShootBackIfHit then
				self:OnShootAt(p_GiverInfo.giver, p_Soldier.player.name, true)
			end

			-- Prevent bots from killing themselves. Bad bot, no suicide.
			if not Config.BotCanKillHimself and p_Soldier.player == p_GiverInfo.giver then
				p_Info.damage = 0.0
			end
		end
	-- This is a real player; check if the damage was dealt by a bot.
	else
		-- We have a giver.
		if p_GiverInfo and p_GiverInfo.giver then
			local s_Bot = self:GetBotByName(p_GiverInfo.giver.name)

			-- This damage was dealt by a bot.
			if s_Bot and s_Bot.m_Player.soldier then
				-- Update the bot damage with the multipliers from the config.
				p_Info.damage = self:_GetDamageValue(p_Info.damage, s_Bot, p_Soldier)
			end
		end
	end

	-- Pass everything, modified or not.
	p_HookCtx:Pass(p_Soldier, p_Info, p_GiverInfo)
end

-- =============================================
-- Custom (Net-)Events
-- =============================================

---@param p_Player Player
---@param p_BotName string
---@param p_IgnoreYaw boolean
function BotManager:OnShootAt(p_Player, p_BotName, p_IgnoreYaw)
	local s_Bot = self:GetBotByName(p_BotName)

	if not s_Bot then
		return
	end

	s_Bot:ShootAt(p_Player, p_IgnoreYaw)
end

---@param p_Player Player
---@param p_BotName string
function BotManager:OnRevivePlayer(p_Player, p_BotName)
	local s_Bot = self:GetBotByName(p_BotName)

	if not s_Bot then
		return
	end

	s_Bot:Revive(p_Player)
end

---@param p_Player Player
---@param p_BotName1 string
---@param p_BotName2 string
function BotManager:OnBotShootAtBot(p_Player, p_BotName1, p_BotName2)
	local s_Bot1 = self:GetBotByName(p_BotName1)

	if not s_Bot1 then
		return
	end

	local s_Bot2 = self:GetBotByName(p_BotName2)

	if not s_Bot2 then
		return
	end

	if s_Bot1:ShootAt(s_Bot2.m_Player, false) then
		self._BotCheckState[s_Bot1.m_Player.name] = true
	end

	if s_Bot2:ShootAt(s_Bot1.m_Player, false) then
		self._BotCheckState[s_Bot2.m_Player.name] = true
	end
end

---@param p_MissileEntity Entity
function BotManager:CheckForFlareOrSmoke(p_MissileEntity)
	p_MissileEntity = SpatialEntity(p_MissileEntity)

	local s_MissileTransform = p_MissileEntity.transform
	local s_MissilePosition = s_MissileTransform.trans

	local s_SmallestAngle = 1.0
	local s_DriverOfVehicle = nil

	local s_Iterator = EntityManager:GetIterator("ServerVehicleEntity")
	local s_Entity = s_Iterator:Next()
	while s_Entity ~= nil do
		s_Entity = ControllableEntity(s_Entity)
		local s_DriverPlayer = s_Entity:GetPlayerInEntry(0)
		if s_DriverPlayer then
			local s_PositionVehicle = s_Entity.transform.trans
			local s_VecMissile = (s_PositionVehicle - s_MissilePosition):Normalize()

			local s_Angle = math.acos(s_VecMissile:Dot(s_MissileTransform.forward))
			local s_Distance = s_PositionVehicle:Distance(s_MissilePosition)

			if s_Angle < s_SmallestAngle and s_Distance < 350 then
				s_SmallestAngle = s_Angle
				s_DriverOfVehicle = s_DriverPlayer
			end
		end

		s_Entity = s_Iterator:Next()
	end

	if not s_DriverOfVehicle then
		return
	end

	local s_TargetBot = self:GetBotByName(s_DriverOfVehicle.name)
	if s_TargetBot then
		s_TargetBot:FireFlareSmoke()
	end
end

function BotManager:OnClientRaycastResults(p_Player, p_RaycastResults)
	if p_RaycastResults == nil then
		return
	end

	for _, l_RaycastResult in ipairs(p_RaycastResults) do
		if l_RaycastResult.Mode == "ShootAtBot" then
			self:OnBotShootAtBot(p_Player, l_RaycastResult.Bot1, l_RaycastResult.Bot2)
		elseif l_RaycastResult.Mode == "ShootAtPlayer" then
			self:OnShootAt(p_Player, l_RaycastResult.Bot1, l_RaycastResult.IgnoreYaw)
		elseif l_RaycastResult.Mode == "RevivePlayer" then
			self:OnRevivePlayer(p_Player, l_RaycastResult.Bot1)
		end
	end
end

---@param p_Player Player
---@param p_BotName string
function BotManager:OnRequestEnterVehicle(p_Player, p_BotName)
	local s_Bot = self:GetBotByName(p_BotName)

	if s_Bot and s_Bot.m_Player.soldier then
		s_Bot:EnterVehicleOfPlayer(p_Player)
	end
end

---@param p_Player Player
---@param p_SeatNumber integer
function BotManager:OnRequestChangeSeatVehicle(p_Player, p_SeatNumber)
	local s_TargetEntryId = p_SeatNumber - 1
	local s_VehicleEntity = p_Player.controlledControllable

	if s_VehicleEntity and s_VehicleEntity.typeInfo.name == "ServerSoldierEntity" then
		s_VehicleEntity = p_Player.attachedControllable
	end

	-- No vehicle found.
	if not s_VehicleEntity then
		return
	end

	-- Player in target seat.
	local s_TargetPlayer = s_VehicleEntity:GetPlayerInEntry(s_TargetEntryId)

	-- No player in target seat.
	if not s_TargetPlayer then
		return
	end

	local s_Bot = self:GetBotByName(s_TargetPlayer.name)

	-- Real player in target seat.
	if not s_Bot then
		return
	end

	-- Exit vehicle with bot, so the real player can get this seat.
	s_Bot:AbortAttack()
	s_Bot.m_Player:ExitVehicle(false, false)
	p_Player:EnterVehicle(s_VehicleEntity, s_TargetEntryId)

	-- Find next free seat and re-enter with the bot if possible.
	for i = 0, s_VehicleEntity.entryCount - 1 do
		if s_VehicleEntity:GetPlayerInEntry(i) == nil then
			s_Bot.m_Player:EnterVehicle(s_VehicleEntity, i)
			s_Bot:UpdateVehicleMovableId()
			break
		end
	end
end

-- =============================================
-- Functions
-- =============================================

-- =============================================
-- Public Functions
-- =============================================

---@param p_Player Player
function BotManager:RegisterActivePlayer(p_Player)
	-- Check if the player is already listed
	for _, l_PlayerName in ipairs(self._ActivePlayers) do
		if l_PlayerName == p_Player.name then
			return
		end
	end

	-- Not listed, add to the list.
	table.insert(self._ActivePlayers, p_Player.name)
end

---Returns the teamId for the team that has the most real players
---@return TeamId
function BotManager:GetPlayerTeam()

	--- Count real players for each team
	---@type table<TeamId, integer>
	local s_CountPlayers = {}

	for l_TeamId = TeamId.Team1, Globals.NrOfTeams do
		---@cast l_TeamId TeamId

		s_CountPlayers[l_TeamId] = 0
		local s_Players = PlayerManager:GetPlayersByTeam(l_TeamId)

		for l_Index = 1, #s_Players do
			if not m_Utilities:isBot(s_Players[l_Index]) then
				s_CountPlayers[l_TeamId] = s_CountPlayers[l_TeamId] + 1
			end
		end
	end

	-- Get the team with the highest real-player count.
	---@type TeamId
	local s_PlayerTeam = TeamId.Team1

	for l_TeamId = TeamId.Team2, Globals.NrOfTeams do
		---@cast l_TeamId TeamId
		if s_CountPlayers[l_TeamId] > s_CountPlayers[s_PlayerTeam] then
			s_PlayerTeam = l_TeamId
		end
	end

	return s_PlayerTeam
end

---@return TeamId
function BotManager:GetBotTeam()
	if Config.BotTeam ~= TeamId.TeamNeutral then
		return Config.BotTeam
	end

	--- Count bot players for each team.
	---@type table<TeamId, integer>
	local s_CountPlayers = {}

	for l_TeamId = TeamId.Team1, Globals.NrOfTeams do
		---@cast l_TeamId TeamId
		s_CountPlayers[l_TeamId] = 0
		local s_Players = PlayerManager:GetPlayersByTeam(l_TeamId)

		for l_Index = 1, #s_Players do
			if not m_Utilities:isBot(s_Players[l_Index]) then
				s_CountPlayers[l_TeamId] = s_CountPlayers[l_TeamId] + 1
			end
		end
	end

	-- Get the team with the lowest bot-player count.
	---@type TeamId
	local s_BotTeam = TeamId.Team1

	for l_TeamId = TeamId.Team2, Globals.NrOfTeams do
		---@cast l_TeamId TeamId
		if s_CountPlayers[l_TeamId] < s_CountPlayers[s_BotTeam] then
			s_BotTeam = l_TeamId
		end
	end

	return s_BotTeam
end

function BotManager:ConfigGlobals()
	Globals.RespawnWayBots = Config.RespawnWayBots
	Globals.AttackWayBots = Config.AttackWayBots
	Globals.SpawnMode = Config.SpawnMode
	Globals.YawPerFrame = self:CalcYawPerFrame()

	local s_MaxPlayersRCON = RCON:SendCommand('vars.maxPlayers')
	local s_MaxPlayers = tonumber(s_MaxPlayersRCON[2])

	if s_MaxPlayers and s_MaxPlayers > 0 then
		Globals.MaxPlayers = s_MaxPlayers
		m_Logger:Write("there are " .. s_MaxPlayers .. " slots on this server")
	else
		-- Only fallback. Should not happen.
		Globals.MaxPlayers = 127
		m_Logger:Error("No Playercount found")
	end

	-- Calculate Raycast per Player.
	local s_FactorTicksUpdate = Registry.GAME_RAYCASTING.BOT_BOT_CHECK_INTERVAL * SharedUtils:GetTickrate()
	local s_RaycastsMax = s_FactorTicksUpdate * (Registry.GAME_RAYCASTING.MAX_RAYCASTS_PER_PLAYER_BOT_BOT)
	-- Always round down one.
	self._RaycastsPerActivePlayer = math.floor(s_RaycastsMax - 0.1)

	self._InitDone = true
end

---@return number
function BotManager:CalcYawPerFrame()
	local s_DegreePerDeltaTime = Config.MaximunYawPerSec / SharedUtils:GetTickrate()
	return (s_DegreePerDeltaTime / 360.0) * 2 * math.pi
end

---@return string|nil
function BotManager:FindNextBotName()
	for _, l_Name in ipairs(BotNames) do
		local s_Name = Registry.COMMON.BOT_TOKEN .. l_Name
		local s_SkipName = false

		for _, l_IgnoreName in ipairs(Globals.IgnoreBotNames) do
			if s_Name == l_IgnoreName then
				s_SkipName = true
				break
			end
		end

		if not s_SkipName then
			local s_Bot = self:GetBotByName(s_Name)

			if not s_Bot and not PlayerManager:GetPlayerByName(s_Name) then
				return s_Name
			elseif s_Bot and not s_Bot.m_Player.soldier and s_Bot:GetSpawnMode() ~= BotSpawnModes.RespawnRandomPath then
				return s_Name
			end
		end
	end

	return nil
end

---@param p_TeamId? TeamId
---@return Bot[]
function BotManager:GetBots(p_TeamId)
	if p_TeamId ~= nil then
		return self._BotsByTeam[p_TeamId + 1]
	else
		return self._Bots
	end
end

---@return integer
function BotManager:GetBotCount()
	return #self._Bots
end

---@param p_TeamId? TeamId
---@return integer
function BotManager:GetActiveBotCount(p_TeamId)
	local s_Count = 0

	for _, l_Bot in ipairs(self._Bots) do
		if not l_Bot:IsInactive() then
			if p_TeamId == nil or l_Bot.m_Player.teamId == p_TeamId then
				s_Count = s_Count + 1
			end
		end
	end

	return s_Count
end

-- Returns all real players.
---@return Player[]
function BotManager:GetPlayers()
	local s_AllPlayers = PlayerManager:GetPlayers()
	local s_Players = {}

	for i = 1, #s_AllPlayers do
		if not m_Utilities:isBot(s_AllPlayers[i]) then
			table.insert(s_Players, s_AllPlayers[i])
		end
	end

	return s_Players
end

---Returns real player count
---@return integer
function BotManager:GetPlayerCount()
	return PlayerManager:GetPlayerCount() - #self._Bots
end

---Get the amount of bots using this kit
---@param p_Kit BotKits
---@return integer
function BotManager:GetKitCount(p_Kit)
	local s_Count = 0

	for _, l_Bot in ipairs(self._Bots) do
		if l_Bot.m_Kit == p_Kit then
			s_Count = s_Count + 1
		end
	end

	return s_Count
end

---@param p_Player Player
---@param p_Option string|'"mode"'|'"speed"'
---@param p_Value BotMoveModes|BotMoveSpeeds
function BotManager:SetStaticOption(p_Player, p_Option, p_Value)
	for _, l_Bot in ipairs(self._Bots) do
		if l_Bot:GetTargetPlayer() == p_Player then
			if l_Bot:IsStaticMovement() then
				if p_Option == "mode" then
					---@cast p_Value BotMoveModes
					l_Bot:SetMoveMode(p_Value)
				end
			end
		end
	end
end

---@param p_Option string|'"shoot"'|'"respawn"'|'"moveMode"'
---@param p_Value boolean|BotMoveModes
function BotManager:SetOptionForAll(p_Option, p_Value)
	for _, l_Bot in pairs(self._Bots) do
		if p_Option == "shoot" then
			---@cast p_Value boolean
			l_Bot:SetShoot(p_Value)
		elseif p_Option == "respawn" then
			---@cast p_Value boolean
			l_Bot:SetRespawn(p_Value)
		elseif p_Option == "moveMode" then
			---@cast p_Value BotMoveModes
			l_Bot:SetMoveMode(p_Value)
		end
	end
end

---@param p_Player Player
---@param p_Option string|'"shoot"'|'"respawn"'|'"moveMode"'
---@param p_Value boolean|BotMoveModes
function BotManager:SetOptionForPlayer(p_Player, p_Option, p_Value)
	for _, l_Bot in pairs(self._Bots) do
		if l_Bot:GetTargetPlayer() == p_Player then
			if p_Option == "shoot" then
				---@cast p_Value boolean
				l_Bot:SetShoot(p_Value)
			elseif p_Option == "respawn" then
				---@cast p_Value boolean
				l_Bot:SetRespawn(p_Value)
			elseif p_Option == "moveMode" then
				---@cast p_Value BotMoveModes
				l_Bot:SetMoveMode(p_Value)
			end
		end
	end
end

---@param p_Name string
---@return Bot|nil
function BotManager:GetBotByName(p_Name)
	return self._BotsByName[p_Name]
end

---@param p_Name string
---@param p_TeamId TeamId
---@param p_SquadId SquadId
---@return Bot|nil
function BotManager:CreateBot(p_Name, p_TeamId, p_SquadId)
	-- m_Logger:Write('botsByTeam['..#self._BotsByTeam[2]..'|'..#self._BotsByTeam[3]..']')

	local s_Bot = self:GetBotByName(p_Name)

	-- Bot exists, so just reset him.
	if s_Bot ~= nil then
		s_Bot.m_Player.teamId = p_TeamId
		s_Bot.m_Player.squadId = p_SquadId
		s_Bot:ResetVars()
		return s_Bot
	end

	-- Check for max-players.
	local s_PlayerLimit = Globals.MaxPlayers

	if Config.KeepOneSlotForPlayers then
		s_PlayerLimit = s_PlayerLimit - 1
	end

	if s_PlayerLimit <= PlayerManager:GetPlayerCount() then
		m_Logger:Write("playerlimit reached")
		return nil
	end

	-- Create a player for this bot.
	local s_BotPlayer = PlayerManager:CreatePlayer(p_Name, p_TeamId, p_SquadId)

	if s_BotPlayer == nil then
		m_Logger:Write("can't create more players on this team")
		return nil
	end

	-- Create input for this bot.
	local s_BotInput = EntryInput()
	s_BotInput.deltaTime = 1.0 / SharedUtils:GetTickrate()
	s_BotInput.flags = EntryInputFlags.AuthoritativeAiming
	s_BotPlayer.input = s_BotInput

	---@type Bot
	s_Bot = Bot(s_BotPlayer)

	table.insert(self._Bots, s_Bot)
	self._BotsByName[p_Name] = s_Bot

	-- Teamid's in self._BotsByTeam are offset by 1.
	local s_TeamLookup = s_Bot.m_Player.teamId + 1
	self._BotsByTeam[s_TeamLookup] = self._BotsByTeam[s_TeamLookup] or {}
	table.insert(self._BotsByTeam[s_TeamLookup], s_Bot)

	-- Bot inputs are stored to prevent garbage collection.
	self._BotInputs[s_BotPlayer.id] = s_BotInput
	return s_Bot
end

---@param p_Bot Bot
---@param p_Transform LinearTransform
---@param p_Pose CharacterPoseType
function BotManager:SpawnBot(p_Bot, p_Transform, p_Pose)
	local s_BotPlayer = p_Bot.m_Player

	if s_BotPlayer.soldier ~= nil then
		s_BotPlayer.soldier:Destroy()
	end

	if s_BotPlayer.corpse ~= nil then
		s_BotPlayer.corpse:Destroy()
	end

	-- Returns SoldierEntity.
	local s_BotSoldier = s_BotPlayer:CreateSoldier(s_BotPlayer.selectedKit, p_Transform)

	if not s_BotSoldier then
		m_Logger:Error("CreateSoldier failed")
		return nil
	end

	-- Customization of health of bot.
	s_BotSoldier.maxHealth = Config.BotMaxHealth

	s_BotPlayer:SpawnSoldierAt(s_BotSoldier, p_Transform, p_Pose)
	s_BotPlayer:AttachSoldier(s_BotSoldier)
end

---@param p_Player Player
function BotManager:KillPlayerBots(p_Player)
	for _, l_Bot in ipairs(self._Bots) do
		if l_Bot:GetTargetPlayer() == p_Player then
			l_Bot:ResetVars()

			if l_Bot.m_Player.soldier then
				l_Bot.m_Player.soldier:Kill()
			end
		end
	end
end

function BotManager:ResetAllBots()
	for _, l_Bot in ipairs(self._Bots) do
		l_Bot:ResetVars()
	end
end

function BotManager:ResetSkills()
	for _, l_Bot in ipairs(self._Bots) do
		l_Bot:ResetSkill()
	end
end

---@param p_Amount? integer
---@param p_TeamId? TeamId
function BotManager:KillAll(p_Amount, p_TeamId)
	local s_BotTable = self._Bots

	if p_TeamId then
		s_BotTable = self._BotsByTeam[p_TeamId + 1]
	end

	p_Amount = p_Amount or #s_BotTable

	for _, l_Bot in ipairs(s_BotTable) do
		l_Bot:Kill()

		p_Amount = p_Amount - 1

		if p_Amount <= 0 then
			return
		end
	end
end

---@param p_Amount? integer
---@param p_TeamId? TeamId
---@param p_Force? boolean
function BotManager:DestroyAll(p_Amount, p_TeamId, p_Force)
	local s_BotTable = self._Bots

	if p_TeamId then
		s_BotTable = self._BotsByTeam[p_TeamId + 1]
	end

	p_Amount = p_Amount or #s_BotTable

	for _, l_Bot in ipairs(s_BotTable) do
		if p_Force then
			self:DestroyBot(l_Bot)
		else
			table.insert(self._BotsToDestroy, l_Bot.m_Name)
		end

		p_Amount = p_Amount - 1

		if p_Amount <= 0 then
			return
		end
	end
end

function BotManager:DestroyDisabledBots()
	for _, l_Bot in ipairs(self._Bots) do
		if l_Bot:IsInactive() then
			table.insert(self._BotsToDestroy, l_Bot.m_Name)
		end
	end
end

---@param p_Player Player
function BotManager:DestroyPlayerBots(p_Player)
	for _, l_Bot in ipairs(self._Bots) do
		if l_Bot:GetTargetPlayer() == p_Player then
			table.insert(self._BotsToDestroy, l_Bot.m_Name)
		end
	end
end

function BotManager:RefreshTables()
	local s_NewTeamsTable = { {}, {}, {}, {}, {} }
	local s_NewBotTable = {}
	local s_NewBotbyNameTable = {}

	for _, l_Bot in ipairs(self._Bots) do
		if l_Bot.m_Player ~= nil then
			table.insert(s_NewBotTable, l_Bot)
			table.insert(s_NewTeamsTable[l_Bot.m_Player.teamId + 1], l_Bot)
			s_NewBotbyNameTable[l_Bot.m_Player.name] = l_Bot
		end
	end

	self._Bots = s_NewBotTable
	self._BotsByTeam = s_NewTeamsTable
	self._BotsByName = s_NewBotbyNameTable
end

---@param p_Bot Bot @might be a string as well
function BotManager:DestroyBot(p_Bot)
	if type(p_Bot) == 'string' then
		p_Bot = self._BotsByName[p_Bot]
	end

	-- Bot was not found.
	if p_Bot == nil then
		return
	end

	for l_Index = #self._Bots, 1, -1 do
		local s_Bot = self._Bots[l_Index]

		if p_Bot.m_Name == s_Bot.m_Name then
			table.remove(self._Bots, l_Index)
		end

		-- This will clear all references of the bot that gets destroyed.
		s_Bot:ClearPlayer(p_Bot.m_Player)
	end

	local s_BotTeam = self._BotsByTeam[p_Bot.m_Player.teamId + 1]

	for l_Index = #s_BotTeam, 1, -1 do
		local s_Bot = s_BotTeam[l_Index]

		if p_Bot.m_Name == s_Bot.m_Name then
			table.remove(s_BotTeam, l_Index)
		end
	end

	self._BotsByName[p_Bot.m_Name] = nil
	self._BotInputs[p_Bot.m_Id] = nil

	p_Bot:Destroy()
	---@diagnostic disable-next-line: cast-local-type
	p_Bot = nil
end

-- Comm-Actions.
-- All bots that are close to this player (and in the same team) leave the vehicles.
---@param p_Player Player
function BotManager:ExitVehicle(p_Player)
	if not p_Player.soldier then
		return
	end

	-- Find the closest bots in vehicle.
	local s_ClosestDistance = nil
	---@type Bot|nil
	local s_ClosestBot = nil

	local s_SoldierPosition = p_Player.soldier.worldTransform.trans

	for _, l_Bot in ipairs(self._BotsByTeam[p_Player.teamId + 1]) do
		if l_Bot.m_InVehicle and l_Bot.m_Player.soldier then
			local s_BotSoldierPosition = nil
			if l_Bot.m_Player.controlledControllable then
				s_BotSoldierPosition = l_Bot.m_Player.controlledControllable.transform.trans
			else
				s_BotSoldierPosition = l_Bot.m_Player.soldier.worldTransform.trans
			end

			if s_BotSoldierPosition then
				if s_ClosestBot == nil then
					s_ClosestBot = l_Bot
					s_ClosestDistance = s_BotSoldierPosition:Distance(s_SoldierPosition)
				else
					local s_Distance = s_BotSoldierPosition:Distance(s_SoldierPosition)

					if s_Distance < s_ClosestDistance then
						s_ClosestDistance = s_Distance
						s_ClosestBot = l_Bot
					end
				end
			end
		end
	end

	--- if there is a bot, then there is a number as well
	---@cast s_ClosestDistance number

	if s_ClosestBot and s_ClosestDistance < Registry.COMMON.COMMAND_DISTANCE then
		local s_VehicleEntity = s_ClosestBot.m_Player.controlledControllable

		if s_VehicleEntity then
			for l_EntryId = 0, s_VehicleEntity.entryCount - 1 do
				local s_Player = s_VehicleEntity:GetPlayerInEntry(l_EntryId)

				if s_Player then
					self:OnBotExitVehicle(s_Player.name)
				end
			end
		end
	end
end

---@param p_Player Player
---@param p_Type string|'"ammo"'|'"medkit"'
function BotManager:Deploy(p_Player, p_Type)
	if not p_Player or not p_Player.soldier then
		return
	end

	local s_SoldierPosition = p_Player.soldier.worldTransform.trans

	for _, l_Bot in ipairs(self._BotsByTeam[p_Player.teamId + 1]) do
		if not l_Bot.m_InVehicle then
			local s_BotPosition = l_Bot.m_Player.soldier and l_Bot.m_Player.soldier.worldTransform.trans

			if s_BotPosition then
				if p_Type == "ammo" and l_Bot.m_Kit == BotKits.Support then
					local s_Distance = s_BotPosition:Distance(s_SoldierPosition)

					if s_Distance < Registry.COMMON.COMMAND_DISTANCE then
						l_Bot:DeployIfPossible()
					end
				elseif p_Type == "medkit" and l_Bot.m_Kit == BotKits.Assault then
					local s_Distance = s_BotPosition:Distance(s_SoldierPosition)

					if s_Distance < Registry.COMMON.COMMAND_DISTANCE then
						l_Bot:DeployIfPossible()
					end
				end
			end
		end
	end
end

---@param p_Player Player
function BotManager:RepairVehicle(p_Player)
	if not p_Player or not p_Player.soldier or not p_Player.controlledControllable or
		p_Player.controlledControllable.typeInfo.name == "ServerSoldierEntity" then
		return
	end

	local s_SoldierPosition = p_Player.soldier.worldTransform.trans

	for _, l_Bot in ipairs(self._BotsByTeam[p_Player.teamId + 1]) do
		if not l_Bot.m_InVehicle and l_Bot.m_Kit == BotKits.Engineer then
			local s_BotSoldier = l_Bot.m_Player.soldier

			if s_BotSoldier then
				local s_Distance = s_BotSoldier.worldTransform.trans:Distance(s_SoldierPosition)

				if s_Distance < Registry.COMMON.COMMAND_DISTANCE then
					l_Bot:Repair(p_Player)
					break
				end
			end
		end
	end
end

---@param p_Player Player
function BotManager:EnterVehicle(p_Player)

	local s_VehicleType = m_Vehicles:FindOutVehicleType(p_Player)
	if s_VehicleType == VehicleTypes.NoVehicle or s_VehicleType == VehicleTypes.MobileArtillery then
		return
	end

	-- Check for vehicle of player and seats.
	local s_MaxFreeSeats = p_Player.controlledControllable.entryCount - 1

	if s_MaxFreeSeats <= 0 then
		return
	end

	local s_SoldierPosition = p_Player.soldier.worldTransform.trans

	for _, l_Bot in ipairs(self._BotsByTeam[p_Player.teamId + 1]) do
		if not l_Bot.m_InVehicle then
			local s_BotSoldier = l_Bot.m_Player.soldier

			if s_BotSoldier then
				local s_Distance = s_BotSoldier.worldTransform.trans:Distance(s_SoldierPosition)

				if s_Distance < Registry.COMMON.COMMAND_DISTANCE then
					l_Bot:EnterVehicleOfPlayer(p_Player)
					s_MaxFreeSeats = s_MaxFreeSeats - 1

					if s_MaxFreeSeats == 0 then
						break
					end
				end
			end
		end
	end
end

---@param p_Player Player
---@param p_Objective any To-do: add emmylua type
function BotManager:Attack(p_Player, p_Objective)
	if not Globals.IsConquest or not p_Player or not p_Player.soldier then
		return
	end

	local s_MaxObjectiveBots = 4
	local s_SoldierPosition = p_Player.soldier.worldTransform.trans

	for _, l_Bot in ipairs(self._BotsByTeam[p_Player.teamId + 1]) do
		local s_BotSoldier = l_Bot.m_Player.soldier

		if s_BotSoldier then
			local s_Distance = s_BotSoldier.worldTransform.trans:Distance(s_SoldierPosition)

			if s_Distance < Registry.COMMON.COMMAND_DISTANCE then
				l_Bot:UpdateObjective(p_Objective)
				s_MaxObjectiveBots = s_MaxObjectiveBots - 1

				if s_MaxObjectiveBots == 0 then
					break
				end
			end
		end
	end
end

-- =============================================
-- Private Functions
-- =============================================

---@param p_RaycastData any To-do: add emmylua type
function BotManager:_DistributeRaycastsBotBotAttack(p_RaycastData)
	local s_RaycastIndex = 0
	local s_RaycastDataCount = #p_RaycastData
	local s_ActivePlayerCount = #self._ActivePlayers

	for i = 0, (s_ActivePlayerCount - 1) do
		local s_Index = ((self._LastPlayerCheckIndex + i) % s_ActivePlayerCount) + 1
		local s_ActivePlayer = PlayerManager:GetPlayerByName(self._ActivePlayers[s_Index])

		if s_ActivePlayer ~= nil then
			local s_RaycastsToSend = {}

			for l_Count = 1, self._RaycastsPerActivePlayer do
				if s_RaycastIndex < s_RaycastDataCount then
					s_RaycastIndex = s_RaycastIndex + 1
					table.insert(s_RaycastsToSend, p_RaycastData[s_RaycastIndex])
				else
					NetEvents:SendUnreliableToLocal('CheckBotBotAttack', s_ActivePlayer, s_RaycastsToSend)
					self._LastPlayerCheckIndex = s_Index
					return
				end
			end

			NetEvents:SendUnreliableToLocal('CheckBotBotAttack', s_ActivePlayer, s_RaycastsToSend)
		end
	end
end

function BotManager:_CheckForBotBotAttack()
	-- Not enough on either team and no players to use.
	if #self._ActivePlayers == 0 then
		return
	end

	-- Create tables and scramble them.
	if #self._BotBotAttackList == 0 then
		-- Filter out bots not in StationaryAA.
		for _, l_Bot in ipairs(self._Bots) do
			if l_Bot.m_InVehicle then
				if l_Bot.m_ActiveVehicle and l_Bot.m_ActiveVehicle.Type ~= VehicleTypes.StationaryAA then
					table.insert(self._BotBotAttackList, l_Bot.m_Name)
				end
			else
				table.insert(self._BotBotAttackList, l_Bot.m_Name)
			end
		end

		-- Randomize the botlist order.
		for i = #self._BotBotAttackList, 2, -1 do
			local j = math.random(i)
			self._BotBotAttackList[i], self._BotBotAttackList[j] = self._BotBotAttackList[j], self._BotBotAttackList[i]
		end
	end

	local s_Raycasts = 0
	local s_ChecksDone = 0

	local s_RaycastEntries = {}

	for i = self._LastBotCheckIndex, #self._BotBotAttackList do
		-- Body.
		local s_BotNameToCheck = self._BotBotAttackList[i]
		local s_Bot = self:GetBotByName(s_BotNameToCheck)

		if s_Bot and s_Bot.m_Player and s_Bot.m_Player.soldier and s_Bot:IsReadyToAttack() then
			local s_BotPosition = nil
			if s_Bot.m_Player.controlledControllable then
				s_BotPosition = s_Bot.m_Player.controlledControllable.transform.trans
			else
				s_BotPosition = s_Bot.m_Player.soldier.worldTransform.trans
			end

			for _, l_BotName in ipairs(self._BotBotAttackList) do
				if l_BotName ~= s_BotNameToCheck then
					local s_EnemyBot = self:GetBotByName(l_BotName)

					if s_EnemyBot and s_EnemyBot.m_Player and s_EnemyBot.m_Player.soldier and
						s_EnemyBot.m_Player.teamId ~= s_Bot.m_Player.teamId and s_EnemyBot:IsReadyToAttack() then
						-- Check connection-state.
						local s_ConnectionValue = ""
						local s_Id1 = s_Bot.m_Player.id
						local s_Id2 = s_EnemyBot.m_Player.id

						if s_Id1 > s_Id2 then
							s_ConnectionValue = tostring(s_Id2) .. "-" .. tostring(s_Id1)
						else
							s_ConnectionValue = tostring(s_Id1) .. "-" .. tostring(s_Id2)
						end

						if not self._ConnectionCheckState[s_ConnectionValue] then
							self._ConnectionCheckState[s_ConnectionValue] = true
							-- Check distance.
							local s_EnemyBotPosition = nil
							if s_Bot.m_Player.controlledControllable then
								s_EnemyBotPosition = s_EnemyBot.m_Player.controlledControllable.transform.trans
							else
								s_EnemyBotPosition = s_EnemyBot.m_Player.soldier.worldTransform.trans
							end
							local s_Distance = s_BotPosition:Distance(s_EnemyBotPosition)
							s_ChecksDone = s_ChecksDone + 1
							local s_MaxDistance = s_Bot:GetAttackDistance()
							local s_MaxDistanceEnemyBot = s_EnemyBot:GetAttackDistance()

							if s_MaxDistanceEnemyBot > s_MaxDistance then
								s_MaxDistance = s_MaxDistanceEnemyBot
							end

							if s_Distance <= s_MaxDistance then
								table.insert(s_RaycastEntries, {
									Bot1 = s_BotNameToCheck,
									Bot2 = l_BotName,
									Bot1InVehicle = s_Bot.m_InVehicle,
									Bot2InVehicle = s_EnemyBot.m_InVehicle,
									Distance = s_Distance
								})
								s_Raycasts = s_Raycasts + 1

								if s_Raycasts >= (#self._ActivePlayers * self._RaycastsPerActivePlayer) then
									self._LastBotCheckIndex = i
									self:_DistributeRaycastsBotBotAttack(s_RaycastEntries)
									return
								end
							end

							if s_ChecksDone >= Registry.GAME_RAYCASTING.BOT_BOT_MAX_CHECKS then
								self._LastBotCheckIndex = i
								self:_DistributeRaycastsBotBotAttack(s_RaycastEntries)
								return
							end
						end
					end
				end
			end
		end

		self._LastBotCheckIndex = i
	end

	self:_DistributeRaycastsBotBotAttack(s_RaycastEntries)

	-- Should only reach here if every connection has been checked.
	-- Clear the cache and start over.
	self._LastBotCheckIndex = 1
	self._BotCheckState = {}
	self._ConnectionCheckState = {}
	self._BotBotAttackList = {}
end

---@param p_Damage integer
---@param p_Bot Bot
---@param p_Soldier SoldierEntity
---@return number
function BotManager:_GetDamageValue(p_Damage, p_Bot, p_Soldier)
	local s_ResultDamage = 0.0
	local s_DamageFactor = 1.0

	local s_ActiveWeapon = p_Bot.m_ActiveWeapon

	if not s_ActiveWeapon then
		m_Logger:Error("Bot without active weapon in Soldier:Damage")
		return s_ResultDamage
	end

	local s_ActiveWeaponType = p_Bot.m_ActiveWeapon.type

	if s_ActiveWeaponType == WeaponTypes.Shotgun then
		s_DamageFactor = Config.DamageFactorShotgun
	elseif s_ActiveWeaponType == WeaponTypes.Assault then
		s_DamageFactor = Config.DamageFactorAssault
	elseif s_ActiveWeaponType == WeaponTypes.Carabine then
		s_DamageFactor = Config.DamageFactorCarabine
	elseif s_ActiveWeaponType == WeaponTypes.PDW then
		s_DamageFactor = Config.DamageFactorPDW
	elseif s_ActiveWeaponType == WeaponTypes.LMG then
		s_DamageFactor = Config.DamageFactorLMG
	elseif s_ActiveWeaponType == WeaponTypes.Sniper then
		s_DamageFactor = Config.DamageFactorSniper
	elseif s_ActiveWeaponType == WeaponTypes.Pistol then
		s_DamageFactor = Config.DamageFactorPistol
	elseif s_ActiveWeaponType == WeaponTypes.Knife then
		s_DamageFactor = Config.DamageFactorKnife
	end

	return p_Damage * s_DamageFactor
end

if g_BotManager == nil then
	---@type BotManager
	g_BotManager = BotManager()
end

return g_BotManager
