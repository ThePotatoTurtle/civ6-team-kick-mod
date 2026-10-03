-- ===========================================================================
-- fake_engine.lua  (offline harness)
-- A small, deterministic imitation of the Civ VI Lua API for lupa's Lua 5.1
-- runtime, so the mod's real gameplay scripts can run in tests. Loaded fresh
-- for every test by tests/offline/run_tests.py, before lib/harness.lua.
-- Ported from the Expeditionary mod's harness, without its unit, map, city
-- and deal models (TX does not need them).
--
-- Globals provided: Game, Players, PlayerManager, PlayerConfigurations,
-- GameInfo, GameConfiguration, GameEvents, Events, LuaEvents,
-- NotificationManager, Locale, Network, include, ParameterTypes,
-- PlayerOperations. fake_ui.lua adds the UI context (UI, Controls, ...).
--
-- All mutable state lives in the global table FAKE so tests can inspect it.
-- Python injects: __py_read(path) -> text|nil, __py_find(name) -> relpath|nil,
-- __py_echo(line) (echo mode), FAKE_TEXT (LOC key -> en_US text) and
-- FAKE_EXTRA_TYPES (Types rows synthesised from the mod's SQL).
--
-- Facts mirrored here (measured in game by the Expeditionary mod, EFV):
--   * the Game property round trip drops empty strings and empty tables
--     (FAKE.dropEmpty, default true);
--   * Player:IsFreeCities and Diplomacy:HasOpenBordersFrom are nil in the
--     gameplay context and exist only while FAKE.context == "UI";
--   * the Free Cities (62) are at war with every major and the Barbarians
--     (63) with everyone, without a declaration (FAKE.permanentWars);
--   * PlayerManager.GetAliveIDs has no useful order: the fake returns it
--     DESCENDING so code that forgets to sort is caught.
-- Models that are NOT verified (TX spike items; switch them per test):
--   * FAKE.teamModel = "config" (default): PlayerConfigurations[i]:SetTeam
--     changes only the config team; Players[i]:GetTeam() keeps the old team
--     until FAKE.ApplyConfigTeams() (the save-and-reload hypothesis, Mode B).
--     "live": both change at once (Mode A).
--   * FAKE.teamWars = true (default): war is shared by teams (2017 patch
--     notes): a and b are at war when any member of a's team is at war with
--     any member of b's team.
-- ===========================================================================

FAKE = {
	turn = 1,
	log = {},                -- every print() line, in order
	echo = false,            -- set by the runner (--echo): mirror print to stdout
	props = {},              -- Game properties (deep-copied in/out)
	propViolations = {},     -- storage-rule violations seen by SetProperty
	propWrites = {},         -- key -> number of SetProperty calls
	rngSeed = 20260928,
	rngCalls = {},           -- { n, label, result }
	forbidden = {},          -- MP-unsafe calls seen in gameplay (math.random, Game.GetLocalPlayer)
	handlerErrors = {},      -- errors raised by event handlers
	players = {},            -- id -> player object
	notifications = {},      -- { pid, typeName, hash, data, id, dismissed, turn }
	nextNotifID = 1,
	freeCitiesID = 62,
	barbarianID = 63,
	context = "G",           -- "G" gameplay (UI == nil) or "UI"
	localPlayer = 0,         -- Game.GetLocalPlayer() (UI)
	dropEmpty = true,        -- Game property round trip drops "" and {}
	permanentWars = true,    -- Free Cities <-> majors and barbarians <-> everyone always at war
	teamWars = true,         -- war status shared by teams (model, see above)
	teamModel = "config",    -- "config" or "live" (model, see above)
	teamSets = {},           -- { pid, team, turn, context } for every PlayerConfigurations:SetTeam
	broadcasts = {},         -- { pid, turn, context } for every Network.BroadcastPlayerInfo
	gameConfig = {},         -- GameConfiguration.GetValue(key) values
	gameInfoLoaded = false,  -- true when tests/offline/data/gameinfo_data.lua was loaded
	configs = {},            -- id -> PlayerConfigurations object (one per player)
}

-- ---------------------------------------------------------------------------
-- Output capture
-- ---------------------------------------------------------------------------
function print(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	local line = table.concat(parts, "\t")
	FAKE.log[#FAKE.log + 1] = line
	if FAKE.echo and __py_echo ~= nil then
		__py_echo(line)
	end
end

-- MP-unsafe calls are recorded, not blocked.
local realRandom = math.random
math.random = function(...)
	FAKE.forbidden[#FAKE.forbidden + 1] = "math.random"
	return realRandom(...)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function DeepCopy(v, seen)
	if type(v) ~= "table" then
		return v
	end
	seen = seen or {}
	if seen[v] then
		return seen[v]
	end
	local c = {}
	seen[v] = c
	for k, x in pairs(v) do
		c[DeepCopy(k, seen)] = DeepCopy(x, seen)
	end
	return c
end
FAKE.DeepCopy = DeepCopy

local function SortedKeys(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then
			return ta < tb
		end
		return a < b
	end)
	return keys
end
FAKE.SortedKeys = SortedKeys

-- Storage rules for Game properties (EFV spike S3): string keys or dense
-- 1..n arrays, no key 0, no holes, only numbers / strings / tables inside
-- (booleans are reported: store 0/1).
local function ValidateStored(v, path, out)
	local tv = type(v)
	if tv == "number" or tv == "string" or tv == "nil" then
		return
	end
	if tv == "boolean" then
		out[#out + 1] = path .. ": boolean value (store 0/1)"
		return
	end
	if tv ~= "table" then
		out[#out + 1] = path .. ": unsupported type " .. tv
		return
	end
	local nStr, nNum, maxN = 0, 0, 0
	for k, x in pairs(v) do
		if type(k) == "string" then
			nStr = nStr + 1
		elseif type(k) == "number" then
			if k == 0 then
				out[#out + 1] = path .. ": key 0"
			elseif k ~= math.floor(k) or k < 0 then
				out[#out + 1] = path .. ": non-integer or negative key " .. tostring(k)
			else
				nNum = nNum + 1
				if k > maxN then
					maxN = k
				end
			end
		else
			out[#out + 1] = path .. ": key of type " .. type(k)
		end
		ValidateStored(x, path .. "." .. tostring(k), out)
	end
	if nStr > 0 and nNum > 0 then
		out[#out + 1] = path .. ": mixed string and number keys"
	end
	if nNum > 0 and maxN ~= nNum then
		out[#out + 1] = path .. ": array with holes (max " .. maxN .. ", count " .. nNum .. ")"
	end
end
FAKE.ValidateStored = ValidateStored

-- An empty string (and an empty table) inside a Game property comes back as nil.
local function StripEmpty(v)
	if type(v) == "string" and v == "" then
		return nil
	end
	if type(v) ~= "table" then
		return v
	end
	local keys = {}
	for k in pairs(v) do
		keys[#keys + 1] = k
	end
	for _, k in ipairs(keys) do
		v[k] = StripEmpty(v[k])
	end
	if next(v) == nil then
		return nil
	end
	return v
end
FAKE.StripEmpty = StripEmpty

local function NewPropertyHolder(label, store)
	return {
		SetProperty = function(self, k, v)
			local issues = {}
			ValidateStored(v, label .. "[" .. tostring(k) .. "]", issues)
			for _, s in ipairs(issues) do
				FAKE.propViolations[#FAKE.propViolations + 1] = s
			end
			if store == FAKE.props then
				FAKE.propWrites[k] = (FAKE.propWrites[k] or 0) + 1
			end
			local copy = DeepCopy(v)
			if FAKE.dropEmpty and label == "Game" then
				copy = StripEmpty(copy)
			end
			store[k] = copy
		end,
		GetProperty = function(self, k)
			return DeepCopy(store[k])
		end,
	}
end

-- ---------------------------------------------------------------------------
-- Enums (values are arbitrary but stable)
-- ---------------------------------------------------------------------------
ParameterTypes = { MESSAGE = "MESSAGE", SUMMARY = "SUMMARY", LOCATION = "LOCATION", PLAYER_ID = "PLAYER_ID" }
PlayerOperations = { EXECUTE_SCRIPT = 1 }

-- ---------------------------------------------------------------------------
-- Event registries: GameEvents.X.Add(fn) / .Remove(fn) / GameEvents.X(...)
-- ---------------------------------------------------------------------------
local function NewEvent(fullName)
	local ev = { name = fullName, handlers = {} }
	ev.Add = function(fn)
		ev.handlers[#ev.handlers + 1] = fn
	end
	ev.Remove = function(fn)
		for i = #ev.handlers, 1, -1 do
			if ev.handlers[i] == fn then
				table.remove(ev.handlers, i)
			end
		end
	end
	ev.Count = function()
		return #ev.handlers
	end
	return setmetatable(ev, {
		__call = function(self, ...)
			local list = {}
			for i, fn in ipairs(self.handlers) do
				list[i] = fn
			end
			for _, fn in ipairs(list) do
				local ok, err = pcall(fn, ...)
				if not ok then
					FAKE.handlerErrors[#FAKE.handlerErrors + 1] = fullName .. ": " .. tostring(err)
					print("Runtime Error: " .. fullName .. " handler: " .. tostring(err))
				end
			end
		end,
	})
end

local function NewEventNamespace(ns)
	return setmetatable({}, {
		__index = function(t, name)
			local ev = NewEvent(ns .. "." .. tostring(name))
			rawset(t, name, ev)
			return ev
		end,
	})
end
GameEvents = NewEventNamespace("GameEvents")
Events = NewEventNamespace("Events")
LuaEvents = NewEventNamespace("LuaEvents")

-- ---------------------------------------------------------------------------
-- GameInfo (rows exported from the cached gameplay DB, plus Types rows for
-- the mod's own notification types). GameInfo.T[key] accepts the primary-key
-- string, the 0-based Index or the Hash; GameInfo.T() iterates rows in order.
-- ---------------------------------------------------------------------------
local function HashString(s)
	-- FNV-1a 32-bit, returned as a signed int like the engine's hashes.
	local h = 2166136261
	for i = 1, string.len(s) do
		local b = string.byte(s, i)
		-- xor via arithmetic (Lua 5.1 has no bit ops)
		local x, y, r, m = h, b, 0, 1
		for _ = 1, 32 do
			local xa, ya = x % 2, y % 2
			if xa ~= ya then
				r = r + m
			end
			x = (x - xa) / 2
			y = (y - ya) / 2
			m = m * 2
		end
		h = (r * 16777619) % 4294967296
	end
	if h >= 2147483648 then
		h = h - 4294967296
	end
	return h
end
FAKE.HashString = HashString

GameInfo = {}
local typeHash = {}

local function BuildTable(name, spec)
	local byKey, byIndex, byHash, rows = {}, {}, {}, {}
	for i, src in ipairs(spec.rows) do
		local row = {}
		for k, v in pairs(src) do
			row[k] = v
		end
		row.Index = i - 1
		local pk = spec.pk and row[spec.pk] or nil
		if pk ~= nil and row.Hash == nil then
			row.Hash = typeHash[pk] or HashString(pk)
		end
		rows[#rows + 1] = row
		byIndex[row.Index] = row
		if pk ~= nil then
			byKey[pk] = row
		end
		if row.Hash ~= nil then
			byHash[row.Hash] = row
		end
	end
	local t = { __rows = rows, __spec = spec }
	setmetatable(t, {
		__index = function(_, k)
			if type(k) == "string" then
				return byKey[k]
			elseif type(k) == "number" then
				return byIndex[k] or byHash[k]
			end
			return nil
		end,
		__call = function()
			local i = 0
			return function()
				i = i + 1
				return rows[i]
			end
		end,
	})
	GameInfo[name] = t
end

-- data: the table returned by data/gameinfo_data.lua, or nil when the game DB
-- was never exported (then only Types exists). extraTypes: names of the mod's
-- KIND_NOTIFICATION types.
function FAKE.LoadGameInfo(data, extraTypes)
	FAKE.gameInfoLoaded = data ~= nil
	data = data or {}
	data.Types = data.Types or { pk = "Type", rows = {} }
	local seen = {}
	for _, r in ipairs(data.Types.rows) do
		typeHash[r.Type] = r.Hash
		seen[r.Type] = true
	end
	for _, tn in ipairs(extraTypes or {}) do
		if not seen[tn] then
			local h = HashString(tn)
			data.Types.rows[#data.Types.rows + 1] = { Type = tn, Hash = h, Kind = "KIND_NOTIFICATION" }
			typeHash[tn] = h
			seen[tn] = true
		end
	end
	FAKE.gameInfoData = data
	for _, name in ipairs(SortedKeys(data)) do
		BuildTable(name, data[name])
	end
end

-- Adds a Types row (tests that need a type the mod does not define).
function FAKE.AddType(typeName, kind)
	local data = FAKE.gameInfoData or { Types = { pk = "Type", rows = {} } }
	if GameInfo.Types ~= nil and GameInfo.Types[typeName] ~= nil then
		return GameInfo.Types[typeName]
	end
	local h = HashString(typeName)
	data.Types.rows[#data.Types.rows + 1] = { Type = typeName, Hash = h, Kind = kind or "KIND_NOTIFICATION" }
	typeHash[typeName] = h
	FAKE.gameInfoData = data
	BuildTable("Types", data.Types)
	return GameInfo.Types[typeName]
end

-- ---------------------------------------------------------------------------
-- Game, GameConfiguration, Network
-- ---------------------------------------------------------------------------
Game = NewPropertyHolder("Game", FAKE.props)
Game.GetCurrentGameTurn = function()
	return FAKE.turn
end
Game.GetRandNum = function(n, label)
	FAKE.rngSeed = (FAKE.rngSeed * 1103515245 + 12345) % 2147483648
	local r = 0
	if type(n) == "number" and n > 0 then
		r = FAKE.rngSeed % n
	end
	FAKE.rngCalls[#FAKE.rngCalls + 1] = { n = n, label = label, result = r }
	return r
end
Game.GetLocalPlayer = function()
	if FAKE.context == "G" then
		FAKE.forbidden[#FAKE.forbidden + 1] = "Game.GetLocalPlayer"
	end
	return FAKE.localPlayer or 0
end

GameConfiguration = {
	GetValue = function(k)
		return FAKE.gameConfig[k]
	end,
}

-- Staging-room pattern (base game): PlayerConfigurations[id]:SetTeam(t) then
-- Network.BroadcastPlayerInfo(id). The fake only records the call.
Network = {
	BroadcastPlayerInfo = function(pid)
		FAKE.broadcasts[#FAKE.broadcasts + 1] = { pid = pid, turn = FAKE.turn, context = FAKE.context }
	end,
}

-- ---------------------------------------------------------------------------
-- Players and diplomacy
-- ---------------------------------------------------------------------------
FAKE.diplo = { war = {}, allied = {}, friend = {}, ob = {}, met = {} }

local function PairGet(t, a, b)
	return t[a] ~= nil and t[a][b] == true
end
local function PairSet(t, a, b, v)
	t[a] = t[a] or {}
	t[a][b] = v and true or nil
end
FAKE.PairGet, FAKE.PairSet = PairGet, PairSet

local function PermanentWar(a, b)
	if FAKE.permanentWars == false then return false end
	local pa, pb = FAKE.players[a], FAKE.players[b]
	if pa == nil or pb == nil then return false end
	if pa.kind == "BARBARIAN" or pb.kind == "BARBARIAN" then return true end
	if (pa.kind == "FREE_CITIES" and pb.kind == "MAJOR") or (pb.kind == "FREE_CITIES" and pa.kind == "MAJOR") then
		return true
	end
	return false
end
FAKE.PermanentWar = PermanentWar

-- Living members of a team, ascending.
function FAKE.TeamMembers(team)
	local out = {}
	for _, id in ipairs(SortedKeys(FAKE.players)) do
		local p = FAKE.players[id]
		if p.team == team and p.alive then out[#out + 1] = id end
	end
	return out
end

function FAKE.IsAtWar(a, b)
	if a == b then return false end
	if PairGet(FAKE.diplo.war, a, b) or PermanentWar(a, b) then return true end
	if FAKE.teamWars then
		local pa, pb = FAKE.players[a], FAKE.players[b]
		if pa == nil or pb == nil or pa.team == pb.team then return false end
		for _, x in ipairs(FAKE.TeamMembers(pa.team)) do
			for _, y in ipairs(FAKE.TeamMembers(pb.team)) do
				if PairGet(FAKE.diplo.war, x, y) then return true end
			end
		end
	end
	return false
end

local function NewDiplomacy(pid)
	local d = {}
	function d:IsAtWarWith(b) return FAKE.IsAtWar(pid, b) end
	function d:HasAllied(b) return PairGet(FAKE.diplo.allied, pid, b) end
	function d:HasDeclaredFriendship(b) return PairGet(FAKE.diplo.friend, pid, b) end
	function d:HasMet(b)
		if b == pid then return true end
		return PairGet(FAKE.diplo.met, pid, b)
	end
	function d:DeclareWarOn(b) FAKE.SetWar(pid, b, true) end
	-- UI only (nil in G, measured by EFV).
	local ui = {}
	function ui.HasOpenBordersFrom(self, b) return PairGet(FAKE.diplo.ob, pid, b) end
	setmetatable(d, { __index = function(t, k)
		if FAKE.context == "UI" then
			return ui[k]
		end
		return nil
	end })
	return d
end

-- War is symmetric; it ends alliance, friendship and open borders both ways.
function FAKE.SetWar(a, b, v)
	PairSet(FAKE.diplo.war, a, b, v)
	PairSet(FAKE.diplo.war, b, a, v)
	PairSet(FAKE.diplo.met, a, b, true)
	PairSet(FAKE.diplo.met, b, a, true)
	if v then
		PairSet(FAKE.diplo.allied, a, b, false); PairSet(FAKE.diplo.allied, b, a, false)
		PairSet(FAKE.diplo.friend, a, b, false); PairSet(FAKE.diplo.friend, b, a, false)
		PairSet(FAKE.diplo.ob, a, b, false); PairSet(FAKE.diplo.ob, b, a, false)
	end
end

local Player = {}
local PlayerUI = {}  -- UI-only player methods (nil in G)
Player.__index = function(t, k)
	local v = Player[k]
	if v == nil and FAKE.context == "UI" then
		return PlayerUI[k]
	end
	return v
end
function Player:GetID() return self.id end
function Player:IsAlive() return self.alive == true end
function Player:IsHuman() return self.human == true end
function Player:IsMajor() return self.kind == "MAJOR" end
function Player:IsBarbarian() return self.kind == "BARBARIAN" end
function PlayerUI.IsFreeCities(self) return self.kind == "FREE_CITIES" end
function Player:GetTeam() return self.team end
function Player:GetDiplomacy() return self.diplomacy end
function Player:GetProperty(k) return DeepCopy(self.props[k]) end
function Player:SetProperty(k, v) self.props[k] = DeepCopy(v) end

Players = {}

-- opts: { alive = true, human = false, kind = "MAJOR"|"CITY_STATE"|"FREE_CITIES"|"BARBARIAN",
--         team = id, civ = "LOC_...", civType = "CIVILIZATION_...", leaderType = "LEADER_...", name = "..." }
function FAKE.NewPlayer(id, opts)
	opts = opts or {}
	local team = opts.team or id
	local p = setmetatable({
		id = id, alive = opts.alive ~= false, human = opts.human == true,
		kind = opts.kind or "MAJOR", team = team, configTeam = team, props = {},
		civ = opts.civ or ("LOC_CIVILIZATION_FAKE_" .. id .. "_NAME"),
		civType = opts.civType, leaderType = opts.leaderType, name = opts.name,
	}, Player)
	p.diplomacy = NewDiplomacy(id)
	Players[id] = p
	FAKE.players[id] = p
	FAKE.configs[id] = nil
	return p
end

-- Copies every config team to the live team: what a save and reload would do
-- if the Mode B hypothesis holds (unverified; tests call it on purpose).
function FAKE.ApplyConfigTeams()
	for _, id in ipairs(SortedKeys(FAKE.players)) do
		local p = FAKE.players[id]
		p.team = p.configTeam
	end
end

PlayerManager = {}
-- Returned in DESCENDING order on purpose: gameplay code must sort.
function PlayerManager.GetAliveIDs()
	local ids = {}
	for id, p in pairs(FAKE.players) do
		if p.alive then ids[#ids + 1] = id end
	end
	table.sort(ids, function(a, b) return a > b end)
	return ids
end
function PlayerManager.GetAliveMajors()
	local out = {}
	for _, id in ipairs(PlayerManager.GetAliveIDs()) do
		if FAKE.players[id].kind == "MAJOR" then out[#out + 1] = FAKE.players[id] end
	end
	return out
end
function PlayerManager.GetAliveMinors()
	local out = {}
	for _, id in ipairs(PlayerManager.GetAliveIDs()) do
		if FAKE.players[id].kind == "CITY_STATE" then out[#out + 1] = FAKE.players[id] end
	end
	return out
end
function PlayerManager.GetFreeCitiesPlayerID() return FAKE.freeCitiesID end
function PlayerManager.GetAliveMajorsCount() return #PlayerManager.GetAliveMajors() end
function PlayerManager.IsValid(id) return FAKE.players[id] ~= nil end

-- One config object per player (the same object on every access).
local function NewConfig(id, p)
	return {
		GetCivilizationShortDescription = function() return p.civ end,
		GetCivilizationTypeName = function() return p.civType or ("CIVILIZATION_FAKE_" .. id) end,
		GetLeaderTypeName = function() return p.leaderType or ("LEADER_FAKE_" .. id) end,
		GetPlayerName = function() return p.name or ("Player " .. id) end,
		IsHuman = function() return p.human end,
		GetTeam = function() return p.configTeam end,
		SetTeam = function(_, team)
			FAKE.teamSets[#FAKE.teamSets + 1] = { pid = id, team = team, turn = FAKE.turn, context = FAKE.context }
			p.configTeam = team
			if FAKE.teamModel == "live" then
				p.team = team
			end
		end,
	}
end
PlayerConfigurations = setmetatable({}, {
	__index = function(_, id)
		local p = FAKE.players[id]
		if p == nil then return nil end
		FAKE.configs[id] = FAKE.configs[id] or NewConfig(id, p)
		return FAKE.configs[id]
	end,
})

-- ---------------------------------------------------------------------------
-- Notifications and text
-- ---------------------------------------------------------------------------
NotificationManager = {}
function NotificationManager.SendNotification(pid, hash, data)
	local row = GameInfo.Types and GameInfo.Types[hash]
	if row == nil then
		error("SendNotification: unknown notification type hash " .. tostring(hash))
	end
	local n = { pid = pid, typeName = row.Type, hash = hash, data = DeepCopy(data or {}), id = FAKE.nextNotifID, turn = FAKE.turn }
	FAKE.nextNotifID = FAKE.nextNotifID + 1
	FAKE.notifications[#FAKE.notifications + 1] = n
	return n.id
end
function NotificationManager.GetList(pid)
	local out = {}
	for _, n in ipairs(FAKE.notifications) do
		if n.pid == pid and not n.dismissed then out[#out + 1] = n.id end
	end
	return out
end
function NotificationManager.Find(pid, id)
	for _, n in ipairs(FAKE.notifications) do
		if n.pid == pid and n.id == id and not n.dismissed then
			return {
				GetType = function() return n.hash end,
				GetValue = function(_, k) return n.data[k] end,
				GetMessage = function() return n.data[ParameterTypes.MESSAGE] end,
				GetSummary = function() return n.data[ParameterTypes.SUMMARY] end,
				GetID = function() return n.id end,
			}
		end
	end
	return nil
end
function NotificationManager.Dismiss(pid, id)
	for _, n in ipairs(FAKE.notifications) do
		if n.pid == pid and n.id == id then n.dismissed = true end
	end
end

Locale = {}
-- Renders "{n_Name}" and the Civ VI plural form "{n_Name : plural 1?one; other?many;}".
-- Text audit: a mod key (LOC_TX_*) whose placeholder {n_...} gets no argument
-- n is recorded in FAKE.handlerErrors, which fails the running test.
FAKE.textArgErrors = {}
FAKE.modKeyPrefix = "LOC_TX_"
local function PluralForm(spec, v)
	local num = tonumber(v)
	local forms, other = {}, nil
	for sel, word in string.gmatch(spec, "([%w]+)%?([^;]*);") do
		forms[sel] = word
		if sel == "other" then other = word end
	end
	if num ~= nil and forms[tostring(num)] ~= nil then return forms[tostring(num)] end
	return other or ""
end
function Locale.Lookup(key, ...)
	if key == nil then return "" end
	local text = (FAKE_TEXT ~= nil and FAKE_TEXT[key]) or nil
	local n = select("#", ...)
	if text == nil then
		if n == 0 then return tostring(key) end
		local parts = {}
		for i = 1, n do parts[i] = tostring((select(i, ...))) end
		return tostring(key) .. "(" .. table.concat(parts, ",") .. ")"
	end
	local args = { ... }
	local prefix = FAKE.modKeyPrefix
	text = string.gsub(text, "{(%d+)_([^}]*)}", function(num, rest)
		local v = args[tonumber(num)]
		if v == nil then
			if string.sub(tostring(key), 1, string.len(prefix)) == prefix
					or string.find(tostring(key), "_TX_", 1, true) ~= nil then
				local msg = "text-args: " .. tostring(key) .. " uses {" .. num .. "_...} but got " .. n .. " argument(s)"
				FAKE.textArgErrors[#FAKE.textArgErrors + 1] = msg
				FAKE.handlerErrors[#FAKE.handlerErrors + 1] = msg
			end
			return "{" .. num .. "}"
		end
		local spec = string.match(rest, "^[^:]*:%s*plural%s+(.*)$")
		if spec ~= nil then return PluralForm(spec, v) end
		return tostring(v)
	end)
	return text
end
function Locale.ToUpper(s) return string.upper(tostring(s)) end
function Locale.Compare(a, b) if a < b then return -1 elseif a > b then return 1 end return 0 end

-- Sets or replaces a text for this test (FAKE_TEXT holds the mod's en_US rows).
function FAKE.SetText(key, text)
	FAKE_TEXT = FAKE_TEXT or {}
	FAKE_TEXT[key] = text
end

-- ---------------------------------------------------------------------------
-- include(name): runs a file of TX/, TX_Dev/ or tests/offline/lib found by
-- file name (the runner builds the index). Like the engine, include re-runs
-- the file every time; load-once guards in the mod make that safe.
-- ---------------------------------------------------------------------------
FAKE.includes = {}
function include(name)
	local rel = __py_find(name)
	if rel == nil then
		print("[FAKE] include: file not found: " .. tostring(name))
		return
	end
	FAKE.includes[#FAKE.includes + 1] = rel
	local src = __py_read(rel)
	local fn, err = loadstring(src, "@" .. rel)
	if fn == nil then
		error("include(" .. tostring(name) .. ") syntax error: " .. tostring(err), 2)
	end
	fn()
end

-- Runs a project file by path (relative to the repo root) and returns its result.
function FAKE.dofile(rel)
	local src = __py_read(rel)
	if src == nil then
		error("FAKE.dofile: not found " .. tostring(rel), 2)
	end
	local fn, err = loadstring(src, "@" .. rel)
	if fn == nil then
		error("FAKE.dofile(" .. rel .. ") syntax error: " .. tostring(err), 2)
	end
	return fn()
end
