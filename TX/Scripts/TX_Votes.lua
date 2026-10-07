-- ===========================================================================
-- TX_Votes.lua  (Team Kick 1.0.0)
-- TX:CONTEXT both
--
-- The vote state machine and its rules (PLAN II.6). Pure: no engine call,
-- no Locale, no print. Inputs are the store table (TX_Store), a world
-- snapshot, ids and the turn; outputs are changed records, reason codes and
-- event lists. Gameplay re-validates every request with these functions
-- (TP 2.5); the UI calls the same functions only to drive the display.
--
-- World: TX_Votes.MakeWorld(turn, slots), slots = every existing slot,
-- { pid, team, alive, major, human } (flags 0/1, team -1 for an empty slot).
-- Gameplay reads Players[i]:GetTeam(); the UI reads the config team, which is
-- what gameplay reads (PLAN II.0 F1, F2; II.10).
--
-- Record (PLAN II.6):
--   { id, teamID, proposerID, targetID, mode = "SOFT" | "HARD",
--     voters = { { pid = 0, v = "YES" }, { pid = 2, v = "PENDING" } },
--     openedTurn, expiresTurn, state,
--     closedTurn, reason,                          -- once it leaves OPEN
--     newTeamID, applied, appliedTurn, appliedBy,  -- from the pass on
--     appliedAttempt, undoneAttempt,               -- apply attempt tokens (UI)
--     doneTurn,
--     hardDone }                                   -- HARD only: 1 alliance ended, 0 a step failed
--
-- MP: every walk is over arrays in ascending order (slots by pid, records by
-- id, voters by pid). No pairs(), no RNG.
-- ===========================================================================

if TX_Votes ~= nil and TX_Votes.LOADED == 1 then
	return
end

include("TX_Config")
include("TX_Util")
include("TX_Store")

TX_Votes = {}

-- Every reason code; each needs LOC_TX_REASON_<CODE> in Data/TX_Text.xml
-- (tools/validate_data.py checks it; keep the closing brace at column 0).
TX_Votes.ALL_REASON_CODES = {
	"VICTORY",
	"NOT_HUMAN",
	"NOT_ALIVE",
	"TARGET_SELF",
	"TARGET_INVALID",
	"NOT_TEAMMATE",
	"VOTE_OPEN",
	"TEAM_BUSY",
	"APPLY_PENDING",
	"NO_RECORD",
	"VOTE_CLOSED",
	"NOT_VOTER",
	"ALREADY_VOTED",
	"BAD_VOTE",
	"NOT_PENDING",
	"BAD_STEP",
	"NOT_SEEN",
	"ATTEMPT_UNDONE",
	"NO_VOTE",
	"TARGET_GONE",
	"TARGET_LEFT",
	"NO_VOTERS",
	"NO_FREE_TEAM",
	"BAD_MODE",
}

-- Confirm dialog kinds (TP 2.3 wording, PLAN II.11a).
TX_Votes.KIND_DISSOLVE = "DISSOLVE"
TX_Votes.KIND_AI_ONLY = "AI_ONLY"
TX_Votes.KIND_VOTE = "VOTE"

-- ===========================================================================
-- World
-- ===========================================================================
local function Flag(v)
	if v == true or v == 1 then
		return 1
	end
	return 0
end

-- TX_Votes.MakeWorld(turn, slots) -> world
-- Copies the slots sorted by pid (the caller's order never matters) and adds
-- byPid. Entries without a numeric pid are skipped; a missing team is -1.
function TX_Votes.MakeWorld(turn, slots)
	local list = {}
	for _, s in ipairs(slots or {}) do
		if type(s) == "table" and type(s.pid) == "number" then
			list[#list + 1] = {
				pid = s.pid,
				team = tonumber(s.team) or -1,
				alive = Flag(s.alive),
				major = Flag(s.major),
				human = Flag(s.human),
			}
		end
	end
	table.sort(list, function(a, b) return a.pid < b.pid end)
	local world = { turn = tonumber(turn) or 0, slots = list, byPid = {} }
	for _, s in ipairs(list) do
		world.byPid[s.pid] = s
	end
	return world
end

function TX_Votes.Slot(world, pid)
	if pid == nil then
		return nil
	end
	return world.byPid[pid]
end

local function LivingMajorSlot(s)
	return s ~= nil and s.alive == 1 and s.major == 1
end

function TX_Votes.IsLivingMajor(world, pid)
	return LivingMajorSlot(TX_Votes.Slot(world, pid))
end

-- TX_Votes.TeamOf(world, pid) -> team (-1 when the slot is missing or empty)
function TX_Votes.TeamOf(world, pid)
	local s = TX_Votes.Slot(world, pid)
	if s == nil then
		return -1
	end
	return s.team
end

-- TX_Votes.Members(world, team) -> ascending pids of the living majors on team
function TX_Votes.Members(world, team)
	local out = {}
	if type(team) ~= "number" or team < 0 then
		return out
	end
	for _, s in ipairs(world.slots) do
		if s.team == team and LivingMajorSlot(s) then
			out[#out + 1] = s.pid
		end
	end
	return out
end

-- Human, alive major, on a team with at least 2 living majors (TP 2.3).
function TX_Votes.CanSeeTeamButton(world, pid)
	local s = TX_Votes.Slot(world, pid)
	if not LivingMajorSlot(s) or s.human ~= 1 or s.team < 0 then
		return false
	end
	return #TX_Votes.Members(world, s.team) >= 2
end

-- TX_Votes.TeamUsed(world, team, exceptPid) -> true when any slot other than
-- exceptPid is on team (dead or alive).
function TX_Votes.TeamUsed(world, team, exceptPid)
	for _, s in ipairs(world.slots) do
		if s.pid ~= exceptPid and s.team == team then
			return true
		end
	end
	return false
end

-- ===========================================================================
-- Records
-- ===========================================================================
local function IsActiveState(state)
	local ST = TX_Config.ST
	return state == ST.OPEN or state == ST.PASSED or state == ST.PENDING_APPLY
end
TX_Votes.IsActiveState = IsActiveState

-- TX_Votes.Active(store, team) -> the team's OPEN, PASSED or PENDING_APPLY record, or nil
function TX_Votes.Active(store, team)
	for _, rec in ipairs(TX_Store.Records(store)) do
		if rec.teamID == team and IsActiveState(rec.state) then
			return rec
		end
	end
	return nil
end

-- TX_Votes.VoterEntry(rec, pid) -> the { pid, v } entry or nil
function TX_Votes.VoterEntry(rec, pid)
	for _, e in ipairs(rec.voters or {}) do
		if e.pid == pid then
			return e
		end
	end
	return nil
end

-- TX_Votes.Voters(world, proposerID, targetID) -> voter list
-- The living human majors on the proposer's team except the target, ascending.
-- The proposer votes YES at once (TP 2.1); AI teammates are left out: they
-- abstain and never block (DEC 1).
function TX_Votes.Voters(world, proposerID, targetID)
	local V = TX_Config.V
	local out = {}
	local team = TX_Votes.TeamOf(world, proposerID)
	for _, pid in ipairs(TX_Votes.Members(world, team)) do
		local s = world.byPid[pid]
		if pid ~= targetID and s.human == 1 then
			if pid == proposerID then
				out[#out + 1] = { pid = pid, v = V.YES }
			else
				out[#out + 1] = { pid = pid, v = V.PENDING }
			end
		end
	end
	return out
end

-- TX_Votes.ConfirmKind(world, proposerID, targetID) -> DISSOLVE | AI_ONLY | VOTE
-- DISSOLVE: a team of 2; AI_ONLY: no other human voter in a team of 3+.
function TX_Votes.ConfirmKind(world, proposerID, targetID)
	local team = TX_Votes.TeamOf(world, proposerID)
	if #TX_Votes.Members(world, team) == 2 then
		return TX_Votes.KIND_DISSOLVE
	end
	local voters = TX_Votes.Voters(world, proposerID, targetID)
	if #voters <= 1 then
		return TX_Votes.KIND_AI_ONLY
	end
	return TX_Votes.KIND_VOTE
end

-- ===========================================================================
-- Kick modes (TX_Config.MODE; DEC 2026-10-04)
-- ===========================================================================
-- TX_Votes.ModeOK(mode) -> true for SOFT, and for HARD while
-- TX_Config.HARD_KICK_ENABLED. Anything else (nil included) is BAD_MODE.
function TX_Votes.ModeOK(mode)
	local M = TX_Config.MODE
	if mode == M.SOFT then
		return true
	end
	return mode == M.HARD and TX_Config.HARD_KICK_ENABLED == true
end

-- TX_Votes.RecMode(rec) -> the record's mode; MODE_DEFAULT (SOFT) for a
-- record without a valid one (saved before kick modes).
function TX_Votes.RecMode(rec)
	local m = rec and rec.mode
	if m == TX_Config.MODE.SOFT or m == TX_Config.MODE.HARD then
		return m
	end
	return TX_Config.MODE_DEFAULT
end

-- TX_Votes.Modes() -> the modes the dialog offers, default first.
function TX_Votes.Modes()
	local M = TX_Config.MODE
	if TX_Config.HARD_KICK_ENABLED == true then
		return { M.SOFT, M.HARD }
	end
	return { M.SOFT }
end

local function Cancel(rec, reason, turn)
	rec.state = TX_Config.ST.CANCELLED
	rec.reason = reason
	if rec.closedTurn == nil then
		rec.closedTurn = turn
	end
end

-- ===========================================================================
-- Propose
-- ===========================================================================
-- TX_Votes.ProposeReasons(store, world, senderID, targetID) -> codes (empty: ok)
-- Order: VICTORY; NOT_HUMAN; NOT_ALIVE; TARGET_SELF; TARGET_INVALID;
-- NOT_TEAMMATE; then the team's active record: APPLY_PENDING, or VOTE_OPEN,
-- which is TEAM_BUSY when the sender is that record's target (the target must
-- not learn of the vote, DEC 2).
function TX_Votes.ProposeReasons(store, world, senderID, targetID)
	local codes = {}
	if store.victoryTurn ~= nil then
		codes[#codes + 1] = "VICTORY"
	end
	local s = TX_Votes.Slot(world, senderID)
	if s == nil or s.human ~= 1 then
		codes[#codes + 1] = "NOT_HUMAN"
	end
	if not LivingMajorSlot(s) then
		codes[#codes + 1] = "NOT_ALIVE"
	end
	local t = TX_Votes.Slot(world, targetID)
	if targetID ~= nil and targetID == senderID then
		codes[#codes + 1] = "TARGET_SELF"
	elseif not LivingMajorSlot(t) then
		codes[#codes + 1] = "TARGET_INVALID"
	elseif s == nil or s.team < 0 or t.team ~= s.team then
		codes[#codes + 1] = "NOT_TEAMMATE"
	end
	if s ~= nil and s.team >= 0 then
		local active = TX_Votes.Active(store, s.team)
		if active ~= nil then
			if active.state == TX_Config.ST.OPEN then
				if active.targetID == senderID then
					codes[#codes + 1] = "TEAM_BUSY"
				else
					codes[#codes + 1] = "VOTE_OPEN"
				end
			else
				codes[#codes + 1] = "APPLY_PENDING"
			end
		end
	end
	return codes
end

-- TX_Votes.Evaluate(rec, turn) -> PASSED | FAILED | nil (still open)
-- Any NO fails it; every voter that is not GONE voting YES passes it.
-- closedTurn is set to turn when it leaves OPEN.
function TX_Votes.Evaluate(rec, turn)
	local ST, V = TX_Config.ST, TX_Config.V
	if rec.state ~= ST.OPEN then
		return nil
	end
	local live, yes = 0, 0
	for _, e in ipairs(rec.voters) do
		if e.v == V.NO then
			rec.state = ST.FAILED
			rec.reason = "NO_VOTE"
			rec.closedTurn = turn
			return ST.FAILED
		end
		if e.v ~= V.GONE then
			live = live + 1
			if e.v == V.YES then
				yes = yes + 1
			end
		end
	end
	if live > 0 and yes == live then
		rec.state = ST.PASSED
		rec.closedTurn = turn
		return ST.PASSED
	end
	return nil
end

-- TX_Votes.Propose(store, world, senderID, targetID, mode) -> rec, codes
-- Refused: nil and the reason codes (ProposeReasons, then BAD_MODE when mode
-- is not TX_Votes.ModeOK; a missing mode is refused too). Else an OPEN record
-- with that mode is added (TX_Store.Add) and evaluated at once (a proposer
-- with no other human voter passes it right away).
function TX_Votes.Propose(store, world, senderID, targetID, mode)
	local codes = TX_Votes.ProposeReasons(store, world, senderID, targetID)
	if not TX_Votes.ModeOK(mode) then
		codes[#codes + 1] = "BAD_MODE"
	end
	if #codes > 0 then
		return nil, codes
	end
	local turn = world.turn
	local rec = {
		teamID = TX_Votes.TeamOf(world, senderID),
		proposerID = senderID,
		targetID = targetID,
		mode = mode,
		voters = TX_Votes.Voters(world, senderID, targetID),
		openedTurn = turn,
		expiresTurn = turn + TX_Config.VOTE_TURNS,
		state = TX_Config.ST.OPEN,
	}
	TX_Store.Add(store, rec)
	TX_Votes.Evaluate(rec, turn)
	return rec, codes
end

-- ===========================================================================
-- Vote
-- ===========================================================================
-- TX_Votes.VoteReasons(store, world, voterID, recID, vote) -> codes
-- VICTORY, NO_RECORD, VOTE_CLOSED, NOT_VOTER (the target, AI, other teams,
-- GONE, not a living major any more), ALREADY_VOTED, BAD_VOTE.
function TX_Votes.VoteReasons(store, world, voterID, recID, vote)
	local ST, V = TX_Config.ST, TX_Config.V
	local codes = {}
	if store.victoryTurn ~= nil then
		codes[#codes + 1] = "VICTORY"
	end
	local rec = TX_Store.Get(store, recID)
	if rec == nil then
		codes[#codes + 1] = "NO_RECORD"
	elseif rec.state ~= ST.OPEN then
		codes[#codes + 1] = "VOTE_CLOSED"
	else
		local e = TX_Votes.VoterEntry(rec, voterID)
		local s = TX_Votes.Slot(world, voterID)
		if e == nil or e.v == V.GONE or not LivingMajorSlot(s) or s.human ~= 1 or s.team ~= rec.teamID then
			codes[#codes + 1] = "NOT_VOTER"
		elseif e.v ~= V.PENDING then
			codes[#codes + 1] = "ALREADY_VOTED"
		end
	end
	if vote ~= V.YES and vote ~= V.NO then
		codes[#codes + 1] = "BAD_VOTE"
	end
	return codes
end

-- TX_Votes.Vote(store, world, voterID, recID, vote) -> rec, codes
-- NO fails the vote at once (reason NO_VOTE); YES then Evaluate.
function TX_Votes.Vote(store, world, voterID, recID, vote)
	local codes = TX_Votes.VoteReasons(store, world, voterID, recID, vote)
	if #codes > 0 then
		return nil, codes
	end
	local rec = TX_Store.Get(store, recID)
	local e = TX_Votes.VoterEntry(rec, voterID)
	e.v = vote
	TX_Votes.Evaluate(rec, world.turn)
	return rec, codes
end

-- TX_Votes.Prune(rec, world) -> number of voters newly GONE
-- A voter who is no longer a living major on the team is GONE; GONE votes
-- don't count (TP 2.6). A voter whose slot turned AI is not GONE for that: the
-- vote then expires.
function TX_Votes.Prune(rec, world)
	local V = TX_Config.V
	local n = 0
	for _, e in ipairs(rec.voters) do
		if e.v ~= V.GONE then
			local s = TX_Votes.Slot(world, e.pid)
			if not LivingMajorSlot(s) or s.team ~= rec.teamID then
				e.v = V.GONE
				n = n + 1
			end
		end
	end
	return n
end

local function AllGone(rec)
	for _, e in ipairs(rec.voters) do
		if e.v ~= TX_Config.V.GONE then
			return false
		end
	end
	return true
end

-- ===========================================================================
-- Pass and the new team ID
-- ===========================================================================
-- TX_Votes.NewTeamID(world, store, recID) -> team or nil
-- The lowest t >= 0 that no slot uses (every slot: dead or alive, majors,
-- city-states, 62, 63; -1 ignored; PLAN II.0 F5) and that no other
-- PENDING_APPLY record holds. nil above TX_Config.MAX_TEAM_ID.
function TX_Votes.NewTeamID(world, store, recID)
	local used = {}
	for _, s in ipairs(world.slots) do
		if s.team >= 0 then
			used[s.team] = true
		end
	end
	for _, rec in ipairs(TX_Store.Records(store)) do
		if rec.id ~= recID and rec.state == TX_Config.ST.PENDING_APPLY and type(rec.newTeamID) == "number" then
			used[rec.newTeamID] = true
		end
	end
	for t = 0, TX_Config.MAX_TEAM_ID do
		if not used[t] then
			return t
		end
	end
	return nil
end

-- TX_Votes.FinishPass(store, world, rec) -> the new state
-- PASSED to PENDING_APPLY with newTeamID and applied = 0, or CANCELLED with
-- NO_FREE_TEAM.
function TX_Votes.FinishPass(store, world, rec)
	local ST = TX_Config.ST
	if rec.state ~= ST.PASSED then
		return rec.state
	end
	local team = TX_Votes.NewTeamID(world, store, rec.id)
	if team == nil then
		Cancel(rec, "NO_FREE_TEAM", world.turn)
		return rec.state
	end
	rec.state = ST.PENDING_APPLY
	rec.newTeamID = team
	rec.applied = 0
	return rec.state
end

-- ===========================================================================
-- Apply seam (PLAN II.9): WRITTEN and RELOADED reports from the host's UI
-- ===========================================================================
-- TX_Votes.ApplyReasons(store, world, senderID, recID, step, attempt) -> codes
-- NOT_HUMAN, NO_RECORD, NOT_PENDING, BAD_STEP, ATTEMPT_UNDONE (a WRITTEN
-- whose attempt, missing = 0, is not above the record's undoneAttempt: the
-- UI already undid that write), NOT_SEEN (WRITTEN, RELOADED: gameplay does
-- not read newTeamID for the target). UNDONE needs no read: the UI wrote the
-- old team back.
function TX_Votes.ApplyReasons(store, world, senderID, recID, step, attempt)
	local codes = {}
	local s = TX_Votes.Slot(world, senderID)
	if s == nil or s.human ~= 1 then
		codes[#codes + 1] = "NOT_HUMAN"
	end
	local rec = TX_Store.Get(store, recID)
	if rec == nil then
		codes[#codes + 1] = "NO_RECORD"
	elseif rec.state ~= TX_Config.ST.PENDING_APPLY then
		codes[#codes + 1] = "NOT_PENDING"
	end
	local stepOk = (step == TX_Config.STEP_WRITTEN or step == TX_Config.STEP_RELOADED or step == TX_Config.STEP_UNDONE)
	if not stepOk then
		codes[#codes + 1] = "BAD_STEP"
	end
	local pending = rec ~= nil and rec.state == TX_Config.ST.PENDING_APPLY
	if pending and step == TX_Config.STEP_WRITTEN and type(rec.undoneAttempt) == "number"
			and (attempt or 0) <= rec.undoneAttempt then
		codes[#codes + 1] = "ATTEMPT_UNDONE"
	end
	if pending and stepOk and step ~= TX_Config.STEP_UNDONE
			and TX_Votes.TeamOf(world, rec.targetID) ~= rec.newTeamID then
		codes[#codes + 1] = "NOT_SEEN"
	end
	return codes
end

-- TX_Votes.MarkWritten(rec, world, senderID, attempt): applied = 1,
-- appliedTurn, appliedBy (-1 when found at a turn start), appliedAttempt (the
-- WRITTEN's attempt, when it has one). A second call changes nothing.
function TX_Votes.MarkWritten(rec, world, senderID, attempt)
	if rec.applied == 1 then
		return
	end
	rec.applied = 1
	rec.appliedTurn = world.turn
	rec.appliedBy = senderID
	if type(attempt) == "number" then
		rec.appliedAttempt = attempt
	end
end

-- TX_Votes.MarkUndone(rec, attempt) -> true when applied went back to 0
-- The host's UI undid the write of that attempt (missing = 0): undoneAttempt
-- = the highest one undone (a WRITTEN up to it is refused, ATTEMPT_UNDONE);
-- applied = 1 from that attempt, an older one or a turn start goes back to 0
-- and the applied fields are cleared, so the host may apply again. applied
-- by a newer attempt stays.
function TX_Votes.MarkUndone(rec, attempt)
	local a = attempt or 0
	if type(rec.undoneAttempt) ~= "number" or a > rec.undoneAttempt then
		rec.undoneAttempt = a
	end
	if rec.applied ~= 1 or (rec.appliedAttempt or 0) > a then
		return false
	end
	rec.applied = 0
	rec.appliedTurn = nil
	rec.appliedBy = nil
	rec.appliedAttempt = nil
	return true
end

-- TX_Votes.MarkDone(rec, world): DONE with doneTurn (and the applied fields
-- when no WRITTEN came first).
function TX_Votes.MarkDone(rec, world)
	TX_Votes.MarkWritten(rec, world, -1)
	rec.state = TX_Config.ST.DONE
	rec.doneTurn = world.turn
end

-- ===========================================================================
-- Victory and the turn start
-- ===========================================================================
local function CancelledByVictory(rec)
	local ST = TX_Config.ST
	return rec.state == ST.OPEN or rec.state == ST.PASSED or (rec.state == ST.PENDING_APPLY and rec.applied ~= 1)
end

-- TX_Votes.Victory(store, turn, team) -> ids cancelled
-- First call only: records victoryTurn / victoryTeam and cancels OPEN, PASSED
-- and unapplied PENDING_APPLY records (reason VICTORY). Later calls return {}.
function TX_Votes.Victory(store, turn, team)
	local ids = {}
	if store.victoryTurn ~= nil then
		return ids
	end
	store.victoryTurn = tonumber(turn) or 0
	if type(team) == "number" then
		store.victoryTeam = team
	end
	for _, rec in ipairs(TX_Store.Records(store)) do
		if CancelledByVictory(rec) then
			Cancel(rec, "VICTORY", store.victoryTurn)
			ids[#ids + 1] = rec.id
		end
	end
	return ids
end

-- TX_Votes.TurnStart(store, world) -> events { kind, id, pid [, reason] }
-- For each record in id order:
--   PASSED (stored only if an error hit between the two steps): FinishPass.
--   OPEN: target checks (TARGET_GONE, TARGET_LEFT), Prune (every voter GONE:
--     NO_VOTERS), Evaluate (PASSED then FinishPass), then expiry; still open:
--     one REMIND_VOTE per pending voter who is human now.
--   PENDING_APPLY: target dead (TARGET_GONE); gameplay already reads
--     newTeamID with applied = 0: MarkWritten(-1) (event APPLIED); applied = 0
--     and another slot on newTeamID: a new ID (TEAM_ID) or NO_FREE_TEAM; still
--     pending: REMIND_APPLY.
--   With a victory: no passes; OPEN, PASSED and unapplied PENDING_APPLY are
--     cancelled (VICTORY).
-- Event kinds: PASSED, EXPIRED, CANCELLED, REMIND_VOTE, REMIND_APPLY, TEAM_ID,
-- APPLIED. pid is the voter for REMIND_VOTE, else the target.
function TX_Votes.TurnStart(store, world)
	local ST, V = TX_Config.ST, TX_Config.V
	local turn = world.turn
	local events = {}
	local function Event(kind, rec, pid, reason)
		events[#events + 1] = { kind = kind, id = rec.id, pid = pid or rec.targetID, reason = reason }
	end
	local function CancelEvent(rec, reason)
		Cancel(rec, reason, turn)
		Event("CANCELLED", rec, nil, reason)
	end
	local function Finish(rec)
		if TX_Votes.FinishPass(store, world, rec) == ST.PENDING_APPLY then
			Event("PASSED", rec)
		else
			Event("CANCELLED", rec, nil, rec.reason)
		end
	end
	local victory = store.victoryTurn ~= nil

	for _, rec in ipairs(TX_Store.Records(store)) do
		local target = rec.targetID
		if victory and CancelledByVictory(rec) then
			CancelEvent(rec, "VICTORY")
		elseif rec.state == ST.PASSED then
			Finish(rec)
		elseif rec.state == ST.OPEN then
			if not TX_Votes.IsLivingMajor(world, target) then
				CancelEvent(rec, "TARGET_GONE")
			elseif TX_Votes.TeamOf(world, target) ~= rec.teamID then
				CancelEvent(rec, "TARGET_LEFT")
			else
				TX_Votes.Prune(rec, world)
				if AllGone(rec) then
					CancelEvent(rec, "NO_VOTERS")
				elseif TX_Votes.Evaluate(rec, turn) == ST.PASSED then
					Finish(rec)
				elseif rec.state == ST.OPEN and turn >= rec.expiresTurn then
					rec.state = ST.EXPIRED
					rec.closedTurn = turn
					Event("EXPIRED", rec)
				elseif rec.state == ST.OPEN then
					for _, e in ipairs(rec.voters) do
						local s = TX_Votes.Slot(world, e.pid)
						if e.v == V.PENDING and s ~= nil and s.human == 1 then
							Event("REMIND_VOTE", rec, e.pid)
						end
					end
				end
			end
		elseif rec.state == ST.PENDING_APPLY then
			if not TX_Votes.IsLivingMajor(world, target) then
				CancelEvent(rec, "TARGET_GONE")
			else
				if rec.applied ~= 1 and TX_Votes.TeamOf(world, target) == rec.newTeamID then
					TX_Votes.MarkWritten(rec, world, -1)
					Event("APPLIED", rec)
				elseif rec.applied ~= 1 and TX_Votes.TeamUsed(world, rec.newTeamID, target) then
					local team = TX_Votes.NewTeamID(world, store, rec.id)
					if team == nil then
						CancelEvent(rec, "NO_FREE_TEAM")
					else
						rec.newTeamID = team
						Event("TEAM_ID", rec)
					end
				end
				if rec.state == ST.PENDING_APPLY then
					Event("REMIND_APPLY", rec)
				end
			end
		end
	end
	return events
end

-- ===========================================================================
-- Display helpers (UI and notifications)
-- ===========================================================================
-- TX_Votes.RoleOf(rec, pid, team) -> TARGET, PROPOSER, VOTER, TEAM, OTHER
-- team (optional) is pid's team: TEAM when it is the record's team.
function TX_Votes.RoleOf(rec, pid, team)
	if pid == rec.targetID then
		return "TARGET"
	end
	if pid == rec.proposerID then
		return "PROPOSER"
	end
	if TX_Votes.VoterEntry(rec, pid) ~= nil then
		return "VOTER"
	end
	if team ~= nil and team == rec.teamID then
		return "TEAM"
	end
	return "OTHER"
end

-- TX_Votes.VisibleTo(rec, viewerID, viewerTeam) -> bool
-- The target sees a record only once the kick passed (PENDING_APPLY, DONE),
-- also after it left the team; everybody else sees the records of their own
-- team. So an open vote is hidden from the target, and past votes against the
-- viewer only show if they passed (TP 2.3, DEC 2).
function TX_Votes.VisibleTo(rec, viewerID, viewerTeam)
	local ST = TX_Config.ST
	if viewerID == rec.targetID then
		return rec.state == ST.PENDING_APPLY or rec.state == ST.DONE
	end
	return viewerTeam ~= nil and rec.teamID == viewerTeam
end

-- TX_Votes.TurnsLeft(rec, turn) -> max(0, expiresTurn - turn)
function TX_Votes.TurnsLeft(rec, turn)
	return math.max(0, (rec.expiresTurn or 0) - (tonumber(turn) or 0))
end

TX_Votes.LOADED = 1
