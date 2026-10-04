-- ===========================================================================
-- TX_Notify.lua  (Team Expulsion 0.1.0)
-- TX:CONTEXT G
--
-- Gameplay only: include("TX_Notify") from TX_Gameplay.lua. The notification
-- queue, its flush, the player labels and the four TX notifications
-- (PLAN II.7, II.13).
--
-- Queue and flush exactly as EFV_Notify (EFV/Scripts/EFV_Notify.lua):
--   * human recipients only (:85-97; IsHuman is synchronised, so the skip is
--     the same on every machine);
--   * a same-batch duplicate (same pid, type and record) replaces the queued
--     entry in place (:128-143, :204-235);
--   * the flush detaches the queue first, sends each entry in its own pcall,
--     looks the text up in gameplay at send time from LOC_<type>_MESSAGE /
--     _SUMMARY, sets AlwaysUnique and the custom keys TX_RecordID / TX_Turn
--     (:157-183, :315-337; read back in the UI with GetValue,
--     EFV_Tracker.lua:594);
--   * handlers commit the store first, then flush (EFV order).
--
-- Labels (PLAN II.7): LOC_TX_PLAYER_LABEL with the leader name and the civ
-- short description of PlayerConfigurations[pid]. Both config reads are PROBE
-- in gameplay (PLAN Appendix B: they exist in G, S1 G dump LOG:903-904; EFV
-- calls GetCivilizationShortDescription in G under pcall, EFV_Util.lua:522-536),
-- so they go through TX_Notify.TryProbe (pcall, logged) with the fallback
-- LOC_TX_PLAYER_GENERIC. LOC_TX_PLAYER_UNMET when the recipient has not met
-- the player (GetDiplomacy():HasMet, G verified, EFV A41; EFV_Rules.lua:171-177).
--
-- Who gets what (PLAN II.7 table):
--   VOTE_REQUIRED   each PENDING human voter, never the proposer or the target
--   KICK_PASSED     every living human major, all teams (TP 2.1)
--   KICK_DONE       every living human major
--   REQUEST_FAILED  the sender of a refused request
-- FAILED, EXPIRED and CANCELLED send nothing (DEC 2, TP 2.1).
--
-- MP: no pairs(), no RNG, no Game.GetLocalPlayer. Recipients come from the
-- world snapshot (ascending pids) or from the record (ascending voters).
-- Engine calls: Players[i]:IsHuman / GetDiplomacy():HasMet (G:C),
-- PlayerConfigurations[i]:GetLeaderName / GetCivilizationShortDescription
-- (G PROBE), Locale.Lookup, GameInfo.Types, NotificationManager.SendNotification,
-- ParameterTypes.MESSAGE / SUMMARY (G:C).
-- ===========================================================================

if TX_Notify ~= nil and TX_Notify.LOADED == 1 then
	return
end

include("TX_Config")
include("TX_Util")
include("TX_Votes")

TX_Notify = {}

-- FIFO of queued entries (module memory, never stored; EFV_Notify.lua:69-70).
local m_Queue = {}

-- Probe labels already logged in this Lua state (log once per outcome).
local m_ProbeSeen = {}

local function Log(level, fmt, ...)
	TX_Util.Log(level, "Notify", fmt, ...)
end

-- ===========================================================================
-- PROBE wrapper
-- ===========================================================================
-- TX_Notify.TryProbe(label, fn) -> ok, value
-- Runs fn under pcall. PROBE calls of PLAN Appendix B go through here, so the
-- in-game log names each one with its outcome (existence: "attempt to call
-- method ... (a nil value)" is the error of a missing method; the return
-- value's type and text when it worked). Logged once per label and outcome
-- in a Lua state at level 2 ("PROBE <label> ok|FAILED ..."), later repeats at
-- level 3, so a re-send every turn does not flood Lua.log. A failure is a
-- finding for Session 4, not a mod error: no ERROR line, the caller falls back.
-- Not named Probe / TX_Probe on purpose: the API audit skips the argument
-- list of those (tools/api_audit.py PROBE_FUNCS), and this one should stay
-- audited.
-- ---------------------------------------------------------------------------
function TX_Notify.TryProbe(label, fn)
	local ok, v = pcall(fn)
	local outcome
	if ok then
		outcome = "ok"
	else
		outcome = "FAILED"
	end
	local seenKey = tostring(label) .. "|" .. outcome
	local level = 2
	if m_ProbeSeen[seenKey] then
		level = 3
	end
	m_ProbeSeen[seenKey] = true
	if ok then
		Log(level, "PROBE %s ok -> %s %s", tostring(label), type(v), TX_Util.Str(v))
	else
		Log(level, "PROBE %s FAILED: %s", tostring(label), TX_Util.Str(v))
	end
	return ok, v
end

-- ===========================================================================
-- Recipients and labels
-- ===========================================================================
-- true if pid is a human player (EFV_Notify.lua:85-97). Any error -> false.
local function IsHumanPlayer(pid)
	if type(pid) ~= "number" or pid < 0 then
		return false
	end
	local ok, human = pcall(function()
		local p = Players[pid]
		if p == nil then
			return false
		end
		return p:IsHuman() == true
	end)
	return ok and human == true
end

-- viewer has met pid (EFV_Rules.lua:171-177; G:C, EFV A41). Any error -> false.
local function HasMet(viewerID, pid)
	local ok, met = pcall(function()
		return Players[viewerID]:GetDiplomacy():HasMet(pid)
	end)
	return ok and met == true
end

local function Text(key, ...)
	local args = { ... }
	local n = select("#", ...)
	local ok, s = pcall(function()
		return Locale.Lookup(key, unpack(args, 1, n))
	end)
	if ok and type(s) == "string" then
		return s
	end
	Log(1, "Locale.Lookup(%s) failed: %s", tostring(key), TX_Util.Str(s))
	return tostring(key)
end

-- A config text key read through the probe; nil unless a non-empty string.
local function ConfigKey(pid, method)
	local ok, v = TX_Notify.TryProbe("G PlayerConfigurations:" .. method, function()
		local cfg = PlayerConfigurations[pid]
		if method == "GetLeaderName" then
			return cfg:GetLeaderName()
		end
		return cfg:GetCivilizationShortDescription()
	end)
	if ok and type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- TX_Notify.Label(pid, viewerID) -> localized label of pid as viewerID sees it
-- LOC_TX_PLAYER_UNMET when viewerID (given and not pid) has not met pid;
-- LOC_TX_PLAYER_LABEL(leader, civ) when both config reads work; else
-- LOC_TX_PLAYER_GENERIC (PLAN II.7). Never nil or "".
-- ---------------------------------------------------------------------------
function TX_Notify.Label(pid, viewerID)
	if type(pid) ~= "number" then
		return Text("LOC_TX_PLAYER_GENERIC")
	end
	if type(viewerID) == "number" and viewerID ~= pid and not HasMet(viewerID, pid) then
		return Text("LOC_TX_PLAYER_UNMET")
	end
	local leader = ConfigKey(pid, "GetLeaderName")
	local civ = ConfigKey(pid, "GetCivilizationShortDescription")
	if leader ~= nil and civ ~= nil then
		local s = Text("LOC_TX_PLAYER_LABEL", Text(leader), Text(civ))
		if s ~= "" then
			return s
		end
	end
	return Text("LOC_TX_PLAYER_GENERIC")
end

-- TX_Notify.LivingHumans(world) -> ascending pids of the living human majors
-- (KICK_PASSED and KICK_DONE go to all of them, every team; TP 2.1).
function TX_Notify.LivingHumans(world)
	local out = {}
	for _, s in ipairs(world.slots) do
		if s.alive == 1 and s.major == 1 and s.human == 1 then
			out[#out + 1] = s.pid
		end
	end
	return out
end

-- ===========================================================================
-- Queue
-- ===========================================================================
local function CopyArgs(args)
	local out = {}
	for i, a in ipairs(args or {}) do
		out[i] = a
	end
	return out
end

-- Index of a queued entry this one replaces (same pid, type and record), or
-- nil. Only entries tied to a record are coalesced (EFV_Notify.lua:128-143).
local function FindDuplicate(entry)
	if entry.recordID == nil then
		return nil
	end
	for i, q in ipairs(m_Queue) do
		if q.pid == entry.pid and q.typeName == entry.typeName and q.recordID == entry.recordID then
			return i
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- TX_Notify.Queue(pid, typeName, args, recordID)
-- Skips non-human players. args: a dense list of already localized strings
-- and numbers, in placeholder order (the same for _MESSAGE and _SUMMARY).
-- recordID (optional) goes to data.TX_RecordID. EFV_Notify.lua:204-235.
-- ---------------------------------------------------------------------------
function TX_Notify.Queue(pid, typeName, args, recordID)
	if type(typeName) ~= "string" then
		Log(1, "queue: bad typeName %s for pid=%s", TX_Util.Str(typeName), TX_Util.Str(pid))
		return
	end
	if not IsHumanPlayer(pid) then
		Log(3, "skip pid=%s type=%s (not a human player)", TX_Util.Str(pid), typeName)
		return
	end
	local entry = {
		pid = pid,
		typeName = typeName,
		args = CopyArgs(args),
		recordID = recordID,
		turn = TX_Util.Turn(),
	}
	local dup = FindDuplicate(entry)
	if dup ~= nil then
		m_Queue[dup] = entry
		Log(3, "replaced queued pid=%d type=%s rec=%s", pid, typeName, TX_Util.Str(recordID))
	else
		m_Queue[#m_Queue + 1] = entry
		Log(3, "queued pid=%d type=%s rec=%s", pid, typeName, TX_Util.Str(recordID))
	end
end

-- ---------------------------------------------------------------------------
-- The four notifications (PLAN II.7)
-- ---------------------------------------------------------------------------
-- VOTE_REQUIRED to one voter: { proposer, target, turns left }. Refuses the
-- proposer, the target and anybody who is not a PENDING voter of the record.
function TX_Notify.VoteRequired(rec, pid, turn)
	if pid == rec.targetID or pid == rec.proposerID then
		Log(1, "vote_required: refused P%s for rec=%s (proposer or target)", TX_Util.Str(pid), TX_Util.Str(rec.id))
		return
	end
	local e = TX_Votes.VoterEntry(rec, pid)
	if e == nil or e.v ~= TX_Config.V.PENDING then
		return
	end
	TX_Notify.Queue(pid, TX_Config.NOTIF.VOTE_REQUIRED, {
		TX_Notify.Label(rec.proposerID, pid),
		TX_Notify.Label(rec.targetID, pid),
		TX_Votes.TurnsLeft(rec, turn),
	}, rec.id)
end

-- VOTE_REQUIRED to every PENDING voter of the record (at Propose).
function TX_Notify.VoteRequiredAll(rec, turn)
	for _, e in ipairs(rec.voters) do
		if e.v == TX_Config.V.PENDING then
			TX_Notify.VoteRequired(rec, e.pid, turn)
		end
	end
end

local function ToLivingHumans(rec, world, typeName)
	for _, pid in ipairs(TX_Notify.LivingHumans(world)) do
		TX_Notify.Queue(pid, typeName, { TX_Notify.Label(rec.targetID, pid) }, rec.id)
	end
end

-- KICK_PASSED to every living human major: { target }.
function TX_Notify.KickPassed(rec, world)
	ToLivingHumans(rec, world, TX_Config.NOTIF.KICK_PASSED)
end

-- KICK_DONE to every living human major: { target }.
function TX_Notify.KickDone(rec, world)
	ToLivingHumans(rec, world, TX_Config.NOTIF.KICK_DONE)
end

-- REQUEST_FAILED to the sender: { LOC_TX_REASON_<code> }. recordID optional.
function TX_Notify.RequestFailed(pid, code, recordID)
	TX_Notify.Queue(pid, TX_Config.NOTIF.REQUEST_FAILED, {
		Text("LOC_TX_REASON_" .. tostring(code)),
	}, recordID)
end

-- ===========================================================================
-- Flush
-- ===========================================================================
-- Sends one entry; returns true on success. Errors are caught by Flush.
-- EFV_Notify.lua:157-183.
local function SendEntry(entry)
	local typeRow = GameInfo.Types[entry.typeName]
	if typeRow == nil or typeRow.Hash == nil then
		Log(1, "unknown notification type %s (missing Types row); pid=%d not notified", entry.typeName, entry.pid)
		return false
	end
	local n = #entry.args
	local data = {}
	data[ParameterTypes.MESSAGE] = Text("LOC_" .. entry.typeName .. "_MESSAGE", unpack(entry.args, 1, n))
	data[ParameterTypes.SUMMARY] = Text("LOC_" .. entry.typeName .. "_SUMMARY", unpack(entry.args, 1, n))
	data.AlwaysUnique = true
	data[TX_Config.NKEY_TURN] = entry.turn
	if type(entry.recordID) == "number" then
		data[TX_Config.NKEY_RECORD] = entry.recordID
	end
	NotificationManager.SendNotification(entry.pid, typeRow.Hash, data)
	return true
end

-- ---------------------------------------------------------------------------
-- TX_Notify.Flush()
-- Detaches the queue (so it is empty even after an error), then sends every
-- entry in queue order, each in its own pcall. Last step of every handler,
-- after TX_Store.Commit. EFV_Notify.lua:315-337.
-- ---------------------------------------------------------------------------
function TX_Notify.Flush()
	local queue = m_Queue
	m_Queue = {}
	if #queue == 0 then
		return
	end
	local sent, failed = 0, 0
	for _, entry in ipairs(queue) do
		local ok, res = pcall(SendEntry, entry)
		if ok and res then
			sent = sent + 1
			Log(2, "sent pid=%d type=%s rec=%s", entry.pid, entry.typeName, TX_Util.Str(entry.recordID))
		else
			failed = failed + 1
			if not ok then
				Log(1, "send failed pid=%d type=%s: %s", entry.pid, entry.typeName, TX_Util.Str(res))
			end
		end
	end
	Log(3, "flush sent=%d failed=%d", sent, failed)
end

-- TX_Notify.Discard(): drops the queue without sending (a handler whose
-- commit failed must not announce a change that was not saved).
function TX_Notify.Discard()
	if #m_Queue > 0 then
		Log(2, "discarded %d queued notification(s)", #m_Queue)
	end
	m_Queue = {}
end

-- TX_Notify.Count() -> queued entries (tests, diagnostics).
function TX_Notify.Count()
	return #m_Queue
end

TX_Notify.LOADED = 1
