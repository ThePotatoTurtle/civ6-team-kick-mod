-- TX_Gameplay.lua (fixture; AddGameplayScripts entry point)
include("TX_Util")
include("TX_Rules")
include("TX_Spike")

local STORE_KEY = "TX_Proposals"

local function Load()
	local store = Game:GetProperty(STORE_KEY)
	if store == nil then
		store = { ids = {} }
	end
	return store
end

local function Commit(store)
	Game:SetProperty(STORE_KEY, store)
end

local function NotifyVote(voterID, proposerID, targetID)
	local data = {}
	data[ParameterTypes.MESSAGE] = Locale.Lookup("LOC_NOTIFICATION_TX_VOTE_REQUIRED_MESSAGE")
	data[ParameterTypes.SUMMARY] = Locale.Lookup("LOC_NOTIFICATION_TX_VOTE_REQUIRED_SUMMARY", proposerID, targetID)
	NotificationManager.SendNotification(voterID, GameInfo.Types["NOTIFICATION_TX_VOTE_REQUIRED"].Hash, data)
end

local function OnPropose(playerID, params)
	local store = Load()
	local reasons = TX_Rules.ProposeReasons(playerID, params.TargetID)
	if #reasons > 0 then
		TX_Log("Propose", Locale.Lookup("LOC_TX_REASON_" .. reasons[1]))
		return
	end
	store.ids[#store.ids + 1] = Game.GetCurrentGameTurn()
	Commit(store)
	for _, pid in ipairs(TX_Util.SortedAlivePlayers()) do
		if pid ~= playerID and pid ~= params.TargetID and Players[pid]:GetTeam() == Players[playerID]:GetTeam() then
			NotifyVote(pid, playerID, params.TargetID)
		end
	end
end

local function OnTurnStarted(turn)
	local store = Load()
	for _, k in ipairs(TX_SortedKeys(store)) do
		TX_Log("Turn", "store key " .. tostring(k) .. " turn " .. tostring(turn))
	end
	if turn == 1 then
		TX_RunSpike()
	end
end

-- Events.* are not synced: this handler only logs.
local function OnDefeatHint(pid)
	TX_Log("Defeat", "player " .. tostring(pid) .. " " .. Locale.Lookup("LOC_NOTIFICATION_TX_EXPELLED_SUMMARY"))
end

GameEvents.TX_Propose.Add(OnPropose)
GameEvents.OnGameTurnStarted.Add(OnTurnStarted)
Events.PlayerDefeat.Add(OnDefeatHint)
