-- TX_Gameplay.lua (BROKEN fixture: every marked line must be reported)
include("TX_Util")

local function Probe(label, objName, index, method, ...)       -- spike probe helper (pcall by name)
	local obj = _G[objName]
	return pcall(obj and obj[method], obj, ...)
end

local function Helper(pid)
	Players[pid]:GetTreasury():ChangeGoldBalance(-10)          -- async-mutation (reached from Events.PlayerDefeat)
	return Game.GetRandNum(10, "bad")                          -- async-mutation
end

local function OnDefeat(pid)
	Helper(pid)
end

function Scan(store)
	for k, v in pairs(store.recs) do                           -- forbidden-pairs
		print(k, v)
	end
	counter = 1                                                -- global-assign-in-function
	local r = math.random(1, 10)                               -- forbidden (math.random)
	local t = os.time()                                        -- forbidden (os.* in G)
	local me = Game.GetLocalPlayer()                           -- forbidden (Game.GetLocalPlayer in G)
	local u = Plyers[0]                                        -- undefined-global (typo)
	local x = table.unpack({ 1, 2 })                           -- lua52
	local d = pUnit:GetDamagee()                               -- undefined-global + unknown-method
	UI.RequestPlayerOperation(0, PlayerOperations.EXECUTE_SCRIPT, {})  -- api-context
	ExposedMembers.TX = {}                                     -- forbidden
	TX_Util.Missing()                                          -- unknown-member
	local unit = store.unit
	unit:Kill()                                                -- forbidden (:Kill)
	print(Locale.Lookup("LOC_TX_TWO_ARGS", 1))                 -- text-args (needs 2)
	print(Locale.Lookup("LOC_TX_UNDEFINED_KEY"))               -- text-missing
	UnitManager.PlaceUnit(unit, 1, 1)                          -- api-scope (TX_Dev/ only)
	print("NOTIFICATION_TX_NOPE")                              -- notification-missing
	local tbl = GameInfo.NoSuchTable                           -- gameinfo-unknown (game DB only)
	local tbl2 = GameInfo.Buildings                            -- gameinfo-unlisted (warn)
	local m = MapLayers.ANYY                                   -- unknown-api (enum typo)
	Probe("S1", "Game", nil, "NoSuchCall", Game.NoSuchMember)  -- not audited (probe)
	return r, t, me, u, x, d, tbl, tbl2, m
end

GameEvents.OnGameTurnStartd.Add(Scan)                          -- unknown-event (typo)
Events.PlayerDefeat.Add(OnDefeat)
Events.UnitAddedToMap.Add(Scan)                                -- api-context (UI event in G)
TX_UIOnlyHelper()                                              -- undefined-global: only the UI state defines it

TX_Rules = {}
TX_Rules.ALL_REASON_CODES = {
	"NOT_HUMAN",
	"NO_TEXT_FOR_THIS",                                        -- text-reason (no LOC_TX_REASON_NO_TEXT_FOR_THIS)
}
