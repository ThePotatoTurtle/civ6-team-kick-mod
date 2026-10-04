-- Tests of TX/Scripts/TX_Gameplay.lua with TX_Notify and TX_Apply (PLAN II.14
-- "test_tx_gameplay.lua", build chunk B of II.16): the real gameplay script on
-- the fake engine plus lib/fake_txworld.lua; requests through H.request (the
-- way EXECUTE_SCRIPT delivers them). TP 2.7 phase 1 and the TP 2.6 rows that
-- belong to gameplay, the turn-start pipeline and the notifications.
--
-- Standard world (FAKE_TX.World): P0, P1, P2 human on team 0; P3 human and P4
-- AI on team 1; P5 human solo (team 2); city-state 6 (team 3); slots 7..61
-- empty (team -1); Free Cities 62 (team 4); Barbarians 63 (team 5). Every pair
-- of majors has met. The first free team ID is 6. The game starts at turn 1,
-- so a vote opened at turn 1 expires at the start of turn 6.

local GAMEPLAY = "TX/Scripts/TX_Gameplay.lua"

local VOTE = "NOTIFICATION_TX_VOTE_REQUIRED"
local PASSED = "NOTIFICATION_TX_KICK_PASSED"
local DONE = "NOTIFICATION_TX_KICK_DONE"
local FAILED = "NOTIFICATION_TX_REQUEST_FAILED"

local HUMANS = { 0, 1, 2, 3, 5 }   -- the living human majors of the standard world

local function Setup(opts)
	FAKE.dofile("tests/offline/lib/fake_txworld.lua")
	FAKE_TX.World(opts)
	H.load(GAMEPLAY)
end

-- Requests (flat params, PLAN II.8).
local function Propose(pid, target, mode)
	H.request(pid, { OnStart = "TX_Propose", targetID = target, mode = mode or "SOFT" })
end
local function Vote(pid, id, v)
	H.request(pid, { OnStart = "TX_Vote", recordID = id, vote = v })
end
local function ApplyDone(pid, id, step, team)
	H.request(pid, { OnStart = "TX_ApplyDone", recordID = id, step = step, team = team })
end
local function Victory(pid, team)
	H.request(pid, { OnStart = "TX_Victory", team = team })
end

-- The stored state.
local function Store()
	return H.prop("TX_Store")
end
local function Rec(id)
	local s = Store()
	if s == nil or s.recs == nil then
		return nil
	end
	return s.recs["r" .. id]
end
local function Rev()
	return H.prop("TX_Rev") or 0
end

-- Notifications.
local function Pids(typeName, from)
	local out = {}
	for i = (from or 0) + 1, #FAKE.notifications do
		local n = FAKE.notifications[i]
		if typeName == nil or n.typeName == typeName then
			out[#out + 1] = n.pid
		end
	end
	return out
end
local function Count()
	return #FAKE.notifications
end
local function Last(pid, typeName)
	local list = H.notifs(pid, typeName)
	return list[#list]
end
local function Summary(n)
	return n and n.data[ParameterTypes.SUMMARY]
end
local function Message(n)
	return n and n.data[ParameterTypes.MESSAGE]
end
local function Reason(code)
	return FAKE_TEXT["LOC_TX_REASON_" .. code]
end
local function Label(pid)
	return "LOC_LEADER_FAKE_" .. pid .. "_NAME (LOC_CIVILIZATION_FAKE_" .. pid .. "_NAME)"
end

local function VotesText(rec)
	local parts = {}
	for _, e in ipairs(rec.voters) do
		parts[#parts + 1] = e.pid .. "=" .. e.v
	end
	return table.concat(parts, ",")
end

-- P0 proposes P1, P2 votes YES: record 1 PENDING_APPLY with newTeamID 6.
local function Pass()
	Propose(0, 1)
	Vote(2, 1, "YES")
	H.eq(Rec(1).state, "PENDING_APPLY", "the kick passed")
end

-- ===========================================================================
-- 1. Load
-- ===========================================================================
test("gameplay 1: load line with 0.1.0; the four TX handlers and OnGameTurnStarted registered; no Events handler", function()
	Setup()
	H.len(H.lines("[TX][T1][Init] Team Expulsion 0.1.0 loaded records=0 rev=0", true), 1, "load line")
	for _, name in ipairs({ "TX_Propose", "TX_Vote", "TX_ApplyDone", "TX_Victory", "OnGameTurnStarted" }) do
		H.eq(GameEvents[name].Count(), 1, name)
		H.len(H.lines("[TX][T1][Init] registered GameEvents." .. name, true), 1, "registration line " .. name)
	end
	-- gameplay registers no Events.* handler (MP: only GameEvents are synced)
	for name, ev in pairs(Events) do
		H.eq(ev.Count(), 0, "Events." .. tostring(name))
	end
	H.isnil(Store(), "nothing written at load (no seeding, PLAN II.5)")
	H.clean()
end)

-- ===========================================================================
-- 2. Propose
-- ===========================================================================
test("gameplay 2: P0 proposes P1: VOTE_REQUIRED only to P2 with the record id; the record is OPEN in the property", function()
	Setup()
	Propose(0, 1)
	local rec = Rec(1)
	H.notnil(rec)
	H.eq(rec.state, "OPEN")
	H.eq(rec.teamID, 0)
	H.eq(rec.proposerID, 0)
	H.eq(rec.targetID, 1)
	H.eq(VotesText(rec), "0=YES,2=PENDING")
	H.eq(rec.openedTurn, 1)
	H.eq(rec.expiresTurn, 6)
	H.eq(Rev(), 1)
	H.deq(Pids(), { 2 }, "only P2, never the proposer, the target, the AI or another team")
	local n = Last(2, VOTE)
	H.eq(n.data.TX_RecordID, 1)
	H.eq(n.data.TX_Turn, 1)
	H.eq(n.data.AlwaysUnique, true)
	H.eq(Message(n), "Team vote")
	-- the fake Locale leaves "#" of a plural form as is (test_harness_selftest.lua:159-161)
	H.eq(Summary(n), Label(0) .. " wants to kick " .. Label(1) .. " off your team (soft kick). Vote within # turns.")
	H.ok(H.hasLine("[TX][T1][Votes] rec=1 opened team=0 proposer=P0 target=P1 mode=SOFT voters=[P0=YES P2=PENDING] expires=T6"))
	H.ok(H.hasLine("[TX][T1][Notify] sent pid=2 type=NOTIFICATION_TX_VOTE_REQUIRED rec=1"))
	H.clean()
end)

-- ===========================================================================
-- 3. A NO fails the vote
-- ===========================================================================
test("gameplay 3: P2 votes NO: FAILED; no notification of the outcome; P1 never got a TX notification", function()
	Setup()
	Propose(0, 1)
	local before = Count()
	Vote(2, 1, "NO")
	local rec = Rec(1)
	H.eq(rec.state, "FAILED")
	H.eq(rec.reason, "NO_VOTE")
	H.eq(rec.closedTurn, 1)
	H.eq(Count(), before, "FAILED is not announced (DEC 2)")
	H.len(H.notifs(1), 0, "the target never learns of the vote")
	H.ok(H.hasLine("rec=1 FAILED (NO_VOTE by P2)"))
	H.endTurn()
	H.eq(Count(), before, "no reminder for a closed vote")
	H.clean()
end)

-- ===========================================================================
-- 4. A pass
-- ===========================================================================
test("gameplay 4: re-proposal after a NO; P2 YES: PENDING_APPLY with newTeamID 6; KICK_PASSED to every living human, not the AI", function()
	Setup()
	Propose(0, 1)
	Vote(2, 1, "NO")
	Propose(0, 1)
	H.eq(Rec(2).state, "OPEN", "re-proposal allowed, new id")
	local before = Count()
	Vote(2, 2, "YES")
	local rec = Rec(2)
	H.eq(rec.state, "PENDING_APPLY")
	H.eq(rec.newTeamID, 6)
	H.eq(rec.applied, 0)
	H.eq(rec.closedTurn, 1)
	H.deq(Pids(PASSED, before), HUMANS, "P0, P1, P2, P3 and P5, not P4")
	H.deq(Pids(nil, before), HUMANS, "nothing else")
	local n = Last(1, PASSED)
	H.eq(n.data.TX_RecordID, 2)
	H.eq(Message(n), "Kicked off a team")
	H.eq(Summary(n), Label(1) .. " was voted off their team (soft kick). It takes effect once the host applies it and the game is saved and reloaded.")
	H.ok(H.hasLine("rec=2 PASSED: target=P1 newTeam=6, waiting for the host to apply"))
	H.clean()
end)

-- ===========================================================================
-- 5. Refused requests
-- ===========================================================================
test("gameplay 5: refused requests: REQUEST_FAILED to the sender only, TX_Rev unchanged", function()
	Setup()
	Propose(0, 1)   -- an open vote: P0 YES, P2 PENDING
	local function Refused(fn, sender, code, label)
		local rev, before = Rev(), Count()
		fn()
		H.eq(Rev(), rev, label .. ": nothing stored")
		if sender == nil then
			H.eq(Count(), before, label .. ": no notification (AI sender)")
			return
		end
		H.deq(Pids(nil, before), { sender }, label .. ": REQUEST_FAILED to the sender only")
		local n = FAKE.notifications[#FAKE.notifications]
		H.eq(n.typeName, FAILED, label)
		H.eq(Message(n), "Team request refused", label)
		H.eq(Summary(n), Reason(code), label .. ": the first reason " .. code)
	end
	Refused(function() Propose(3, 3) end, 3, "TARGET_SELF", "self")
	Refused(function() Propose(3, 6) end, 3, "TARGET_INVALID", "city-state")
	Refused(function() Propose(3, 63) end, 3, "TARGET_INVALID", "barbarians")
	Refused(function() Propose(3, 30) end, 3, "TARGET_INVALID", "empty slot")
	Refused(function() Propose(3, 0) end, 3, "NOT_TEAMMATE", "other team")
	Refused(function() Propose(4, 3) end, nil, "NOT_HUMAN", "AI sender")
	Refused(function() Vote(0, 1, "YES") end, 0, "ALREADY_VOTED", "double vote")
	Refused(function() Vote(1, 1, "NO") end, 1, "NOT_VOTER", "vote by the target")
	Refused(function() Vote(3, 1, "YES") end, 3, "NOT_VOTER", "vote from another team")
	Refused(function() Vote(2, 99, "YES") end, 2, "NO_RECORD", "unknown record")
	-- non-number / non-string params read as missing
	Refused(function() H.request(3, { OnStart = "TX_Propose", targetID = "4" }) end, 3, "TARGET_INVALID", "string target")
	Refused(function() H.request(3, { OnStart = "TX_Propose", targetID = 4.5 }) end, 3, "TARGET_INVALID", "fractional target")
	Refused(function() H.request(3, { OnStart = "TX_Propose" }) end, 3, "TARGET_INVALID", "no target")
	Refused(function() Vote(2, "1", "YES") end, 2, "NO_RECORD", "string record id")
	Refused(function() Vote(2, 1, 1) end, 2, "BAD_VOTE", "number vote")
	Refused(function() Vote(2, 1, "MAYBE") end, 2, "BAD_VOTE", "unknown vote")
	Refused(function() GameEvents.TX_Propose(3, "not a table") end, 3, "TARGET_INVALID", "params not a table")
	Refused(function() ApplyDone(0, 1, "WRITTEN", 6) end, 0, "NOT_PENDING", "apply while open")
	H.eq(Rec(1).state, "OPEN", "the open vote is untouched")
	H.eq(VotesText(Rec(1)), "0=YES,2=PENDING")
	H.ok(H.hasLine("[TX][T1][Votes] refused propose from P3: TARGET_SELF"))
	H.clean()
end)

-- ===========================================================================
-- 6. The target never learns of the open vote
-- ===========================================================================
test("gameplay 6: the target proposing during the open vote gets the TEAM_BUSY text, never VOTE_OPEN", function()
	Setup()
	Propose(0, 1)
	local before = Count()
	Propose(1, 2)
	H.deq(Pids(nil, before), { 1 })
	H.eq(Summary(Last(1, FAILED)), Reason("TEAM_BUSY"))
	-- a third teammate who is not the target gets VOTE_OPEN
	Propose(2, 0)
	H.eq(Summary(Last(2, FAILED)), Reason("VOTE_OPEN"))
	for _, n in ipairs(H.notifs(1)) do
		H.ne(Summary(n), Reason("VOTE_OPEN"), "P1 never sees VOTE_OPEN")
		H.ne(n.typeName, VOTE, "P1 never gets VOTE_REQUIRED")
	end
	H.clean()
end)

-- ===========================================================================
-- 7. Persistence and expiry
-- ===========================================================================
test("gameplay 7: VOTE_REQUIRED re-sent to P2 each turn start while pending; EXPIRED at opened + 5; nothing after", function()
	Setup()
	-- raw arguments: proposer | target | turns left
	FAKE.SetText("LOC_NOTIFICATION_TX_VOTE_REQUIRED_SUMMARY", "{1_P}|{2_P}|{3_Num}")
	Propose(0, 1)
	H.len(H.notifs(2, VOTE), 1)
	H.eq(Summary(Last(2, VOTE)), Label(0) .. "|" .. Label(1) .. "|5")
	H.endTurn()   -- turn 2
	H.len(H.notifs(2, VOTE), 2)
	H.eq(Summary(Last(2, VOTE)), Label(0) .. "|" .. Label(1) .. "|4")
	H.eq(Last(2, VOTE).data.TX_Turn, 2)
	H.eq(Last(2, VOTE).data.TX_RecordID, 1)
	H.turns(3)    -- turns 3, 4, 5
	H.len(H.notifs(2, VOTE), 5)
	H.eq(Summary(Last(2, VOTE)), Label(0) .. "|" .. Label(1) .. "|1")
	H.eq(Rec(1).state, "OPEN", "still open at expiresTurn - 1")
	local before = Count()
	H.endTurn()   -- turn 6 = expiresTurn
	H.eq(Rec(1).state, "EXPIRED")
	H.eq(Rec(1).closedTurn, 6)
	H.eq(Count(), before, "EXPIRED is not announced")
	H.turns(2)
	H.eq(Count(), before, "nothing after the expiry")
	H.deq(Pids(VOTE), { 2, 2, 2, 2, 2 }, "only P2 was ever reminded")
	H.ok(H.hasLine("[TX][T6][Turn] rec=1 EXPIRED target=P1 reason=nil"))
	-- re-proposal allowed after the expiry
	Propose(0, 1)
	H.eq(Rec(2).state, "OPEN")
	H.clean()
end)

-- ===========================================================================
-- 8. Turn guard
-- ===========================================================================
test("gameplay 8: a second OnGameTurnStarted for the same turn is skipped", function()
	Setup()
	Propose(0, 1)
	H.endTurn()
	H.eq(Store().lastTurn, 2)
	local rev, before = Rev(), Count()
	GameEvents.OnGameTurnStarted(2)
	H.eq(Rev(), rev, "nothing stored")
	H.eq(Count(), before, "no second reminder")
	H.ok(H.hasLine("[TX][T2][Turn] skip turn=2 lastTurn=2"))
	H.clean()
end)

-- ===========================================================================
-- 9. TP 2.6 rows
-- ===========================================================================
test("gameplay 9a: team of 2: P3 kicks AI P4: PENDING_APPLY in the same request", function()
	Setup()
	Propose(3, 4)
	local rec = Rec(1)
	H.eq(rec.state, "PENDING_APPLY")
	H.eq(rec.newTeamID, 6)
	H.eq(VotesText(rec), "3=YES")
	H.deq(Pids(PASSED), HUMANS)
	H.len(H.notifs(nil, VOTE), 0, "nobody to ask")
	H.clean()
end)

test("gameplay 9b: target eliminated during the vote: CANCELLED TARGET_GONE, nobody notified", function()
	Setup()
	Propose(0, 1)
	local before = Count()
	H.kill(1)
	H.endTurn()
	H.eq(Rec(1).state, "CANCELLED")
	H.eq(Rec(1).reason, "TARGET_GONE")
	H.eq(Rec(1).closedTurn, 2)
	H.eq(Count(), before, "no PASSED, no reminder, nothing")
	H.clean()
end)

test("gameplay 9c: voter eliminated: GONE, the pass happens at the next turn start", function()
	Setup()
	Propose(0, 1)
	H.kill(2)
	local before = Count()
	H.endTurn()
	local rec = Rec(1)
	H.eq(VotesText(rec), "0=YES,2=GONE")
	H.eq(rec.state, "PENDING_APPLY")
	H.eq(rec.closedTurn, 2)
	H.eq(rec.newTeamID, 6)
	H.deq(Pids(nil, before), { 0, 1, 3, 5 }, "KICK_PASSED to the living humans only, once each")
	H.deq(Pids(PASSED, before), { 0, 1, 3, 5 })
	H.clean()
end)

test("gameplay 9d: a human voter turned AI: no re-send, the vote expires", function()
	Setup()
	Propose(0, 1)
	H.human(2, false)
	local before = Count()
	H.turns(5)
	H.eq(Count(), before, "no reminder to the AI slot, nothing else")
	H.eq(Rec(1).state, "EXPIRED")
	H.eq(VotesText(Rec(1)), "0=YES,2=PENDING", "turned AI is not GONE (TP 2.6)")
	H.clean()
end)

test("gameplay 9e: victory: the open vote is cancelled; later proposals and votes refused with VICTORY; first report only", function()
	Setup()
	Propose(0, 1)
	local before = Count()
	Victory(4, 1)   -- an AI never reports
	H.isnil(Store().victoryTurn, "AI report ignored")
	H.ok(H.hasLine("refused victory report from P4 (not a human player)"))
	Victory(3, 1)
	local s = Store()
	H.eq(s.victoryTurn, 1)
	H.eq(s.victoryTeam, 1)
	H.eq(Rec(1).state, "CANCELLED")
	H.eq(Rec(1).reason, "VICTORY")
	H.eq(Count(), before, "no notification for a victory")
	H.ok(H.hasLine("victory team=1 reported by P3: cancelled records [1]"))
	local rev = Rev()
	Victory(0, 0)
	H.eq(Rev(), rev, "a second report changes nothing")
	H.eq(Store().victoryTeam, 1)
	H.eq(Count(), before, "and sends nothing")
	Propose(3, 4)
	H.eq(Summary(Last(3, FAILED)), Reason("VICTORY"))
	Vote(2, 1, "YES")
	H.eq(Summary(Last(2, FAILED)), Reason("VICTORY"))
	H.isnil(Rec(2), "nothing opened")
	H.endTurn()
	H.eq(Rec(1).state, "CANCELLED")
	H.clean()
end)

test("gameplay 9f: the target is the only other human, AI teammates: passes at once", function()
	Setup()
	H.human(2, false)
	Propose(0, 1)
	local rec = Rec(1)
	H.eq(rec.state, "PENDING_APPLY")
	H.eq(VotesText(rec), "0=YES")
	H.deq(Pids(PASSED), { 0, 1, 3, 5 })
	H.len(H.notifs(nil, VOTE), 0)
	H.clean()
end)

test("gameplay 9g: the host never applies: PENDING_APPLY for 10 turns, KICK_PASSED each turn, nothing else", function()
	Setup()
	Pass()
	local before = Count()
	H.turns(10)
	local rec = Rec(1)
	H.eq(rec.state, "PENDING_APPLY")
	H.eq(rec.applied, 0)
	H.eq(rec.newTeamID, 6)
	H.isnil(rec.appliedTurn)
	H.eq(Count() - before, 10 * #HUMANS, "one KICK_PASSED per living human per turn")
	H.eq(#Pids(PASSED, before), 10 * #HUMANS, "only KICK_PASSED")
	H.eq(Last(5, PASSED).data.TX_Turn, 11)
	H.eq(Last(5, PASSED).data.TX_RecordID, 1)
	-- the team stays busy
	Propose(2, 0)
	H.eq(Summary(Last(2, FAILED)), Reason("APPLY_PENDING"))
	H.eq(#FAKE.teamSets, 0, "gameplay never writes a team")
	H.clean()
end)

test("gameplay 9h: mod added to a save with no records: the first turn start and request work", function()
	Setup({ turn = 30 })
	H.isnil(Store())
	H.endTurn()
	local s = Store()
	H.eq(s.lastTurn, 31)
	H.eq(s.nextID, 1)
	H.isnil(s.ids, "empty lists are left out")
	Propose(0, 1)
	H.eq(Rec(1).state, "OPEN")
	H.eq(Rec(1).openedTurn, 31)
	H.eq(Rec(1).expiresTurn, 36)
	H.deq(Pids(), { 2 })
	H.clean()
end)

-- ===========================================================================
-- 10. Apply seam, gameplay side
-- ===========================================================================
test("gameplay 10: WRITTEN without the write: NOT_SEEN, an ERROR line, REQUEST_FAILED; nothing stored", function()
	Setup()
	Pass()
	local rev, before = Rev(), Count()
	ApplyDone(0, 1, "WRITTEN", 6)
	H.eq(Rev(), rev)
	H.eq(Rec(1).applied, 0)
	H.deq(Pids(nil, before), { 0 })
	H.eq(Summary(Last(0, FAILED)), Reason("NOT_SEEN"))
	H.eq(Last(0, FAILED).data.TX_RecordID, 1, "the UI can match the refusal to its record")
	H.len(H.lines("[TX][T1][Apply] ERROR WRITTEN rec=1: gameplay reads team=0 for P1, not newTeam=6 (NOT_SEEN)"), 1)
end, { allowErrors = true })

test("gameplay 10: WRITTEN after the config write: applied; RELOADED after the load: DONE, KICK_DONE to all, AfterReload once; a duplicate adds nothing", function()
	Setup()
	Pass()
	-- the host's UI writes the config team (F1); gameplay reads it at once (F2)
	PlayerConfigurations[1]:SetTeam(6)
	local before = Count()
	ApplyDone(2, 1, "WRITTEN", 6)
	local rec = Rec(1)
	H.eq(rec.state, "PENDING_APPLY")
	H.eq(rec.applied, 1)
	H.eq(rec.appliedTurn, 1)
	H.eq(rec.appliedBy, 2)
	H.eq(Count(), before, "no KICK_DONE before the reload")
	H.ok(H.hasLine("[TX][T1][Apply] rec=1 WRITTEN by P2: gameplay reads newTeam=6 for P1; waiting for the reload"))
	-- a second WRITTEN changes nothing
	local rev = Rev()
	ApplyDone(0, 1, "WRITTEN", 6)
	H.eq(Rev(), rev)
	H.eq(Rec(1).appliedBy, 2)
	H.eq(Count(), before)
	-- the end of the turn still reminds (PENDING_APPLY until DONE)
	H.endTurn()
	H.deq(Pids(PASSED, before), HUMANS)
	-- save and load (F4), then a UI reports RELOADED
	FAKE_TX.Reload()
	H.markBody()
	before = Count()
	ApplyDone(3, 1, "RELOADED", 6)
	rec = Rec(1)
	H.eq(rec.state, "DONE")
	H.eq(rec.doneTurn, 2)
	H.eq(rec.applied, 1)
	H.eq(rec.appliedBy, 2, "the WRITTEN fields stay")
	H.deq(Pids(nil, before), HUMANS, "KICK_DONE to every living human")
	H.deq(Pids(DONE, before), HUMANS)
	H.eq(Message(Last(0, DONE)), "Team changed")
	H.eq(Summary(Last(0, DONE)), Label(1) .. " now plays alone and stays allied with their old team.")
	H.eq(Last(0, DONE).data.TX_RecordID, 1)
	H.len(H.lines("[TX][T2][Apply] AfterReload rec=1 target=P1 mode=SOFT: no war step, the ex-teammates stay allied (O2 vision: known limitation)"), 1)
	-- every other UI reports too: nothing new
	rev, before = Rev(), Count()
	ApplyDone(0, 1, "RELOADED", 6)
	ApplyDone(2, 1, "RELOADED", 6)
	H.eq(Rev(), rev)
	H.eq(Count(), before)
	H.len(H.lines("AfterReload rec=1"), 1, "the hook ran once")
	-- DONE is never re-announced
	H.endTurn()
	H.eq(Count(), before)
	-- P1 is on its own team; P0 and P2 can still vote among themselves
	Propose(0, 2)
	H.eq(Rec(2).state, "PENDING_APPLY", "team of 2 now: dissolves at once")
	H.eq(Rec(2).newTeamID, 7, "6 is P1's team now")
	H.clean()
end)

test("gameplay 10: RELOADED without the record or with a bad step is refused", function()
	Setup()
	Pass()
	local rev = Rev()
	ApplyDone(0, 9, "RELOADED", 6)
	H.eq(Summary(Last(0, FAILED)), Reason("NO_RECORD"))
	ApplyDone(0, 1, "SAVED", 6)
	H.eq(Summary(Last(0, FAILED)), Reason("BAD_STEP"))
	ApplyDone(4, 1, "WRITTEN", 6)
	H.len(H.notifs(4), 0, "an AI sender is refused silently")
	H.eq(Rev(), rev)
	H.eq(Rec(1).state, "PENDING_APPLY")
	H.clean()
end)

-- The UI undid its write after a timeout (review fix): UNDONE and the attempt token.
local function Attempt(pid, id, step, attempt)
	H.request(pid, { OnStart = "TX_ApplyDone", recordID = id, step = step, team = 6, attempt = attempt })
end

test("gameplay 10: WRITTEN then UNDONE (requests in order): applied back to 0, fields cleared, Apply possible again", function()
	Setup()
	Pass()
	PlayerConfigurations[1]:SetTeam(6)       -- the write, still seen when the slow WRITTEN is handled
	Attempt(0, 1, "WRITTEN", 1)
	H.eq(Rec(1).applied, 1)
	H.eq(Rec(1).appliedAttempt, 1)
	PlayerConfigurations[1]:SetTeam(0)       -- the UI timed out and undid it
	local rev, before = Rev(), Count()
	Attempt(0, 1, "UNDONE", 1)
	local rec = Rec(1)
	H.eq(rec.state, "PENDING_APPLY")
	H.eq(rec.applied, 0)
	H.isnil(rec.appliedTurn)
	H.isnil(rec.appliedBy)
	H.isnil(rec.appliedAttempt)
	H.eq(rec.undoneAttempt, 1)
	H.eq(Rev(), rev + 1)
	H.eq(Count(), before, "no notification")
	H.ok(H.hasLine("[TX][T1][Apply] rec=1 UNDONE attempt 1 by P0: applied 1 -> 0, the host may apply again"))
	-- the next turn start does not mark it applied again (gameplay reads the old team)
	H.endTurn()
	H.eq(Rec(1).applied, 0)
	-- the next attempt goes through
	PlayerConfigurations[1]:SetTeam(6)
	Attempt(0, 1, "WRITTEN", 2)
	H.eq(Rec(1).applied, 1)
	H.eq(Rec(1).appliedAttempt, 2)
	H.clean()
end)

test("gameplay 10: UNDONE then a late WRITTEN of that attempt: refused (ATTEMPT_UNDONE), no REQUEST_FAILED; a newer attempt is accepted", function()
	Setup()
	Pass()
	Attempt(0, 1, "UNDONE", 1)
	H.eq(Rec(1).applied, 0)
	H.eq(Rec(1).undoneAttempt, 1)
	PlayerConfigurations[1]:SetTeam(6)       -- gameplay would even see the team (late, lagging read)
	local rev, before = Rev(), Count()
	Attempt(0, 1, "WRITTEN", 1)
	H.eq(Rec(1).applied, 0, "the undone attempt never sets applied")
	H.eq(Rev(), rev)
	H.eq(Count(), before, "the sender already knows: no REQUEST_FAILED")
	H.ok(H.hasLine("[TX][T1][Apply] refused WRITTEN from P0 rec=1 attempt 1: ATTEMPT_UNDONE (undone up to attempt 1)"))
	Attempt(0, 1, "WRITTEN", nil)           -- no token reads as attempt 0: refused too
	H.eq(Rec(1).applied, 0)
	Attempt(0, 1, "WRITTEN", 2)
	H.eq(Rec(1).applied, 1)
	-- an UNDONE of an older attempt does not undo the newer one
	Attempt(0, 1, "UNDONE", 1)
	H.eq(Rec(1).applied, 1)
	H.eq(Rec(1).appliedAttempt, 2)
	H.clean()
end)

test("gameplay 10: UNDONE is re-validated: AI sender, no record, not PENDING_APPLY", function()
	Setup()
	Pass()
	PlayerConfigurations[1]:SetTeam(6)
	Attempt(0, 1, "WRITTEN", 1)
	local rev = Rev()
	Attempt(4, 1, "UNDONE", 1)
	H.len(H.notifs(4), 0, "an AI sender is refused silently")
	H.eq(Rec(1).applied, 1)
	Attempt(0, 9, "UNDONE", 1)
	H.eq(Summary(Last(0, FAILED)), Reason("NO_RECORD"))
	H.eq(Rev(), rev)
	FAKE_TX.Reload()
	H.markBody()
	ApplyDone(0, 1, "RELOADED", 6)
	H.eq(Rec(1).state, "DONE")
	rev = Rev()
	Attempt(0, 1, "UNDONE", 1)
	H.eq(Summary(Last(0, FAILED)), Reason("NOT_PENDING"))
	H.eq(Rec(1).applied, 1)
	H.eq(Rev(), rev)
	H.clean()
end)

-- ===========================================================================
-- Turn-start pipeline (PLAN II.8 "OnGameTurnStarted")
-- ===========================================================================
test("turn: the new team ID is taken before the apply: a new ID at the next turn start, KICK_PASSED goes on", function()
	Setup()
	Pass()
	H.team(30, 6)   -- an empty slot now holds team 6 (only a test setup can do this)
	local before = Count()
	H.endTurn()
	H.eq(Rec(1).newTeamID, 7)
	H.eq(Rec(1).state, "PENDING_APPLY")
	H.deq(Pids(PASSED, before), HUMANS)
	H.ok(H.hasLine("[TX][T2][Turn] rec=1 newTeam taken before the apply; now newTeam=7"))
	H.clean()
end)

test("turn: gameplay already reads newTeamID with applied 0 (WRITTEN lost): marked applied by -1", function()
	Setup()
	Pass()
	PlayerConfigurations[1]:SetTeam(6)
	H.endTurn()
	local rec = Rec(1)
	H.eq(rec.applied, 1)
	H.eq(rec.appliedBy, -1)
	H.eq(rec.appliedTurn, 2)
	H.ok(H.hasLine("[TX][T2][Turn] rec=1 gameplay already reads newTeam=6 for P1; marked applied"))
	H.clean()
end)

test("turn: a stored PASSED record (error between the two steps) is finished and announced", function()
	FAKE.dofile("tests/offline/lib/fake_txworld.lua")
	FAKE_TX.World()
	Game:SetProperty("TX_Store", {
		schema = 1, nextID = 2, lastTurn = 1, ids = { 1 },
		recs = { r1 = { id = 1, teamID = 0, proposerID = 0, targetID = 1,
			voters = { { pid = 0, v = "YES" }, { pid = 2, v = "YES" } },
			openedTurn = 1, expiresTurn = 6, state = "PASSED", closedTurn = 1 } },
	})
	H.load(GAMEPLAY)
	H.len(H.lines("loaded records=1", true), 1)
	H.endTurn()
	H.eq(Rec(1).state, "PENDING_APPLY")
	H.eq(Rec(1).newTeamID, 6)
	H.deq(Pids(PASSED), HUMANS, "KICK_PASSED once each, no REMIND_APPLY copy in the same turn")
	H.clean()
end)

test("turn: two teams' records are handled in record-id order in one turn start", function()
	Setup()
	Propose(0, 1)                 -- rec 1, team 0, open
	H.human(4, true)
	Propose(3, 4)                 -- rec 2, team 1: P4 is human now, so a team of 2 dissolves at once
	H.eq(Rec(2).state, "PENDING_APPLY")
	local before = Count()
	H.endTurn()
	-- rec 1 reminds P2 first, then rec 2 reminds everybody
	local got = {}
	for i = before + 1, #FAKE.notifications do
		local n = FAKE.notifications[i]
		got[#got + 1] = n.data.TX_RecordID .. ":" .. n.pid
	end
	H.deq(got, { "1:2", "2:0", "2:1", "2:2", "2:3", "2:4", "2:5" })
	H.clean()
end)

-- ===========================================================================
-- Notifications: labels, PROBE fallback, queue
-- ===========================================================================
test("notify: a recipient who has not met the target gets the unmet label", function()
	Setup()
	FAKE.PairSet(FAKE.diplo.met, 5, 1, false)
	FAKE.PairSet(FAKE.diplo.met, 1, 5, false)
	Pass()
	H.eq(Summary(Last(5, PASSED)), "an unmet player was voted off their team (soft kick). It takes effect once the host applies it and the game is saved and reloaded.")
	H.eq(Summary(Last(3, PASSED)), Label(1) .. " was voted off their team (soft kick). It takes effect once the host applies it and the game is saved and reloaded.")
	H.eq(Summary(Last(1, PASSED)), Label(1) .. " was voted off their team (soft kick). It takes effect once the host applies it and the game is saved and reloaded.", "own label, no HasMet check")
	H.clean()
end)

test("notify: PROBE config reads in gameplay are logged; a failing read falls back to the generic label", function()
	Setup()
	PlayerConfigurations[1].GetLeaderName = function() error("attempt to call method 'GetLeaderName' (a nil value)") end
	Propose(0, 1)
	H.eq(Summary(Last(2, VOTE)), Label(0) .. " wants to kick a teammate off your team (soft kick). Vote within # turns.")
	H.len(H.lines("[TX][T1][Notify] PROBE G PlayerConfigurations:GetLeaderName ok -> string LOC_LEADER_FAKE_0_NAME"), 1)
	H.len(H.lines("[TX][T1][Notify] PROBE G PlayerConfigurations:GetLeaderName FAILED: "), 1)
	H.len(H.lines("PROBE G PlayerConfigurations:GetCivilizationShortDescription ok -> string"), 1, "logged once per outcome")
	-- the next turn's reminder logs at level 3 only (not shown at LOG_LEVEL 2)
	H.endTurn()
	H.len(H.lines("PROBE G PlayerConfigurations:GetLeaderName FAILED"), 1)
	H.eq(Summary(Last(2, VOTE)), Label(0) .. " wants to kick a teammate off your team (soft kick). Vote within # turns.")
	H.clean()
end)

test("notify: queue skips non-humans, replaces a same-batch duplicate, and Flush sends in order", function()
	Setup()
	H.markBody()
	TX_Notify.Queue(2, VOTE, { "a", "b", 3, "m" }, 7)
	TX_Notify.Queue(4, VOTE, { "a", "b", 3, "m" }, 7)       -- AI: skipped
	TX_Notify.Queue(0, PASSED, { "x", "m" }, 7)
	TX_Notify.Queue(2, VOTE, { "c", "d", 1, "m" }, 7)       -- replaces the first, keeps its place
	TX_Notify.Queue(2, FAILED, { "r" })                 -- no record: never coalesced
	TX_Notify.Queue(2, FAILED, { "r" })
	H.eq(TX_Notify.Count(), 4)
	TX_Notify.Flush()
	H.eq(TX_Notify.Count(), 0)
	local got = {}
	for _, n in ipairs(FAKE.notifications) do
		got[#got + 1] = n.pid .. ":" .. n.typeName .. ":" .. tostring(n.data.TX_RecordID)
	end
	H.deq(got, { "2:" .. VOTE .. ":7", "0:" .. PASSED .. ":7", "2:" .. FAILED .. ":nil", "2:" .. FAILED .. ":nil" })
	H.eq(Summary(FAKE.notifications[1]), "c wants to kick d off your team (m). Vote within 1 turn.")
	TX_Notify.Queue(2, VOTE, { "a", "b", 3, "m" }, 7)
	TX_Notify.Discard()
	TX_Notify.Flush()
	H.eq(#FAKE.notifications, 4, "discarded entries are never sent")
	H.clean()
end)

test("notify: VoteRequired never goes to the proposer or the target", function()
	Setup()
	Propose(0, 1)
	local rec = Rec(1)
	H.markBody()
	TX_Notify.VoteRequired(rec, 0, 1)
	TX_Notify.VoteRequired(rec, 1, 1)
	TX_Notify.VoteRequired(rec, 3, 1)   -- not a voter: nothing
	H.eq(TX_Notify.Count(), 0)
	H.len(H.errorLines(), 2, "a refused recipient is a mod error")
	TX_Notify.Discard()
end, { allowErrors = true })

-- ===========================================================================
-- Store failures
-- ===========================================================================
test("store: a failed commit announces nothing", function()
	Setup()
	local orig = Game.SetProperty
	Game.SetProperty = function(self, k, v)
		if k == "TX_Store" then
			error("disk full")
		end
		return orig(self, k, v)
	end
	Propose(0, 1)
	Game.SetProperty = orig
	H.eq(Count(), 0, "no VOTE_REQUIRED for a vote that was not saved")
	H.isnil(Store())
	H.ok(H.hasLine("[TX][T1][Votes] ERROR commit failed; queued notifications dropped"))
	-- the next request works
	Propose(0, 1)
	H.eq(Rec(1).state, "OPEN")
	H.deq(Pids(), { 2 })
end, { allowErrors = true })

test("store: an unreadable store: the request is dropped, nothing written or sent", function()
	Setup()
	Propose(0, 1)
	local rev, before = Rev(), Count()
	local orig = Game.GetProperty
	Game.GetProperty = function(self, k)
		if k == "TX_Store" then
			error("read error")
		end
		return orig(self, k)
	end
	Vote(2, 1, "YES")
	H.endTurn()
	Game.GetProperty = orig
	H.eq(Rev(), rev)
	H.eq(Count(), before)
	H.eq(Rec(1).state, "OPEN")
	H.ok(H.hasLine("[TX][T1][Votes] ERROR vote: the store could not be read; nothing done"))
	H.ok(H.hasLine("[TX][T2][Turn] ERROR turn start: the store could not be read; nothing done"))
end, { allowErrors = true })

-- ===========================================================================
-- 11. MP hygiene
-- ===========================================================================
-- One scripted game from scratch: returns the stored TX_Store and the list of
-- notifications sent ("pid:type:record:summary").
local function Scenario()
	for _, k in ipairs(FAKE.SortedKeys(FAKE.props)) do
		FAKE.props[k] = nil
	end
	FAKE.notifications = {}
	FAKE.nextNotifID = 1
	FAKE.teamSets = {}
	H.reload({}, FAKE_TX.GLOBALS)
	FAKE_TX.World()
	FAKE.dofile(GAMEPLAY)
	Propose(0, 1)
	Vote(2, 1, "NO")
	Propose(0, 1)
	H.endTurn()
	Vote(2, 2, "YES")                -- rec 2 passes: newTeam 6
	Propose(3, 4)                    -- rec 3, team of 2: newTeam 7
	PlayerConfigurations[1]:SetTeam(6)
	ApplyDone(0, 2, "WRITTEN", 6)
	H.turns(2)
	Propose(5, 0)                    -- refused: other team
	Victory(5, 2)
	H.endTurn()
	local sent = {}
	for _, n in ipairs(FAKE.notifications) do
		sent[#sent + 1] = n.pid .. ":" .. n.typeName .. ":" .. tostring(n.data.TX_RecordID) .. ":" .. tostring(Summary(n))
	end
	return FAKE.DeepCopy(Store()), sent
end

test("gameplay 11: MP hygiene: two identical runs give the same TX_Store and notifications; no RNG, no local player, no storage violation", function()
	FAKE.dofile("tests/offline/lib/fake_txworld.lua")
	local s1, n1 = Scenario()
	local s2, n2 = Scenario()
	H.deq(s2, s1, "same store")
	H.deq(n2, n1, "same notifications")
	H.eq(s1.recs.r2.state, "PENDING_APPLY", "applied before the victory: kept")
	H.eq(s1.recs.r2.applied, 1)
	H.eq(s1.recs.r3.newTeamID, 7)
	H.eq(s1.recs.r3.state, "CANCELLED", "not applied at the victory")
	H.eq(s1.recs.r3.reason, "VICTORY")
	H.eq(s1.victoryTeam, 2)
	H.len(FAKE.rngCalls, 0, "no Game.GetRandNum")
	H.len(FAKE.forbidden, 0, "no math.random, no Game.GetLocalPlayer")
	H.len(FAKE.propViolations, 0)
	H.clean()
end)

-- ===========================================================================
-- 12. History trim
-- ===========================================================================
test("gameplay 12: HISTORY_MAX trim at the turn start keeps the newest closed records and every active one", function()
	Setup()
	TX_Config.HISTORY_MAX = 2
	for id = 1, 4 do
		Propose(0, 1)
		Vote(2, id, "NO")
	end
	Propose(0, 1)                  -- rec 5, open
	H.deq(Store().ids, { 1, 2, 3, 4, 5 })
	H.endTurn()
	H.deq(Store().ids, { 3, 4, 5 })
	H.isnil(Rec(1))
	H.eq(Rec(5).state, "OPEN")
	H.eq(Store().nextID, 6, "ids are never reused")
	Vote(2, 5, "NO")
	Propose(0, 1)
	H.eq(Rec(6).state, "OPEN")
	H.clean()
end)

-- ===========================================================================
-- Kick modes (DEC 2026-10-04; PLAN Part II notes "Kick modes"). The fake
-- diplomacy of lib/fake_txworld.lua models AL3 / AL3b (test assumptions; the
-- kicked-player-declares direction is PROVISIONAL, TX_Dev Session 3c).
-- ===========================================================================
local HARD_N = "NOTIFICATION_TX_HARD_KICK_DONE"

-- Kick P1 off team 0 in the given mode up to DONE: the ex-teammates keep the
-- timeless alliance (FAKE_TX.AllyTeam before the split); voters say YES; the
-- host's UI writes the config team; save and load; P3's UI reports RELOADED.
-- opts.voters (default { 2 }), opts.beforeReloaded (called after the load).
-- Returns the notification count before RELOADED.
local function KickToDone(mode, opts)
	opts = opts or {}
	FAKE_TX.AllyTeam(0)
	Propose(0, 1, mode)
	for _, v in ipairs(opts.voters or { 2 }) do
		Vote(v, 1, "YES")
	end
	local rec = Rec(1)
	H.eq(rec.state, "PENDING_APPLY", "the kick passed")
	PlayerConfigurations[1]:SetTeam(rec.newTeamID)
	ApplyDone(2, 1, "WRITTEN", rec.newTeamID)
	H.eq(Rec(1).applied, 1)
	FAKE_TX.Reload()
	H.markBody()
	if opts.beforeReloaded ~= nil then
		opts.beforeReloaded()
	end
	local before = Count()
	ApplyDone(3, 1, "RELOADED", rec.newTeamID)
	H.eq(Rec(1).state, "DONE")
	return before
end

local function Outcome(key)
	return FAKE_TEXT["LOC_TX_HARD_OUTCOME_" .. key]
end

test("modes 1: TX_Propose mode is validated in gameplay: missing, unknown, lower case, a number: BAD_MODE, nothing stored; SOFT and HARD stored", function()
	Setup()
	local function Refused(params, label)
		local rev, before = Rev(), Count()
		params.OnStart = "TX_Propose"
		H.request(0, params)
		H.eq(Rev(), rev, label .. ": nothing stored")
		H.deq(Pids(nil, before), { 0 }, label .. ": REQUEST_FAILED to the sender only")
		H.eq(Summary(Last(0, FAILED)), Reason("BAD_MODE"), label)
	end
	Refused({ targetID = 1 }, "missing mode")
	Refused({ targetID = 1, mode = "MEDIUM" }, "unknown mode")
	Refused({ targetID = 1, mode = "hard" }, "lower case")
	Refused({ targetID = 1, mode = 1 }, "number mode")
	H.ok(H.hasLine("[TX][T1][Votes] refused propose from P0: BAD_MODE"))
	H.isnil(Store(), "no record was ever stored")
	-- another reason comes first: the mode is checked last
	Propose(0, 0, "MEDIUM")
	H.eq(Summary(Last(0, FAILED)), Reason("TARGET_SELF"))
	Propose(0, 1, "HARD")
	H.eq(Rec(1).mode, "HARD")
	H.ok(H.hasLine("[TX][T1][Votes] propose from P0 target=1 mode=HARD"))
	H.ok(H.hasLine("rec=1 opened team=0 proposer=P0 target=P1 mode=HARD voters=[P0=YES P2=PENDING]"))
	H.ok(string.find(Summary(Last(2, VOTE)), "(hard kick)", 1, true) ~= nil, "the voter's notification names the mode")
	Vote(2, 1, "NO")
	Propose(3, 4, "SOFT")
	H.eq(Rec(2).mode, "SOFT")
	H.eq(Summary(Last(3, PASSED)), Label(4) .. " was voted off their team (soft kick). It takes effect once the host applies it and the game is saved and reloaded.")
	Propose(0, 1, "HARD")
	Vote(2, 3, "YES")
	H.eq(Summary(Last(0, PASSED)), Label(1) .. " was voted off their team (hard kick). It takes effect once the host applies it and the game is saved and reloaded.")
	H.clean()
end)

test("modes 2: HARD after the reload: P1 declares war on P0 (the team war covers P2), makes peace; grievances on P1; HARD_KICK_DONE to all; hardDone 1", function()
	Setup()
	local before = KickToDone("HARD")
	local rec = Rec(1)
	H.eq(rec.mode, "HARD")
	H.eq(rec.hardDone, 1)
	local wars = FAKE_TX.Calls("DeclareWarOn")
	H.len(wars, 1, "one declaration: the war is team wide (fake model)")
	H.eq(wars[1].a, 1, "the KICKED player declares")
	H.eq(wars[1].b, 0, "on the lowest keeper first")
	H.eq(wars[1].warType, WarTypes.FORMAL_WAR)
	H.eq(wars[1].third, true, "AL3b: the third argument must be true on an ally")
	H.eq(wars[1].context, "G", "in gameplay (synced handler)")
	local peace = FAKE_TX.Calls("MakePeaceWith")
	H.len(peace, 1)
	H.eq(peace[1].a, 1)
	H.eq(peace[1].b, 0)
	H.eq(peace[1].v, true)
	for _, k in ipairs({ 0, 2 }) do
		H.eq(FAKE.IsAtWar(1, k), false, "peace with P" .. k)
		H.eq(FAKE_TX.DiploState(1, k), "UNFRIENDLY", "no longer allied with P" .. k)
		H.eq(FAKE_TX.Grievance(k, 1), 100, "P" .. k .. " holds the grievances against the kicked player")
		H.eq(FAKE_TX.Grievance(1, k), 0, "the kicked player holds none")
	end
	for _, l in ipairs({
		"[Apply] AfterReload rec=1 target=P1 mode=HARD: war then peace (PROVISIONAL, Session 3c)",
		"[Apply] HARD rec=1: P1 ends the alliance with its old team 0: keepers [P0,P2]",
		"[Apply] HARD rec=1 war P1->P0: declared, at war=yes",
		"[Apply] HARD rec=1 war P1->P2: already at war, no declaration",
		"[Apply] HARD rec=1 peace P1->P0: made, at war=no",
		"[Apply] HARD rec=1 peace P1->P2: not at war, no call",
		"[Apply] HARD rec=1 final P1 vs P0: war step=yes at war=no",
		"[Apply] HARD rec=1 final P1 vs P2: war step=yes at war=no",
		"[Apply] HARD rec=1 done: the alliance of P1 with team 0 is ended (war then peace)",
		"[Apply] rec=1 hardDone=1",
	}) do
		H.len(H.lines(l), 1, l)
	end
	-- the news: HARD_KICK_DONE instead of KICK_DONE
	H.deq(Pids(nil, before), HUMANS, "one notification per living human")
	H.deq(Pids(HARD_N, before), HUMANS)
	H.eq(Message(Last(0, HARD_N)), "Hard kick")
	H.eq(Summary(Last(0, HARD_N)), Label(1) .. " was hard kicked from their team. " .. Outcome("OK"))
	H.eq(Summary(Last(0, HARD_N)), Label(1) .. " was hard kicked from their team. The alliance with their old team has been ended. They declared war and made peace at once, so the grievances fall on them.")
	H.eq(Last(1, HARD_N).data.TX_RecordID, 1)
	H.eq(H.prop("TX_Store").recs.r1.hardDone, 1, "stored")
	H.clean()
end)

test("modes 3: HARD runs once: two more RELOADED reports, another load and its report, later turns: no new war, peace or notification", function()
	Setup()
	KickToDone("HARD")
	local calls, count, rev = #FAKE_TX.diploCalls, Count(), Rev()
	ApplyDone(0, 1, "RELOADED", 6)
	ApplyDone(2, 1, "RELOADED", 6)
	FAKE_TX.Reload()
	ApplyDone(0, 1, "RELOADED", 6)
	ApplyDone(3, 1, "RELOADED", 6)
	H.endTurn()
	H.endTurn()
	H.eq(#FAKE_TX.diploCalls, calls, "no diplomacy call after the first run")
	H.eq(Count(), count, "no notification")
	H.eq(Rev(), rev + 2, "only the two turn starts wrote")
	H.eq(Rec(1).hardDone, 1)
	H.len(H.lines("AfterReload rec=1"), 1, "the hook ran once")
	H.len(H.lines("HARD rec=1 done"), 1)
	H.clean()
end)

test("modes 4: multi-keeper (P5 joins team 0, per-pair wars): war on P0, P2, P5 in pid order, then peace in pid order", function()
	Setup()
	FAKE.teamWars = false
	H.team(5, 0)
	KickToDone("HARD", { voters = { 2, 5 } })
	local order = {}
	for _, c in ipairs(FAKE_TX.diploCalls) do
		order[#order + 1] = c.fn .. " " .. c.a .. ">" .. c.b
	end
	H.deq(order, { "DeclareWarOn 1>0", "DeclareWarOn 1>2", "DeclareWarOn 1>5",
		"MakePeaceWith 1>0", "MakePeaceWith 1>2", "MakePeaceWith 1>5" })
	H.ok(H.hasLine("HARD rec=1: P1 ends the alliance with its old team 0: keepers [P0,P2,P5]"))
	for _, k in ipairs({ 0, 2, 5 }) do
		H.eq(FAKE.IsAtWar(1, k), false)
		H.eq(FAKE_TX.DiploState(1, k), "UNFRIENDLY")
		H.eq(FAKE_TX.Grievance(k, 1), 100)
	end
	H.eq(Rec(1).hardDone, 1)
	H.clean()
end)

test("modes 5: a failed step is an ERROR and is left as it is: one call per keeper and step, no retry; hardDone 0; the failed outcome is announced", function()
	Setup()
	FAKE.teamWars = false
	local before = KickToDone("HARD", { beforeReloaded = function()
		FAKE_TX.diploFail["declare:1>0"] = "error"
		FAKE_TX.diploFail["peace:1>2"] = "noop"
	end })
	H.len(FAKE_TX.Calls("DeclareWarOn"), 2, "one declaration per keeper")
	H.len(FAKE_TX.Calls("MakePeaceWith"), 1, "peace only with the keeper at war, once")
	H.eq(FAKE.IsAtWar(1, 0), false)
	H.eq(FAKE_TX.DiploState(1, 0), "ALLIED", "the war on P0 never started")
	H.eq(FAKE.IsAtWar(1, 2), true, "the failed peace is left as it is")
	H.len(H.lines("[Apply] ERROR HARD rec=1 war P1->P0: DeclareWarOn failed: "), 1)
	H.len(H.lines("[Apply] ERROR HARD rec=1 peace P1->P2: MakePeaceWith ran but at war=yes"), 1)
	H.len(H.lines("[Apply] HARD rec=1 peace P1->P0: not at war, no call"), 1)
	H.len(H.lines("[Apply] HARD rec=1 final P1 vs P0: war step=no at war=no"), 1)
	H.len(H.lines("[Apply] HARD rec=1 final P1 vs P2: war step=yes at war=yes"), 1)
	H.len(H.lines("[Apply] ERROR HARD rec=1 FAILED: P1 may still be allied with or at war with team 0; left as it is (no retry)"), 1)
	H.eq(Rec(1).state, "DONE")
	H.eq(Rec(1).hardDone, 0)
	H.deq(Pids(HARD_N, before), HUMANS)
	H.eq(Summary(Last(0, HARD_N)), Label(1) .. " was hard kicked from their team. " .. Outcome("FAILED"))
	H.len(H.notifs(nil, DONE), 0, "no soft KICK_DONE")
	-- nothing tries again
	local calls = #FAKE_TX.diploCalls
	ApplyDone(0, 1, "RELOADED", 6)
	H.endTurn()
	FAKE_TX.Reload()
	ApplyDone(0, 1, "RELOADED", 6)
	H.eq(#FAKE_TX.diploCalls, calls)
	H.eq(Rec(1).hardDone, 0)
end, { allowErrors = true })

test("modes 5b: the hook itself throws: ERROR line, hardDone 0, the failed outcome; DONE stays", function()
	Setup()
	KickToDone("HARD", { beforeReloaded = function()
		TX_Apply.HardKick = function() error("boom") end
	end })
	H.ok(H.hasLine("[Apply] ERROR TX_Apply.AfterReload failed: "))
	H.eq(Rec(1).state, "DONE")
	H.eq(Rec(1).hardDone, 0)
	H.eq(Summary(Last(0, HARD_N)), Label(1) .. " was hard kicked from their team. " .. Outcome("FAILED"))
	H.len(FAKE_TX.diploCalls, 0)
end, { allowErrors = true })

test("modes 6: SOFT does nothing extra: no diplomacy call, KICK_DONE says they stay allied, no hardDone", function()
	Setup()
	local before = KickToDone("SOFT")
	H.len(FAKE_TX.diploCalls, 0)
	H.eq(FAKE_TX.DiploState(1, 0), "ALLIED", "still allied")
	H.eq(FAKE_TX.DiploState(1, 2), "ALLIED")
	H.isnil(Rec(1).hardDone)
	H.deq(Pids(nil, before), HUMANS)
	H.deq(Pids(DONE, before), HUMANS)
	H.eq(Summary(Last(0, DONE)), Label(1) .. " now plays alone and stays allied with their old team.")
	H.ok(H.hasLine("[Apply] AfterReload rec=1 target=P1 mode=SOFT: no war step, the ex-teammates stay allied (O2 vision: known limitation)"))
	H.clean()
end)

test("modes 7: HARD_KICK_ENABLED = false at the reload: a stored HARD record ends as a soft kick (no call, KICK_DONE, no hardDone)", function()
	Setup()
	local before = KickToDone("HARD", { beforeReloaded = function() TX_Config.HARD_KICK_ENABLED = false end })
	H.len(FAKE_TX.diploCalls, 0)
	H.eq(FAKE_TX.DiploState(1, 0), "ALLIED")
	H.isnil(Rec(1).hardDone)
	H.eq(Rec(1).mode, "HARD", "the record keeps its mode")
	H.deq(Pids(DONE, before), HUMANS)
	H.len(H.notifs(nil, HARD_N), 0)
	H.ok(H.hasLine("[Apply] AfterReload rec=1 target=P1 mode=HARD: HARD_KICK_ENABLED is false; nothing done, they stay allied"))
	-- and new HARD proposals are refused
	Propose(0, 2, "HARD")
	H.eq(Summary(Last(0, FAILED)), Reason("BAD_MODE"))
	H.clean()
end)

test("modes 8: MP hygiene: two identical HARD runs give the same store, calls and notifications", function()
	FAKE.dofile("tests/offline/lib/fake_txworld.lua")
	local function Run()
		for _, k in ipairs(FAKE.SortedKeys(FAKE.props)) do
			FAKE.props[k] = nil
		end
		FAKE.notifications = {}
		FAKE.nextNotifID = 1
		FAKE.teamSets = {}
		H.reload({}, FAKE_TX.GLOBALS)
		FAKE_TX.World()
		FAKE.dofile(GAMEPLAY)
		KickToDone("HARD")
		local calls = {}
		for _, c in ipairs(FAKE_TX.diploCalls) do
			calls[#calls + 1] = c.fn .. " " .. c.a .. ">" .. c.b
		end
		local sent = {}
		for _, n in ipairs(FAKE.notifications) do
			sent[#sent + 1] = n.pid .. ":" .. n.typeName .. ":" .. tostring(Summary(n))
		end
		return FAKE.DeepCopy(Store()), calls, sent
	end
	local s1, c1, n1 = Run()
	local s2, c2, n2 = Run()
	H.deq(s2, s1)
	H.deq(c2, c1)
	H.deq(n2, n1)
	H.len(FAKE.rngCalls, 0)
	H.len(FAKE.forbidden, 0)
	H.len(FAKE.propViolations, 0)
end)
