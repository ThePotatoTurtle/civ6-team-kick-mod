-- ===========================================================================
-- TX_UIShared.lua  (Team Kick 0.1.0)
-- TX:CONTEXT UI
--
-- UI module (PLAN II.10): include("TX_UIShared") from every TX UI context
-- (modinfo ImportFiles TX_Imports). Functions on the global table TX_UI.
-- Read-only: the UI reads Game properties and the engine, and changes game
-- state only through flat EXECUTE_SCRIPT requests (TX_UI.Request; PB 3).
-- Gameplay re-validates every request (TP 2.5); the TX_Votes calls the UI
-- makes only drive the display.
--
--   TX_UI.Local()             Game.GetLocalPlayer() in pcall, -1 on error.
--                             Every view calls it at the moment of use
--                             (hotseat hand-off).
--   TX_UI.ReadStore()         TX_Store.Load(), cached on (TX_Rev, turn)
--                             (EFV/UI/EFV_UIShared.lua:156-180).
--   TX_UI.World()             slots 0..63; team = the config team (what
--                             gameplay reads, PLAN II.0 F1, F2), else
--                             Players[i]:GetTeam(); alive / major / human
--                             from Players[i] (as TX_Gameplay.lua World()).
--   TX_UI.LiveTeam(pid)       UI Players[pid]:GetTeam(): stale until a load
--                             (F3); only for reload detection (chunk D).
--   TX_UI.Label(pid)          LOC_TX_PLAYER_LABEL {leader, civ}.
--   TX_UI.ModeShort(rec)      the record's kick mode in short words
--                             (LOC_TX_MODE_<mode>_SHORT; old records SOFT).
--   TX_UI.ModeLine(mode)      LOC_TX_MODE_LINE {LOC_TX_MODE_<mode>, _INFO}.
--   TX_UI.PortraitIcon(pid)   "ICON_" .. GetLeaderTypeName() (DiplomacyRibbon.lua:219).
--   TX_UI.Request(onStart, params)  EFV_UIShared.lua:576-610.
--   TX_UI.ReasonText(codes)   LOC_TX_REASON_<code> lines.
--   TX_UI.IsHost(), TX_UI.NetMP(), TX_UI.Hotseat()   Network.IsGameHost(),
--                             GameConfiguration.IsNetworkMultiplayer(),
--                             GameConfiguration.IsHotseat() in pcall.
--   TX_UI.Hash(typeName)      GameInfo.Types[typeName].Hash.
--   TX_UI.Sweep(localID, typeName, keep)  EFV SweepStale (EFV_Tracker.lua:564-622).
--   TX_UI.TryProbe(label, fn) logged pcall wrapper for PROBE calls.
--   TX_UI.ActivatedRecord(pid, nid, typeName)  the Events.NotificationActivated
--                             read (PROBE for a custom type, Appendix B).
--
-- Engine calls (PLAN Appendix B, all UI): Game.GetLocalPlayer (C, EFV U02),
-- Game:GetProperty via TX_Store (C), Players[i] :GetTeam / IsAlive / IsMajor /
-- IsHuman (C, EFV A42), PlayerConfigurations[i] :GetTeam (C, LOG:956-960),
-- :GetLeaderName (VERIFIED-BY-SOURCE, BASE24 DiplomacyActionView.lua:647),
-- :GetCivilizationShortDescription (C, EFV A62), :GetLeaderTypeName (C),
-- Locale.Lookup (C), GameInfo.Types (C), NotificationManager.GetList / Find /
-- Dismiss, :GetType / :GetValue (C, EFV U15, T21: Dismiss is deferred),
-- UI.RequestPlayerOperation with PlayerOperations.EXECUTE_SCRIPT (C, EFV U01),
-- Network.IsGameHost (C, LOG:1136), GameConfiguration.IsNetworkMultiplayer (C),
-- GameConfiguration.IsHotseat (C, TX_Dev UI snapshots, Session 3b hotseat=1).
-- MP: the UI never writes state; no pairs() (TX_Util.SortedKeys only).
-- ===========================================================================

if TX_UI ~= nil and TX_UI.LOADED == 1 then
	return
end

include("TX_Config")
include("TX_Util")
include("TX_Store")
include("TX_Votes")

TX_UI = {}

local LOG_TAG = "UIShared"
local LOG_TAG_REQ = "UIRequest"     -- EFV_UIShared.lua LOG_TAG_REQ

local Str = TX_Util.Str

local m_Cache = nil                 -- { rev, turn, store } of the last ReadStore
local m_ProbeSeen = {}              -- probe label|outcome already logged at level 2

local function Log(level, tag, fmt, ...)
	TX_Util.Log(level, tag, fmt, ...)
end

-- ---------------------------------------------------------------------------
-- TX_UI.L(key, ...) -> text
-- Locale.Lookup in pcall; the key itself when the lookup fails
-- (EFV_Tracker.lua:118-126).
-- ---------------------------------------------------------------------------
function TX_UI.L(key, ...)
	local args = { ... }
	local n = select("#", ...)
	local ok, s = pcall(function() return Locale.Lookup(key, unpack(args, 1, n)) end)
	if ok and type(s) == "string" then
		return s
	end
	return tostring(key)
end

-- ---------------------------------------------------------------------------
-- TX_UI.Local() -> player ID, -1 when it cannot be read
-- EFV_Tracker.lua:102-108. Read at the moment of use, never cached
-- (hotseat: Events.LocalPlayerChanged hands the machine to another player).
-- ---------------------------------------------------------------------------
function TX_UI.Local()
	local ok, pid = pcall(function() return Game.GetLocalPlayer() end)
	if ok and type(pid) == "number" then
		return pid
	end
	return -1
end

function TX_UI.Turn()
	return TX_Util.Turn()
end

-- ---------------------------------------------------------------------------
-- TX_UI.TryProbe(label, fn) -> ok, value
-- Logged pcall for PROBE calls (PLAN Appendix B; same shape as
-- TX_Notify.TryProbe in gameplay): "PROBE <label> ok -> <type> <value>" or
-- "PROBE <label> FAILED: <err>" at level 2 the first time per label and
-- outcome in this Lua state, level 3 after that. Never an ERROR line: a failed
-- probe is a Session 4 finding and the caller falls back.
-- (Not named Probe / TX_Probe: api_audit skips the arguments of those.)
-- ---------------------------------------------------------------------------
function TX_UI.TryProbe(label, fn)
	local ok, v = pcall(fn)
	local outcome = ok and "ok" or "FAILED"
	local seenKey = tostring(label) .. "|" .. outcome
	local level = 2
	if m_ProbeSeen[seenKey] then
		level = 3
	end
	m_ProbeSeen[seenKey] = true
	if ok then
		Log(level, LOG_TAG, "PROBE %s ok -> %s %s", tostring(label), type(v), Str(v))
	else
		Log(level, LOG_TAG, "PROBE %s FAILED: %s", tostring(label), Str(v))
	end
	return ok, v
end

-- ---------------------------------------------------------------------------
-- Store
-- ---------------------------------------------------------------------------
-- TX_UI.Rev() -> TX_Rev (0 when missing)
function TX_UI.Rev()
	return TX_Store.Rev()
end

-- TX_UI.ReadStore() -> store (TX_Store.Normalize shape, never nil)
-- Cached while (TX_Rev, turn) is unchanged (EFV_UIShared.lua:156-180):
-- gameplay raises TX_Rev on every commit. The UI never changes the table.
function TX_UI.ReadStore()
	local rev = TX_Store.Rev()
	local turn = TX_Util.Turn()
	if m_Cache ~= nil and m_Cache.rev == rev and m_Cache.turn == turn then
		return m_Cache.store
	end
	local store = TX_Store.Load()
	m_Cache = { rev = rev, turn = turn, store = store }
	Log(3, LOG_TAG, "store read rev=%d records=%d", rev, #(store.ids or {}))
	return store
end

-- ---------------------------------------------------------------------------
-- World (PLAN II.10)
-- ---------------------------------------------------------------------------
local function Flag(fn)
	local ok, v = pcall(fn)
	if ok and v == true then
		return 1
	end
	return 0
end

-- TX_UI.World() -> TX_Votes world
-- Every existing slot 0..63, ascending. The team is the config team
-- (PlayerConfigurations[i]:GetTeam(), the value gameplay reads right after
-- the host's write, F1, F2); the UI's Players[i]:GetTeam() stays old until a
-- load (F3) and is only the fallback. Same shape as TX_Gameplay.lua World().
function TX_UI.World()
	local slots = {}
	for i = 0, 63 do
		local okP, p = pcall(function() return Players[i] end)
		if okP and p ~= nil then
			local team = -1
			local okC, ct = pcall(function()
				local cfg = PlayerConfigurations[i]
				if cfg == nil then
					return nil
				end
				return cfg:GetTeam()
			end)
			if okC and type(ct) == "number" then
				team = ct
			else
				local okT, t = pcall(function() return p:GetTeam() end)
				if okT and type(t) == "number" then
					team = t
				end
			end
			slots[#slots + 1] = {
				pid = i,
				team = team,
				alive = Flag(function() return p:IsAlive() end),
				major = Flag(function() return p:IsMajor() end),
				human = Flag(function() return p:IsHuman() end),
			}
		end
	end
	return TX_Votes.MakeWorld(TX_Util.Turn(), slots)
end

-- TX_UI.LiveTeam(pid) -> the UI's Players[pid]:GetTeam(), or nil
-- Stale until a load (F3); used only to detect a reload (PLAN II.8, II.11c).
function TX_UI.LiveTeam(pid)
	local ok, t = pcall(function() return Players[pid]:GetTeam() end)
	if ok and type(t) == "number" then
		return t
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Names and portraits
-- ---------------------------------------------------------------------------
-- TX_UI.Label(pid) -> "Leader (Civ)", LOC_TX_PLAYER_GENERIC when unknown
-- PlayerConfigurations[pid]:GetLeaderName() (BASE24 DiplomacyActionView.lua:647)
-- and :GetCivilizationShortDescription() (EFV A62), both under pcall.
-- Teammates have always met, so there is no unmet label in the UI.
function TX_UI.Label(pid)
	if type(pid) ~= "number" or pid < 0 then
		return TX_UI.L("LOC_TX_PLAYER_GENERIC")
	end
	local ok, leader, civ = pcall(function()
		local cfg = PlayerConfigurations[pid]
		return cfg:GetLeaderName(), cfg:GetCivilizationShortDescription()
	end)
	if ok and type(leader) == "string" and leader ~= "" and type(civ) == "string" and civ ~= "" then
		return TX_UI.L("LOC_TX_PLAYER_LABEL", TX_UI.L(leader), TX_UI.L(civ))
	end
	return TX_UI.L("LOC_TX_PLAYER_GENERIC")
end

-- TX_UI.ModeShort(rec) -> "soft kick" / "hard kick" (LOC_TX_MODE_<mode>_SHORT)
function TX_UI.ModeShort(rec)
	return TX_UI.L("LOC_TX_MODE_" .. TX_Votes.RecMode(rec) .. "_SHORT")
end

-- TX_UI.ModeLine(mode) -> "<mode name>: <one-line explanation>" (LOC_TX_MODE_LINE)
function TX_UI.ModeLine(mode)
	return TX_UI.L("LOC_TX_MODE_LINE", TX_UI.L("LOC_TX_MODE_" .. mode), TX_UI.L("LOC_TX_MODE_" .. mode .. "_INFO"))
end

-- TX_UI.PortraitIcon(pid) -> "ICON_<LEADER_TYPE>" or nil
-- For Image:SetIcon on a Leaders45 image (BASE24 DiplomacyRibbon.lua:219,
-- Instances/LeaderIcon.lua:59).
function TX_UI.PortraitIcon(pid)
	local ok, t = pcall(function() return PlayerConfigurations[pid]:GetLeaderTypeName() end)
	if ok and type(t) == "string" and t ~= "" then
		return "ICON_" .. t
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- TX_UI.ReasonText(codes) -> "LOC_TX_REASON_<code>" lines joined by [NEWLINE]
-- Each code once, in the given order (TX_Votes returns them in the PLAN II.6
-- order). "" for no codes.
-- ---------------------------------------------------------------------------
function TX_UI.ReasonText(codes)
	local lines, seen = {}, {}
	for _, code in ipairs(codes or {}) do
		local c = tostring(code)
		if not seen[c] then
			seen[c] = true
			lines[#lines + 1] = TX_UI.L("LOC_TX_REASON_" .. c)
		end
	end
	return table.concat(lines, "[NEWLINE]")
end

-- ---------------------------------------------------------------------------
-- TX_UI.Request(onStart, params) -> true when handed to the engine
-- EFV_UIShared.lua:576-610: flat params (numbers and strings; booleans as
-- 0/1; anything else dropped with an ERROR line), logged, then
-- UI.RequestPlayerOperation(local, PlayerOperations.EXECUTE_SCRIPT, params)
-- (PB 3; Appendix B row 1). Arrives as GameEvents[onStart](playerID, params)
-- on every machine; gameplay re-validates it.
-- ---------------------------------------------------------------------------
function TX_UI.Request(onStart, params)
	local localID = TX_UI.Local()
	if localID < 0 then
		Log(1, LOG_TAG_REQ, "%s not sent: no local player", Str(onStart))
		return false
	end
	params = params or {}
	local flat = {}
	local logParts = {}
	for _, k in ipairs(TX_Util.SortedKeys(params)) do
		local v = params[k]
		local tv = type(v)
		if tv == "boolean" then
			v = v and 1 or 0
			tv = "number"
		end
		if type(k) == "string" and k ~= "OnStart" and (tv == "number" or tv == "string") then
			flat[k] = v
			logParts[#logParts + 1] = k .. "=" .. tostring(v)
		elseif k ~= "OnStart" then
			Log(1, LOG_TAG_REQ, "%s dropped non-flat param %s (%s)", Str(onStart), tostring(k), tv)
		end
	end
	flat.OnStart = onStart
	Log(2, LOG_TAG_REQ, "%s from P%d %s", Str(onStart), localID, table.concat(logParts, " "))
	local ok, err = pcall(function()
		UI.RequestPlayerOperation(localID, PlayerOperations.EXECUTE_SCRIPT, flat)
	end)
	if not ok then
		Log(1, LOG_TAG_REQ, "%s RequestPlayerOperation failed: %s", Str(onStart), Str(err))
	end
	return ok
end

-- ---------------------------------------------------------------------------
-- Host and network flags (apply seam, chunk D)
-- ---------------------------------------------------------------------------
function TX_UI.IsHost()
	local ok, v = pcall(function() return Network.IsGameHost() end)
	return ok and v == true
end

function TX_UI.NetMP()
	local ok, v = pcall(function() return GameConfiguration.IsNetworkMultiplayer() end)
	return ok and v == true
end

-- GameConfiguration.IsHotseat() in pcall (the kick save dialog's wording).
function TX_UI.Hotseat()
	local ok, v = pcall(function() return GameConfiguration.IsHotseat() end)
	return ok and v == true
end

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------
-- TX_UI.Hash(typeName) -> GameInfo.Types[typeName].Hash or nil (EFV U16, A51)
function TX_UI.Hash(typeName)
	local ok, h = pcall(function()
		local row = GameInfo.Types[typeName]
		if row == nil then
			return nil
		end
		return row.Hash
	end)
	if ok then
		return h
	end
	return nil
end

-- Type hash of notification nid of pid, or nil.
local function NotificationType(pid, nid)
	local ok, t = pcall(function()
		local p = NotificationManager.Find(pid, nid)
		if p == nil then
			return nil
		end
		return p:GetType()
	end)
	if ok then
		return t
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- TX_UI.ActivatedRecord(pid, nid, typeName) -> matched, recordID
-- For Events.NotificationActivated(pid, nid, byUser): matched is true when
-- notification nid of pid is of typeName (NotificationManager.Find(pid, nid):
-- GetType() == its hash; XP2-20 GovernorPanel.lua:414-426,
-- HistoricMoments.lua:136-150). recordID is its TX_RecordID value
-- (:GetValue, EFV_Tracker.lua:594), or nil. That the event reaches a mod
-- context for a custom type on the default handler is a PROBE (Appendix B;
-- R C, NotificationPanel.lua:1102-1108): the read runs through TryProbe, so
-- Lua.log shows "PROBE UI NotificationActivated <type> ok" once it worked.
-- ---------------------------------------------------------------------------
function TX_UI.ActivatedRecord(pid, nid, typeName)
	local want = TX_UI.Hash(typeName)
	if want == nil or NotificationType(pid, nid) ~= want then
		return false, nil
	end
	local ok, rid = TX_UI.TryProbe("UI NotificationActivated " .. tostring(typeName), function()
		return NotificationManager.Find(pid, nid):GetValue(TX_Config.NKEY_RECORD)
	end)
	if ok and type(rid) == "number" then
		return true, rid
	end
	return true, nil
end

-- ---------------------------------------------------------------------------
-- TX_UI.Sweep(localID, typeName, keep) -> number of Dismiss calls
-- EFV SweepStale (EFV_Tracker.lua:564-622): reads the local player's
-- notifications and looks only at those of typeName that carry a numeric
-- TX_RecordID (every other notification is never touched). Per record, the
-- newest copy (highest TX_Turn, then highest ID) stays while keep(rec) is
-- true; every other copy, and every copy of a record that is gone, is
-- dismissed. UI NotificationManager.Dismiss is deferred (EFV T21): never
-- re-checked in the same call. ExpiresEndOfTurn 0 plus a re-send each turn
-- (PLAN II.7) leaves one copy per turn without this.
-- ---------------------------------------------------------------------------
function TX_UI.Sweep(localID, typeName, keep)
	if type(localID) ~= "number" or localID < 0 then
		return 0
	end
	local want = TX_UI.Hash(typeName)
	if want == nil then
		return 0
	end
	local okList, list = pcall(function() return NotificationManager.GetList(localID) end)
	if not okList or type(list) ~= "table" then
		return 0
	end
	local store = TX_UI.ReadStore()
	local entries, newest = {}, {}
	for _, nid in ipairs(list) do
		pcall(function()
			local p = NotificationManager.Find(localID, nid)
			if p == nil or p:GetType() ~= want then
				return
			end
			local rid = p:GetValue(TX_Config.NKEY_RECORD)
			if type(rid) ~= "number" then
				return
			end
			local e = { nid = nid, rid = rid, turn = tonumber(p:GetValue(TX_Config.NKEY_TURN)) or -1 }
			entries[#entries + 1] = e
			local best = newest[rid]
			if best == nil or e.turn > best.turn or (e.turn == best.turn and e.nid > best.nid) then
				newest[rid] = e
			end
		end)
	end
	local dismissed = 0
	for _, e in ipairs(entries) do
		local rec = TX_Store.Get(store, e.rid)
		local alive = false
		if rec ~= nil then
			local okK, k = pcall(keep, rec)
			alive = okK and k == true
		end
		if not (alive and newest[e.rid] == e) then
			local ok = pcall(function() NotificationManager.Dismiss(localID, e.nid) end)
			if ok then
				dismissed = dismissed + 1
			end
			Log(3, LOG_TAG, "dismiss %s id=%s rec=%d turn=%d live=%s", Str(typeName), Str(e.nid), e.rid, e.turn,
				tostring(alive))
		end
	end
	return dismissed
end

TX_UI.LOADED = 1
