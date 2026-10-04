-- ===========================================================================
-- TX_Gameplay.lua  (Team Kick 0.1.0)
-- TX:CONTEXT G
--
-- Gameplay entry point (modinfo AddGameplayScripts TX_Gameplay; PLAN II.8).
-- Runs on every new game and on every load. Not included by any other file,
-- so it has no load-once guard (EFV_Gameplay.lua:4-6).
--
-- Owns all TX state: every change happens inside a GameEvents handler
-- registered here, at file load, with literal GameEvents.X.Add calls and one
-- log line each (EFV_Gameplay.lua:346-387).
--   GameEvents.TX_Propose(playerID, { targetID, mode = "SOFT" | "HARD" })
--   GameEvents.TX_Vote(playerID, { recordID, vote = "YES" | "NO" })
--   GameEvents.TX_ApplyDone(playerID, { recordID, step = "WRITTEN" | "RELOADED" | "UNDONE", team, attempt })
--   GameEvents.TX_Victory(playerID, { team })
--   GameEvents.OnGameTurnStarted(turn): the turn pipeline
-- Requests come from the UI as UI.RequestPlayerOperation(local,
-- EXECUTE_SCRIPT, { OnStart = "TX_*", flat params }) (PB 3; EFV U01, A05;
-- TX_Dev_Gameplay.lua:1738-1772). The handler's playerID is the sender; every
-- request is re-validated here through TX_Votes (TP 2.5), the same functions
-- the UI uses only for display.
--
-- Every handler (EFV order): load the store, work, commit, then flush the
-- notifications; the whole body in a SafeCall (EFV_Gameplay.lua:71-81). The
-- store is never cached across handlers. A refused request stores nothing
-- (TX_Rev unchanged) and tells its sender with REQUEST_FAILED.
--
-- MP rules (PLAN II.2): slots 0..63 and records in ascending order; no
-- pairs() (TX_Util.SortedKeys only), no RNG, no Game.GetLocalPlayer, no
-- Events.* handler: only GameEvents.* are registered here.
-- Engine calls: Players[i] and :GetTeam / IsAlive / IsMajor / IsHuman (G:C,
-- EFV A42; TeamRows pattern TX_Dev_Gameplay.lua:164-175), the GameEvents
-- registrations (G:C), plus what the included modules call.
-- ===========================================================================

include("TX_Config")
include("TX_Util")
include("TX_Store")
include("TX_Votes")
include("TX_Notify")
include("TX_Apply")

local ST = TX_Config.ST
local Str = TX_Util.Str

local function Log(level, tag, fmt, ...)
	TX_Util.Log(level, tag, fmt, ...)
end

-- pcall wrapper: logs "<label> failed: <error>" as an ERROR under tag
-- (EFV_Gameplay.lua:71-81). Returns true when fn ran without error.
local function SafeCall(tag, label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		Log(1, tag, "%s failed: %s", tostring(label), Str(err))
	end
	return ok
end

-- ===========================================================================
-- World snapshot (PLAN II.6, II.8)
-- ===========================================================================
local function Flag(fn)
	local ok, v = pcall(fn)
	if ok and v == true then
		return 1
	end
	return 0
end

-- Every existing slot 0..63, ascending: { pid, team, alive, major, human }.
-- Gameplay reads Players[i]:GetTeam(), which gives the new team right after
-- the host's config write (PLAN II.0 F2). As TX_Dev_Gameplay.lua:164-175.
-- Built once per handler.
local function World()
	local slots = {}
	for i = 0, 63 do
		local okP, p = pcall(function() return Players[i] end)
		if okP and p ~= nil then
			local okT, team = pcall(function() return p:GetTeam() end)
			if not okT or type(team) ~= "number" then
				team = -1
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

-- ===========================================================================
-- Helpers
-- ===========================================================================
-- Flat params: numbers must be whole numbers, strings strings; anything else
-- reads as missing, so TX_Votes refuses it with its own reason.
local function Num(v)
	if type(v) == "number" and v == v and v == math.floor(v) then
		return v
	end
	return nil
end

local function Text(v)
	if type(v) == "string" then
		return v
	end
	return nil
end

local function Params(params)
	if type(params) == "table" then
		return params
	end
	return {}
end

local function Codes(codes)
	return table.concat(codes or {}, ",")
end

local function VotersText(rec)
	local parts = {}
	for _, e in ipairs(rec.voters or {}) do
		parts[#parts + 1] = "P" .. Str(e.pid) .. "=" .. Str(e.v)
	end
	return table.concat(parts, " ")
end

-- The store for this handler, or nil when it cannot be read (Commit would
-- refuse it anyway; nothing is announced for a change that cannot be saved).
local function LoadStore(tag, what)
	local store = TX_Store.Load()
	if store.broken == 1 then
		Log(1, tag, "%s: the store could not be read; nothing done", what)
		return nil
	end
	return store
end

-- Commit, then flush (EFV order). A failed commit drops the queued
-- notifications. Returns true when committed.
local function CommitAndFlush(tag, store)
	if TX_Store.Commit(store) then
		TX_Notify.Flush()
		return true
	end
	Log(1, tag, "commit failed; queued notifications dropped")
	TX_Notify.Discard()
	return false
end

-- A refused request: log, REQUEST_FAILED with the first reason to the sender
-- only, nothing stored (PLAN II.8).
local function Refuse(tag, what, playerID, codes, recordID)
	Log(2, tag, "refused %s from P%s: %s", what, Str(playerID), Codes(codes))
	TX_Notify.RequestFailed(playerID, codes[1], recordID)
	TX_Notify.Flush()
end

-- A record that just became PASSED: FinishPass (PENDING_APPLY with newTeamID,
-- or CANCELLED NO_FREE_TEAM), KICK_PASSED to every living human on a pass.
local function AfterPass(tag, store, world, rec)
	local state = TX_Votes.FinishPass(store, world, rec)
	if state == ST.PENDING_APPLY then
		Log(2, tag, "rec=%d PASSED: target=P%d newTeam=%d, waiting for the host to apply",
			rec.id, rec.targetID, rec.newTeamID)
		TX_Notify.KickPassed(rec, world)
	else
		Log(2, tag, "rec=%d PASSED but %s reason=%s", rec.id, Str(state), Str(rec.reason))
	end
end

-- ===========================================================================
-- GameEvents.TX_Propose(playerID, { targetID, mode })
-- mode: the kick mode the proposer picked (TX_Config.MODE); missing or
-- unknown (or HARD while HARD_KICK_ENABLED is false) is refused, BAD_MODE.
-- ===========================================================================
local function Propose(playerID, params)
	local p = Params(params)
	local targetID = Num(p.targetID)
	local mode = Text(p.mode)
	Log(2, "Votes", "propose from P%s target=%s mode=%s", Str(playerID), Str(p.targetID), Str(p.mode))
	local store = LoadStore("Votes", "propose")
	if store == nil then
		return
	end
	local world = World()
	local rec, codes = TX_Votes.Propose(store, world, playerID, targetID, mode)
	if rec == nil then
		Refuse("Votes", "propose", playerID, codes, nil)
		return
	end
	Log(2, "Votes", "rec=%d opened team=%d proposer=P%d target=P%d mode=%s voters=[%s] expires=T%d",
		rec.id, rec.teamID, rec.proposerID, rec.targetID, rec.mode, VotersText(rec), rec.expiresTurn)
	if rec.state == ST.PASSED then
		AfterPass("Votes", store, world, rec)
	else
		TX_Notify.VoteRequiredAll(rec, world.turn)
	end
	CommitAndFlush("Votes", store)
end

-- ===========================================================================
-- GameEvents.TX_Vote(playerID, { recordID, vote })
-- ===========================================================================
local function Vote(playerID, params)
	local p = Params(params)
	local recordID = Num(p.recordID)
	local vote = Text(p.vote)
	Log(2, "Votes", "vote from P%s rec=%s vote=%s", Str(playerID), Str(p.recordID), Str(p.vote))
	local store = LoadStore("Votes", "vote")
	if store == nil then
		return
	end
	local world = World()
	local rec, codes = TX_Votes.Vote(store, world, playerID, recordID, vote)
	if rec == nil then
		Refuse("Votes", "vote", playerID, codes, recordID)
		return
	end
	if rec.state == ST.PASSED then
		AfterPass("Votes", store, world, rec)
	elseif rec.state == ST.FAILED then
		-- No notification: only a passed kick is announced (DEC 2, TP 2.1).
		Log(2, "Votes", "rec=%d FAILED (%s by P%d)", rec.id, Str(rec.reason), playerID)
	else
		Log(2, "Votes", "rec=%d still open voters=[%s]", rec.id, VotersText(rec))
	end
	CommitAndFlush("Votes", store)
end

-- ===========================================================================
-- GameEvents.TX_ApplyDone(playerID, { recordID, step, team, attempt })
-- The apply seam, gameplay side (PLAN II.8, II.9). WRITTEN: the host's UI
-- wrote the config team; gameplay must read it at once (F2). RELOADED: a UI
-- saw the target's live team equal newTeamID, which it never does before a
-- load (F3); gameplay checks its own read again. UNDONE: the host's UI gave
-- up waiting and wrote the old team back; applied goes back to 0 so the
-- Apply button returns, and a WRITTEN of that attempt (or an older one)
-- that arrives later is refused (ATTEMPT_UNDONE, no REQUEST_FAILED: its
-- sender already knows). Only synced state decides.
-- ===========================================================================
local function ApplyDone(playerID, params)
	local p = Params(params)
	local recordID = Num(p.recordID)
	local step = Text(p.step)
	local team = Num(p.team)
	local attempt = Num(p.attempt)
	Log(2, "Apply", "%s from P%s rec=%s team=%s attempt=%s", Str(p.step), Str(playerID), Str(p.recordID), Str(p.team),
		Str(p.attempt))
	local store = LoadStore("Apply", "apply")
	if store == nil then
		return
	end
	local rec = TX_Store.Get(store, recordID)
	if step == TX_Config.STEP_RELOADED and rec ~= nil and rec.state == ST.DONE then
		-- Every UI reports after the load; the first one did the work.
		Log(3, "Apply", "RELOADED rec=%d from P%s: already DONE", rec.id, Str(playerID))
		return
	end
	local world = World()
	if rec ~= nil and team ~= nil and rec.newTeamID ~= nil and team ~= rec.newTeamID then
		Log(2, "Apply", "rec=%d: the UI reports team=%d, the record holds newTeam=%d", rec.id, team, rec.newTeamID)
	end
	local codes = TX_Votes.ApplyReasons(store, world, playerID, recordID, step, attempt)
	if codes[1] == "ATTEMPT_UNDONE" then
		Log(2, "Apply", "refused WRITTEN from P%s rec=%d attempt %s: ATTEMPT_UNDONE (undone up to attempt %d)",
			Str(playerID), rec.id, Str(attempt), rec.undoneAttempt)
		return
	end
	if #codes > 0 then
		-- The host's write did not take (the only reason left): an ERROR, the
		-- UI then undoes its write (PLAN II.11c step 6).
		if codes[1] == "NOT_SEEN" then
			Log(1, "Apply", "%s rec=%d: gameplay reads team=%d for P%d, not newTeam=%d (NOT_SEEN)",
				Str(step), rec.id, TX_Votes.TeamOf(world, rec.targetID), rec.targetID, rec.newTeamID)
		end
		Refuse("Apply", Str(step), playerID, codes, recordID)
		return
	end
	if step == TX_Config.STEP_UNDONE then
		local was = rec.applied
		if TX_Votes.MarkUndone(rec, attempt) then
			Log(2, "Apply", "rec=%d UNDONE attempt %s by P%d: applied %s -> 0, the host may apply again",
				rec.id, Str(attempt), playerID, Str(was))
		else
			Log(2, "Apply", "rec=%d UNDONE attempt %s by P%d: applied=%s (attempt %s) kept",
				rec.id, Str(attempt), playerID, Str(rec.applied), Str(rec.appliedAttempt))
		end
		CommitAndFlush("Apply", store)
		return
	end
	if step == TX_Config.STEP_WRITTEN then
		if rec.applied == 1 then
			Log(3, "Apply", "WRITTEN rec=%d from P%s: already applied", rec.id, Str(playerID))
			return
		end
		TX_Votes.MarkWritten(rec, world, playerID, attempt)
		Log(2, "Apply", "rec=%d WRITTEN by P%d: gameplay reads newTeam=%d for P%d; waiting for the reload",
			rec.id, playerID, rec.newTeamID, rec.targetID)
		CommitAndFlush("Apply", store)
		return
	end
	-- RELOADED
	TX_Votes.MarkDone(rec, world)
	Log(2, "Apply", "rec=%d DONE: P%d plays on team %d mode=%s (reported by P%d)", rec.id, rec.targetID, rec.newTeamID,
		TX_Votes.RecMode(rec), playerID)
	-- Commit DONE first, so the hook runs once per record: a second RELOADED
	-- (another UI, another load) finds DONE above and stops. Then the hook,
	-- then the outcome of a hard kick (hardDone) and the notification.
	if not TX_Store.Commit(store) then
		Log(1, "Apply", "commit failed; AfterReload not run, notifications dropped")
		TX_Notify.Discard()
		return
	end
	local result = nil
	SafeCall("Apply", "TX_Apply.AfterReload", function()
		result = TX_Apply.AfterReload(rec, world)
	end)
	-- The hook threw (an ERROR line already) on a hard kick: a failed one.
	if result == nil and TX_Votes.RecMode(rec) == TX_Config.MODE.HARD then
		result = TX_Apply.FAILED
	end
	if result == TX_Apply.OK or result == TX_Apply.FAILED then
		-- A hard kick ran: record the outcome once.
		if result == TX_Apply.OK then
			rec.hardDone = 1
		else
			rec.hardDone = 0
		end
		Log(2, "Apply", "rec=%d hardDone=%d", rec.id, rec.hardDone)
		TX_Notify.HardKickDone(rec, world, rec.hardDone == 1)
		if not TX_Store.Commit(store) then
			Log(1, "Apply", "rec=%d: commit of hardDone failed; the record stays DONE, the hard kick is not run again", rec.id)
		end
	else
		TX_Notify.KickDone(rec, world)
	end
	TX_Notify.Flush()
end

-- ===========================================================================
-- GameEvents.TX_Victory(playerID, { team })
-- Gameplay has no verified victory read (Game.GetWinningTeam is UI only and
-- its no-winner value is unknown, R A1), so every UI reports
-- Events.TeamVictory with this request (PLAN II.8 "Victory first", TP 2.6).
-- The first report wins; later ones only log. No notification.
-- ===========================================================================
local function Victory(playerID, params)
	local p = Params(params)
	local team = Num(p.team)
	local store = LoadStore("Votes", "victory")
	if store == nil then
		return
	end
	if store.victoryTurn ~= nil then
		Log(3, "Votes", "victory report from P%s: already recorded at T%d", Str(playerID), store.victoryTurn)
		return
	end
	local world = World()
	local s = TX_Votes.Slot(world, playerID)
	if s == nil or s.human ~= 1 then
		Log(2, "Votes", "refused victory report from P%s (not a human player)", Str(playerID))
		return
	end
	local ids = TX_Votes.Victory(store, world.turn, team)
	local parts = {}
	for _, id in ipairs(ids) do
		parts[#parts + 1] = tostring(id)
	end
	Log(2, "Votes", "victory team=%s reported by P%d: cancelled records [%s]", Str(team), playerID, table.concat(parts, ","))
	CommitAndFlush("Votes", store)
end

-- ===========================================================================
-- GameEvents.OnGameTurnStarted(turn): the turn pipeline (PLAN II.8)
-- turn <= lastTurn: skip (EFV DV9, EFV_Gameplay.lua:120-123). TX_Votes.TurnStart,
-- then per event: REMIND_VOTE -> VOTE_REQUIRED to that voter; PASSED and
-- REMIND_APPLY -> KICK_PASSED to every living human (TP 2.4 persistence:
-- re-sent each turn, the UI sweeps older copies); EXPIRED, CANCELLED,
-- TEAM_ID, APPLIED -> log only. Then Trim(HISTORY_MAX), lastTurn = turn,
-- commit, flush.
-- ===========================================================================
local function TurnStarted(eventTurn)
	local turn = TX_Util.Turn()
	if eventTurn ~= nil and eventTurn ~= turn then
		Log(3, "Turn", "OnGameTurnStarted eventTurn=%s currentTurn=%d", Str(eventTurn), turn)
	end
	local store = LoadStore("Turn", "turn start")
	if store == nil then
		return
	end
	if turn <= store.lastTurn then
		Log(2, "Turn", "skip turn=%d lastTurn=%d", turn, store.lastTurn)
		return
	end
	local world = World()
	local events = TX_Votes.TurnStart(store, world)
	for _, e in ipairs(events) do
		local rec = TX_Store.Get(store, e.id)
		if e.kind == "REMIND_VOTE" then
			Log(3, "Turn", "rec=%d remind P%d to vote", e.id, e.pid)
			TX_Notify.VoteRequired(rec, e.pid, turn)
		elseif e.kind == "PASSED" then
			Log(2, "Turn", "rec=%d PASSED: target=P%d newTeam=%d", e.id, e.pid, rec.newTeamID)
			TX_Notify.KickPassed(rec, world)
		elseif e.kind == "REMIND_APPLY" then
			Log(3, "Turn", "rec=%d still waiting for the host to apply (target=P%d newTeam=%d)", e.id, e.pid, rec.newTeamID)
			TX_Notify.KickPassed(rec, world)
		elseif e.kind == "TEAM_ID" then
			Log(2, "Turn", "rec=%d newTeam taken before the apply; now newTeam=%d", e.id, rec.newTeamID)
		elseif e.kind == "APPLIED" then
			Log(2, "Turn", "rec=%d gameplay already reads newTeam=%d for P%d; marked applied", e.id, rec.newTeamID, e.pid)
		else
			-- EXPIRED, CANCELLED: no notification (DEC 2, TP 2.1).
			Log(2, "Turn", "rec=%d %s target=P%d reason=%s", e.id, e.kind, e.pid, Str(e.reason))
		end
	end
	TX_Store.Trim(store, TX_Config.HISTORY_MAX)
	store.lastTurn = turn
	CommitAndFlush("Turn", store)
	Log(3, "Turn", "done turn=%d records=%d events=%d", turn, #store.ids, #events)
end

-- ===========================================================================
-- Hook wrappers: SafeCall + delegate (EFV_Gameplay.lua:287-291)
-- ===========================================================================
local function OnPropose(playerID, params)
	SafeCall("Votes", "TX_Propose", Propose, playerID, params)
end

local function OnVote(playerID, params)
	SafeCall("Votes", "TX_Vote", Vote, playerID, params)
end

local function OnApplyDone(playerID, params)
	SafeCall("Apply", "TX_ApplyDone", ApplyDone, playerID, params)
end

local function OnVictory(playerID, params)
	SafeCall("Votes", "TX_Victory", Victory, playerID, params)
end

local function OnGameTurnStarted(turn)
	SafeCall("Turn", "OnGameTurnStarted", TurnStarted, turn)
end

-- ===========================================================================
-- Registration at file load, unconditionally, literal names (the audit
-- matches each UI OnStart = TX_Config.REQ_* with its handler).
-- EFV_Gameplay.lua:346-387.
-- ===========================================================================
GameEvents.TX_Propose.Add(OnPropose)
Log(2, "Init", "registered GameEvents.%s", TX_Config.REQ_PROPOSE)

GameEvents.TX_Vote.Add(OnVote)
Log(2, "Init", "registered GameEvents.%s", TX_Config.REQ_VOTE)

GameEvents.TX_ApplyDone.Add(OnApplyDone)
Log(2, "Init", "registered GameEvents.%s", TX_Config.REQ_APPLY_DONE)

GameEvents.TX_Victory.Add(OnVictory)
Log(2, "Init", "registered GameEvents.%s", TX_Config.REQ_VICTORY)

GameEvents.OnGameTurnStarted.Add(OnGameTurnStarted)
Log(2, "Init", "registered GameEvents.OnGameTurnStarted")

-- Load line (PLAN II.8). A missing property is a fresh store: no seeding.
SafeCall("Init", "load line", function()
	local store = TX_Store.Load()
	Log(2, "Init", "Team Kick %s loaded records=%d rev=%d", TX_Config.VERSION, #store.ids, TX_Store.Rev())
end)
