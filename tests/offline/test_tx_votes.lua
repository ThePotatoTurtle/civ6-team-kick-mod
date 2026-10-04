-- Tests of TX/Scripts/TX_Votes.lua (PLAN II.14 "test_tx_votes.lua"; TP 2.7
-- phase 1 and the TP 2.6 rows). TX_Votes is pure, so everything runs on plain
-- tables: a store from TX_Store.Fresh and worlds from TX_Votes.MakeWorld.
--
-- Standard world (as FAKE_TX.World): P0, P1, P2 human on team 0; P3 human and
-- P4 AI on team 1; P5 human solo (team 2); city-state 6 (team 3); slots 7..61
-- empty (team -1); Free Cities 62 (team 4); Barbarians 63 (team 5). First
-- free team ID: 6.

local function Load()
	include("TX_Votes")
end

-- over[pid] = { field = value } overrides (a new pid adds a slot).
local function Slots(over)
	over = over or {}
	local s = {
		{ pid = 0, team = 0, alive = 1, major = 1, human = 1 },
		{ pid = 1, team = 0, alive = 1, major = 1, human = 1 },
		{ pid = 2, team = 0, alive = 1, major = 1, human = 1 },
		{ pid = 3, team = 1, alive = 1, major = 1, human = 1 },
		{ pid = 4, team = 1, alive = 1, major = 1, human = 0 },
		{ pid = 5, team = 2, alive = 1, major = 1, human = 1 },
		{ pid = 6, team = 3, alive = 1, major = 0, human = 0 },
	}
	for i = 7, 61 do
		s[#s + 1] = { pid = i, team = -1, alive = 0, major = 0, human = 0 }
	end
	s[#s + 1] = { pid = 62, team = 4, alive = 1, major = 0, human = 0 }
	s[#s + 1] = { pid = 63, team = 5, alive = 1, major = 0, human = 0 }
	for _, slot in ipairs(s) do
		local o = over[slot.pid]
		if o ~= nil then
			for _, k in ipairs(FAKE.SortedKeys(o)) do
				slot[k] = o[k]
			end
		end
	end
	return s
end

local function World(turn, over)
	return TX_Votes.MakeWorld(turn or 42, Slots(over))
end

-- A human major on team 0 in slot 7 (a team of four humans).
local FOUR = { [7] = { team = 0, alive = 1, major = 1, human = 1 } }

local function Fresh(turn)
	return TX_Store.Fresh(turn or 42)
end

local function Codes(list)
	return table.concat(list or {}, ",")
end

local function VotersText(rec)
	local parts = {}
	for _, e in ipairs(rec.voters) do
		parts[#parts + 1] = e.pid .. "=" .. e.v
	end
	return table.concat(parts, " ")
end

local function KnownCodes(codes)
	local known = {}
	for _, c in ipairs(TX_Votes.ALL_REASON_CODES) do
		known[c] = true
	end
	for _, c in ipairs(codes) do
		H.ok(known[c], "code " .. tostring(c) .. " is in ALL_REASON_CODES")
	end
end

local function EventsText(events)
	local parts = {}
	for _, e in ipairs(events) do
		parts[#parts + 1] = e.kind .. ":" .. e.id .. ":" .. e.pid .. (e.reason and (":" .. e.reason) or "")
	end
	return table.concat(parts, " ")
end

-- ---------------------------------------------------------------------------
test("votes: reason codes are 23 (22 + ATTEMPT_UNDONE), unique, and each has its text", function()
	Load()
	H.len(TX_Votes.ALL_REASON_CODES, 23)
	local seen = {}
	for _, c in ipairs(TX_Votes.ALL_REASON_CODES) do
		H.isnil(seen[c], "duplicate code " .. c)
		seen[c] = true
		H.notnil(FAKE_TEXT["LOC_TX_REASON_" .. c], "LOC_TX_REASON_" .. c)
	end
end)

test("votes: MakeWorld sorts the slots, normalizes flags and keeps the world pure", function()
	Load()
	local w = TX_Votes.MakeWorld(7, {
		{ pid = 2, team = 0, alive = true, major = true, human = false },
		{ pid = 0, team = 0, alive = 1, major = 1, human = 1 },
		{ pid = "x" },
		{ pid = 1 },
	})
	H.eq(w.turn, 7)
	H.len(w.slots, 3)
	H.eq(w.slots[1].pid, 0)
	H.eq(w.slots[2].pid, 1)
	H.eq(w.slots[2].team, -1, "missing team is -1")
	H.eq(w.slots[3].alive, 1)
	H.eq(w.slots[3].human, 0)
	H.eq(w.byPid[2].major, 1)
	H.deq(TX_Votes.Members(w, 0), { 0, 2 })
	H.deq(TX_Votes.Members(w, -1), {})
	H.eq(TX_Votes.TeamOf(w, 99), -1)
end)

test("votes 1: Propose opens a record: voters are the human teammates but the target, proposer YES, expiry +5", function()
	Load()
	local store, w = Fresh(), World(42)
	local rec, codes = TX_Votes.Propose(store, w, 0, 1)
	H.eq(Codes(codes), "")
	H.eq(rec.id, 1)
	H.eq(rec.state, "OPEN")
	H.eq(rec.teamID, 0)
	H.eq(rec.proposerID, 0)
	H.eq(rec.targetID, 1)
	H.eq(VotersText(rec), "0=YES 2=PENDING")
	H.eq(rec.openedTurn, 42)
	H.eq(rec.expiresTurn, 47)
	H.isnil(rec.closedTurn)
	H.deq(store.ids, { 1 })
	H.eq(store.nextID, 2)
	H.eq(TX_Store.Get(store, 1), rec)
	H.eq(TX_Votes.ConfirmKind(w, 0, 1), "VOTE")
	-- ascending order whoever proposes
	local store2 = Fresh()
	local rec2 = TX_Votes.Propose(store2, World(42), 2, 0)
	H.eq(VotersText(rec2), "1=PENDING 2=YES")
	H.eq(TX_Votes.RoleOf(rec, 1), "TARGET")
	H.eq(TX_Votes.RoleOf(rec, 0), "PROPOSER")
	H.eq(TX_Votes.RoleOf(rec, 2), "VOTER")
	H.eq(TX_Votes.RoleOf(rec, 4, 1), "OTHER")
	H.eq(TX_Votes.RoleOf(rec, 9, 0), "TEAM")
	H.eq(TX_Votes.TurnsLeft(rec, 42), 5)
	H.eq(TX_Votes.TurnsLeft(rec, 50), 0)
end)

test("votes 2: one active record per team; another team may propose", function()
	Load()
	local store, w = Fresh(), World(42)
	TX_Votes.Propose(store, w, 0, 1)
	local rec, codes = TX_Votes.Propose(store, w, 2, 0)
	H.isnil(rec)
	H.eq(Codes(codes), "VOTE_OPEN")
	H.eq(Codes(TX_Votes.ProposeReasons(store, w, 0, 2)), "VOTE_OPEN")
	H.deq(store.ids, { 1 }, "nothing stored for a refused proposal")
	local rec3, codes3 = TX_Votes.Propose(store, w, 3, 4)
	H.eq(Codes(codes3), "")
	H.eq(rec3.id, 2)
	H.eq(rec3.teamID, 1)
	H.eq(TX_Votes.Active(store, 0).id, 1)
	H.eq(TX_Votes.Active(store, 1).id, 2)
	H.isnil(TX_Votes.Active(store, 2))
end)

test("votes 3: the target of the open vote gets TEAM_BUSY, never VOTE_OPEN", function()
	Load()
	local store, w = Fresh(), World(42)
	TX_Votes.Propose(store, w, 0, 1)
	H.eq(Codes(TX_Votes.ProposeReasons(store, w, 1, 2)), "TEAM_BUSY")
	H.eq(Codes(TX_Votes.ProposeReasons(store, w, 1, 0)), "TEAM_BUSY")
	local _, codes = TX_Votes.Propose(store, w, 1, 2)
	H.eq(Codes(codes), "TEAM_BUSY")
end)

test("votes 4: invalid proposals: NOT_HUMAN, NOT_ALIVE, TARGET_SELF, TARGET_INVALID, NOT_TEAMMATE", function()
	Load()
	local store = Fresh()
	local w = World(42)
	local function First(sender, target, world)
		local codes = TX_Votes.ProposeReasons(store, world or w, sender, target)
		KnownCodes(codes)
		return codes[1], codes
	end
	H.eq(First(4, 3), "NOT_HUMAN", "AI sender")
	H.eq(First(99, 0), "NOT_HUMAN", "missing sender")
	local _, all = First(99, 0)
	H.contains(all, "NOT_ALIVE")
	H.eq(First(0, 1, World(42, { [0] = { alive = 0 } })), "NOT_ALIVE")
	H.eq(First(0, 0), "TARGET_SELF")
	H.eq(First(0, 1, World(42, { [1] = { alive = 0 } })), "TARGET_INVALID", "dead target")
	H.eq(First(0, 6), "TARGET_INVALID", "city-state")
	H.eq(First(0, 62), "TARGET_INVALID", "Free Cities")
	H.eq(First(0, 63), "TARGET_INVALID", "Barbarians")
	H.eq(First(0, 99), "TARGET_INVALID", "missing slot")
	H.eq(First(0, 30), "TARGET_INVALID", "empty slot")
	H.eq(First(0, nil), "TARGET_INVALID", "no target")
	H.eq(First(0, 3), "NOT_TEAMMATE")
	H.eq(First(0, 5), "NOT_TEAMMATE")
	H.eq(First(5, 0), "NOT_TEAMMATE", "solo player")
	H.deq(store.ids, {})
end)

test("votes 5: unanimous YES passes, FinishPass gives PENDING_APPLY with the new team ID", function()
	Load()
	local store = Fresh()
	local rec = TX_Votes.Propose(store, World(42), 0, 1)
	local w = World(44)
	local r, codes = TX_Votes.Vote(store, w, 2, rec.id, "YES")
	H.eq(Codes(codes), "")
	H.eq(r, rec)
	H.eq(rec.state, "PASSED")
	H.eq(rec.closedTurn, 44)
	H.eq(TX_Votes.FinishPass(store, w, rec), "PENDING_APPLY")
	H.eq(rec.newTeamID, 6)
	H.eq(rec.applied, 0)
	H.eq(Codes(TX_Votes.ProposeReasons(store, w, 2, 0)), "APPLY_PENDING")
	H.eq(Codes(TX_Votes.ProposeReasons(store, w, 1, 0)), "APPLY_PENDING", "the target is told once it passed")
end)

test("votes 6: a single NO fails the vote at once; the other votes stay PENDING", function()
	Load()
	local store = Fresh()
	local rec = TX_Votes.Propose(store, World(42, FOUR), 0, 1)
	H.eq(VotersText(rec), "0=YES 2=PENDING 7=PENDING")
	TX_Votes.Vote(store, World(43, FOUR), 2, rec.id, "NO")
	H.eq(rec.state, "FAILED")
	H.eq(rec.reason, "NO_VOTE")
	H.eq(rec.closedTurn, 43)
	H.eq(VotersText(rec), "0=YES 2=NO 7=PENDING")
end)

test("votes 7: a new proposal against the same target right after FAILED is allowed", function()
	Load()
	local store, w = Fresh(), World(42)
	local rec = TX_Votes.Propose(store, w, 0, 1)
	TX_Votes.Vote(store, w, 2, rec.id, "NO")
	local rec2, codes = TX_Votes.Propose(store, w, 0, 1)
	H.eq(Codes(codes), "")
	H.eq(rec2.id, 2)
	H.eq(rec2.state, "OPEN")
	H.eq(rec.state, "FAILED")
end)

test("votes 8: expiry: OPEN at expiresTurn - 1, EXPIRED at expiresTurn, then a new proposal works", function()
	Load()
	local store = Fresh()
	local rec = TX_Votes.Propose(store, World(42), 0, 1)
	local ev = TX_Votes.TurnStart(store, World(46))
	H.eq(rec.state, "OPEN")
	H.eq(EventsText(ev), "REMIND_VOTE:1:2")
	ev = TX_Votes.TurnStart(store, World(47))
	H.eq(rec.state, "EXPIRED")
	H.eq(rec.closedTurn, 47)
	H.eq(EventsText(ev), "EXPIRED:1:1")
	H.eq(Codes(TX_Votes.VoteReasons(store, World(47), 2, rec.id, "YES")), "VOTE_CLOSED")
	local rec2, codes = TX_Votes.Propose(store, World(47), 0, 1)
	H.eq(Codes(codes), "")
	H.eq(rec2.id, 2)
	H.eq(EventsText(TX_Votes.TurnStart(store, World(48))), "REMIND_VOTE:2:2", "closed records send nothing")
end)

test("votes 9: vote reasons: NO_RECORD, VOTE_CLOSED, NOT_VOTER, ALREADY_VOTED, BAD_VOTE", function()
	Load()
	local over = { [7] = { team = 0, alive = 1, major = 1, human = 0 } }   -- AI teammate
	local store, w = Fresh(), World(42, over)
	local rec = TX_Votes.Propose(store, w, 0, 1)
	local function R(pid, id, vote)
		local codes = TX_Votes.VoteReasons(store, w, pid, id, vote)
		KnownCodes(codes)
		return Codes(codes)
	end
	H.eq(R(2, 99, "YES"), "NO_RECORD")
	H.eq(R(2, nil, "YES"), "NO_RECORD")
	H.eq(R(1, rec.id, "YES"), "NOT_VOTER", "the target")
	H.eq(R(7, rec.id, "YES"), "NOT_VOTER", "an AI teammate")
	H.eq(R(3, rec.id, "YES"), "NOT_VOTER", "another team")
	H.eq(R(0, rec.id, "YES"), "ALREADY_VOTED", "the proposer voted YES at the start")
	H.eq(R(2, rec.id, "MAYBE"), "BAD_VOTE")
	H.eq(R(2, rec.id, nil), "BAD_VOTE")
	H.eq(R(2, rec.id, "NO"), "")
	local r, codes = TX_Votes.Vote(store, w, 2, rec.id, "yes")
	H.isnil(r)
	H.eq(Codes(codes), "BAD_VOTE")
	H.eq(rec.state, "OPEN", "a refused vote changes nothing")
	TX_Votes.Vote(store, w, 2, rec.id, "NO")
	H.eq(R(2, rec.id, "YES"), "VOTE_CLOSED")
end)

test("votes 10: AI teammates abstain: AI_ONLY and DISSOLVE pass at once", function()
	Load()
	-- {P0 human, P1 AI, P2 target}
	local over = { [1] = { human = 0 } }
	local store, w = Fresh(), World(42, over)
	H.eq(TX_Votes.ConfirmKind(w, 0, 2), "AI_ONLY")
	local rec = TX_Votes.Propose(store, w, 0, 2)
	H.eq(rec.state, "PASSED")
	H.eq(rec.closedTurn, 42)
	H.eq(VotersText(rec), "0=YES")
	-- team of 2: P3 kicks P4 (AI)
	H.eq(TX_Votes.ConfirmKind(w, 3, 4), "DISSOLVE")
	local rec2 = TX_Votes.Propose(store, w, 3, 4)
	H.eq(rec2.state, "PASSED")
	-- {P0, P1 target, P2 AI}: the target is the only other human
	local over3 = { [2] = { human = 0 } }
	local store3, w3 = Fresh(), World(42, over3)
	H.eq(TX_Votes.ConfirmKind(w3, 0, 1), "AI_ONLY")
	local rec3 = TX_Votes.Propose(store3, w3, 0, 1)
	H.eq(rec3.state, "PASSED")
	H.eq(TX_Votes.FinishPass(store3, w3, rec3), "PENDING_APPLY")
	-- a team of 3 humans votes
	H.eq(TX_Votes.ConfirmKind(World(42), 0, 1), "VOTE")
	H.eq(TX_Votes.ConfirmKind(World(42, FOUR), 0, 1), "VOTE")
end)

test("votes 11: NewTeamID: Session 1 layout gives 10; -1 ignored; dead slots count; reserved IDs; none above 63", function()
	Load()
	-- Session 1 (SR:132, LOG:956-966): 0,1 team 0; 2,3 team 1; 4..9 city-states teams 2..7;
	-- 10..61 empty (-1); 62 team 8; 63 team 9.
	local s = {
		{ pid = 0, team = 0, alive = 1, major = 1, human = 1 },
		{ pid = 1, team = 0, alive = 1, major = 1, human = 1 },
		{ pid = 2, team = 1, alive = 1, major = 1, human = 1 },
		{ pid = 3, team = 1, alive = 1, major = 1, human = 0 },
	}
	for i = 4, 9 do
		s[#s + 1] = { pid = i, team = i - 2, alive = 1, major = 0, human = 0 }
	end
	for i = 10, 61 do
		s[#s + 1] = { pid = i, team = -1, alive = 0, major = 0, human = 0 }
	end
	s[#s + 1] = { pid = 62, team = 8, alive = 1, major = 0, human = 0 }
	s[#s + 1] = { pid = 63, team = 9, alive = 1, major = 0, human = 0 }
	local store = Fresh(3)
	H.eq(TX_Votes.NewTeamID(TX_Votes.MakeWorld(3, s), store, nil), 10)
	-- a dead player still holds its team
	s[11] = { pid = 10, team = 10, alive = 0, major = 1, human = 1 }
	H.eq(TX_Votes.NewTeamID(TX_Votes.MakeWorld(3, s), store, nil), 11)
	s[11] = { pid = 10, team = -1, alive = 0, major = 0, human = 0 }
	-- a PENDING_APPLY record reserves its ID for other records, not for itself
	local w = TX_Votes.MakeWorld(3, s)
	local rec = TX_Votes.Propose(store, w, 0, 1)
	H.eq(rec.state, "PASSED")
	TX_Votes.FinishPass(store, w, rec)
	H.eq(rec.newTeamID, 10)
	H.eq(TX_Votes.NewTeamID(w, store, rec.id), 10)
	H.eq(TX_Votes.NewTeamID(w, store, nil), 11)
	local rec2 = TX_Votes.Propose(store, w, 2, 3)
	TX_Votes.FinishPass(store, w, rec2)
	H.eq(rec2.newTeamID, 11, "a second pending kick gets 11")
	-- every ID 0..63 used: nil and NO_FREE_TEAM
	local full = {}
	for i = 0, 63 do
		full[#full + 1] = { pid = i, team = i, alive = 1, major = 1, human = 1 }
	end
	full[2].team = 0
	local wf = TX_Votes.MakeWorld(5, full)
	local sf = Fresh(5)
	H.eq(TX_Votes.NewTeamID(wf, sf, nil), 1, "team 1 is free after P1 joined team 0")
	full[2].team = 1
	full[1] = { pid = 0, team = 1, alive = 1, major = 1, human = 1 }
	full[65] = { pid = 64, team = 0, alive = 0, major = 0, human = 0 }
	wf = TX_Votes.MakeWorld(5, full)
	H.isnil(TX_Votes.NewTeamID(wf, sf, nil))
	local recf = TX_Votes.Propose(sf, wf, 0, 1)
	H.eq(recf.state, "PASSED")
	H.eq(TX_Votes.FinishPass(sf, wf, recf), "CANCELLED")
	H.eq(recf.reason, "NO_FREE_TEAM")
end)

test("votes 12: Prune: a dead voter is GONE and the rest pass at the next turn start; all GONE: NO_VOTERS; a voter turned AI expires the vote", function()
	Load()
	-- dead voter
	local store = Fresh()
	local rec = TX_Votes.Propose(store, World(42, FOUR), 0, 1)
	local dead7 = { [7] = { team = 0, alive = 0, major = 1, human = 1 } }
	TX_Votes.Vote(store, World(43, dead7), 2, rec.id, "YES")
	H.eq(rec.state, "OPEN", "P7 is still listed as PENDING until the turn start")
	local ev = TX_Votes.TurnStart(store, World(44, dead7))
	H.eq(VotersText(rec), "0=YES 2=YES 7=GONE")
	H.eq(rec.state, "PENDING_APPLY")
	H.eq(rec.closedTurn, 44)
	H.eq(rec.newTeamID, 6)
	H.eq(EventsText(ev), "PASSED:1:1")
	-- every voter GONE
	local store2 = Fresh()
	local rec2 = TX_Votes.Propose(store2, World(42), 0, 1)
	ev = TX_Votes.TurnStart(store2, World(43, { [0] = { alive = 0 }, [2] = { team = 9 } }))
	H.eq(rec2.state, "CANCELLED")
	H.eq(rec2.reason, "NO_VOTERS")
	H.eq(EventsText(ev), "CANCELLED:1:1:NO_VOTERS")
	-- a voter whose slot turned AI keeps PENDING, gets no reminder, and the vote expires
	local store3 = Fresh()
	local rec3 = TX_Votes.Propose(store3, World(42), 0, 1)
	local ai2 = { [2] = { human = 0 } }
	for turn = 43, 46 do
		ev = TX_Votes.TurnStart(store3, World(turn, ai2))
		H.eq(EventsText(ev), "", "no reminder for an AI slot at T" .. turn)
	end
	H.eq(VotersText(rec3), "0=YES 2=PENDING")
	H.eq(Codes(TX_Votes.VoteReasons(store3, World(46, ai2), 2, rec3.id, "YES")), "NOT_VOTER")
	ev = TX_Votes.TurnStart(store3, World(47, ai2))
	H.eq(rec3.state, "EXPIRED")
	H.eq(EventsText(ev), "EXPIRED:1:1")
end)

test("votes 13: target dead: CANCELLED TARGET_GONE with no PASSED event; target on another team: TARGET_LEFT", function()
	Load()
	-- the rest said YES and the last voter died too: the target check comes first
	local store = Fresh()
	local rec = TX_Votes.Propose(store, World(42, FOUR), 0, 1)
	TX_Votes.Vote(store, World(42, FOUR), 2, rec.id, "YES")
	local ev = TX_Votes.TurnStart(store, World(43, { [1] = { alive = 0 }, [7] = { team = 0, alive = 0, major = 1, human = 1 } }))
	H.eq(rec.state, "CANCELLED")
	H.eq(rec.reason, "TARGET_GONE")
	H.eq(EventsText(ev), "CANCELLED:1:1:TARGET_GONE", "no PASSED event")
	-- an OPEN vote whose target dies
	local store2 = Fresh()
	local rec2 = TX_Votes.Propose(store2, World(42), 0, 1)
	ev = TX_Votes.TurnStart(store2, World(43, { [1] = { alive = 0 } }))
	H.eq(rec2.state, "CANCELLED")
	H.eq(rec2.reason, "TARGET_GONE")
	H.eq(rec2.closedTurn, 43)
	H.eq(EventsText(ev), "CANCELLED:1:1:TARGET_GONE")
	-- the target left the team
	local store3 = Fresh()
	local rec3 = TX_Votes.Propose(store3, World(42), 0, 1)
	ev = TX_Votes.TurnStart(store3, World(43, { [1] = { team = 9 } }))
	H.eq(rec3.reason, "TARGET_LEFT")
	H.eq(EventsText(ev), "CANCELLED:1:1:TARGET_LEFT")
	-- a PENDING_APPLY record whose target dies
	local store4 = Fresh()
	local rec4 = TX_Votes.Propose(store4, World(42), 3, 4)
	TX_Votes.FinishPass(store4, World(42), rec4)
	ev = TX_Votes.TurnStart(store4, World(43, { [4] = { alive = 0 } }))
	H.eq(rec4.state, "CANCELLED")
	H.eq(rec4.reason, "TARGET_GONE")
	H.eq(rec4.closedTurn, 42, "closedTurn stays the turn it left OPEN")
	H.eq(EventsText(ev), "CANCELLED:1:4:TARGET_GONE")
end)

test("votes 14: victory cancels OPEN and unapplied PENDING_APPLY, keeps applied ones, then refuses proposals and votes", function()
	Load()
	local over = { [7] = { team = 7, alive = 1, major = 1, human = 1 }, [8] = { team = 7, alive = 1, major = 1, human = 1 } }
	local store, w = Fresh(), World(42, over)
	local open = TX_Votes.Propose(store, w, 0, 1)
	local pend = TX_Votes.Propose(store, w, 3, 4)
	TX_Votes.FinishPass(store, w, pend)
	local applied = TX_Votes.Propose(store, w, 7, 8)
	TX_Votes.FinishPass(store, w, applied)
	H.eq(applied.newTeamID, 8, "6 is taken by the first pending kick")
	TX_Votes.MarkWritten(applied, World(43, { [8] = { team = 8, alive = 1, major = 1, human = 1 }, [7] = over[7] }), 7)
	local ids = TX_Votes.Victory(store, 45, 1)
	H.deq(ids, { 1, 2 })
	H.eq(open.state, "CANCELLED")
	H.eq(open.reason, "VICTORY")
	H.eq(open.closedTurn, 45)
	H.eq(pend.state, "CANCELLED")
	H.eq(pend.reason, "VICTORY")
	H.eq(applied.state, "PENDING_APPLY")
	H.eq(store.victoryTurn, 45)
	H.eq(store.victoryTeam, 1)
	H.deq(TX_Votes.Victory(store, 46, 0), {}, "only the first report counts")
	H.eq(store.victoryTurn, 45)
	H.eq(TX_Votes.ProposeReasons(store, w, 0, 2)[1], "VICTORY")
	H.eq(TX_Votes.VoteReasons(store, w, 2, open.id, "YES")[1], "VICTORY")
	local _, codes = TX_Votes.Propose(store, w, 0, 2)
	H.eq(codes[1], "VICTORY")
	local ev = TX_Votes.TurnStart(store, World(46, { [8] = { team = 8, alive = 1, major = 1, human = 1 }, [7] = over[7] }))
	H.eq(EventsText(ev), "REMIND_APPLY:3:8", "the applied kick goes on")
end)

test("votes 15: VisibleTo: open and failed votes are hidden from the target; passed ones shown; never to another team", function()
	Load()
	local rec = { id = 1, teamID = 0, proposerID = 0, targetID = 1, voters = { { pid = 0, v = "YES" } } }
	for _, st in ipairs({ "OPEN", "PASSED", "FAILED", "EXPIRED", "CANCELLED" }) do
		rec.state = st
		H.eq(TX_Votes.VisibleTo(rec, 1, 0), false, st .. " hidden from the target")
		H.eq(TX_Votes.VisibleTo(rec, 0, 0), true, st .. " shown to the proposer")
		H.eq(TX_Votes.VisibleTo(rec, 2, 0), true, st .. " shown to a teammate")
		H.eq(TX_Votes.VisibleTo(rec, 3, 1), false, st .. " hidden from another team")
	end
	for _, st in ipairs({ "PENDING_APPLY", "DONE" }) do
		rec.state = st
		H.eq(TX_Votes.VisibleTo(rec, 1, 0), true, st .. " shown to the target")
		H.eq(TX_Votes.VisibleTo(rec, 1, 6), true, st .. " shown to the target on its new team")
		H.eq(TX_Votes.VisibleTo(rec, 2, 0), true)
		H.eq(TX_Votes.VisibleTo(rec, 3, 1), false, st .. " hidden from another team")
		H.eq(TX_Votes.VisibleTo(rec, 3, nil), false)
	end
end)

test("votes 16: ApplyReasons, MarkWritten and MarkDone; NOT_PENDING, NOT_SEEN", function()
	Load()
	local store = Fresh()
	local rec = TX_Votes.Propose(store, World(42), 0, 1)
	local function R(world, sender, id, step)
		local codes = TX_Votes.ApplyReasons(store, world, sender, id, step)
		KnownCodes(codes)
		return Codes(codes)
	end
	H.eq(R(World(42), 0, rec.id, "WRITTEN"), "NOT_PENDING", "still OPEN")
	TX_Votes.Vote(store, World(42), 2, rec.id, "YES")
	TX_Votes.FinishPass(store, World(42), rec)
	H.eq(R(World(42), 0, rec.id, "WRITTEN"), "NOT_SEEN", "gameplay still reads team 0")
	local seen = World(43, { [1] = { team = 6 } })
	H.eq(R(seen, 0, rec.id, "WRITTEN"), "")
	H.eq(R(seen, 1, rec.id, "RELOADED"), "", "the target may report too (hotseat)")
	H.eq(R(seen, 4, rec.id, "WRITTEN"), "NOT_HUMAN")
	H.eq(R(seen, 0, 99, "WRITTEN"), "NO_RECORD")
	H.eq(R(seen, 0, rec.id, "SAVED"), "BAD_STEP")
	H.eq(R(seen, 0, rec.id, nil), "BAD_STEP")
	TX_Votes.MarkWritten(rec, seen, 0)
	H.eq(rec.applied, 1)
	H.eq(rec.appliedTurn, 43)
	H.eq(rec.appliedBy, 0)
	TX_Votes.MarkWritten(rec, World(44, { [1] = { team = 6 } }), 2)
	H.eq(rec.appliedBy, 0, "a second WRITTEN changes nothing")
	TX_Votes.MarkDone(rec, World(45, { [1] = { team = 6 } }))
	H.eq(rec.state, "DONE")
	H.eq(rec.doneTurn, 45)
	H.eq(R(seen, 0, rec.id, "RELOADED"), "NOT_PENDING")
	-- DONE without a WRITTEN first fills the applied fields
	local store2 = Fresh()
	local rec2 = TX_Votes.Propose(store2, World(42), 3, 4)
	TX_Votes.FinishPass(store2, World(42), rec2)
	TX_Votes.MarkDone(rec2, World(44, { [4] = { team = 6 } }))
	H.eq(rec2.applied, 1)
	H.eq(rec2.appliedBy, -1)
	H.eq(rec2.appliedTurn, 44)
end)

test("votes 16b: UNDONE needs no read and resets applied; a WRITTEN up to undoneAttempt is ATTEMPT_UNDONE; a newer one is not", function()
	Load()
	local store = Fresh()
	local rec = TX_Votes.Propose(store, World(42), 3, 4)
	TX_Votes.FinishPass(store, World(42), rec)
	local function R(world, sender, step, attempt)
		local codes = TX_Votes.ApplyReasons(store, world, sender, rec.id, step, attempt)
		KnownCodes(codes)
		return Codes(codes)
	end
	local seen = World(43, { [4] = { team = 6 } })
	H.eq(R(World(43), 3, "UNDONE", 1), "", "no NOT_SEEN for UNDONE: the old team is back")
	H.eq(R(World(43), 4, "UNDONE", 1), "NOT_HUMAN")
	TX_Votes.MarkWritten(rec, seen, 3, 1)
	H.eq(rec.appliedAttempt, 1)
	H.eq(TX_Votes.MarkUndone(rec, 1), true)
	H.eq(rec.applied, 0)
	H.isnil(rec.appliedTurn)
	H.isnil(rec.appliedBy)
	H.isnil(rec.appliedAttempt)
	H.eq(rec.undoneAttempt, 1)
	H.eq(R(seen, 3, "WRITTEN", 1), "ATTEMPT_UNDONE", "the late WRITTEN of the undone attempt")
	H.eq(R(seen, 3, "WRITTEN", nil), "ATTEMPT_UNDONE", "no token reads as 0")
	H.eq(R(World(43), 3, "WRITTEN", 1), "ATTEMPT_UNDONE,NOT_SEEN")
	H.eq(R(seen, 3, "WRITTEN", 2), "")
	H.eq(R(seen, 3, "RELOADED", nil), "", "RELOADED carries no token")
	TX_Votes.MarkWritten(rec, seen, 3, 2)
	H.eq(TX_Votes.MarkUndone(rec, 1), false, "an older UNDONE leaves the newer attempt applied")
	H.eq(rec.applied, 1)
	H.eq(rec.undoneAttempt, 1)
	-- applied found at a turn start (no token) is reset by any UNDONE
	TX_Votes.MarkUndone(rec, 2)
	TX_Votes.MarkWritten(rec, seen, -1)
	H.eq(TX_Votes.MarkUndone(rec, 2), true)
	H.eq(rec.undoneAttempt, 2)
	-- the store keeps the tokens through a commit and a load
	local copy = TX_Store.Normalize(FAKE.DeepCopy(TX_Store.Shape(store)), 43)
	H.eq(TX_Store.Get(copy, rec.id).undoneAttempt, 2)
	H.deq(TX_Store.Check(TX_Store.Shape(store)), {})
end)

test("votes 17: TurnStart with PENDING_APPLY: already applied in gameplay -> applied; ID taken by another slot -> new ID, never because of the target", function()
	Load()
	local store = Fresh()
	local rec = TX_Votes.Propose(store, World(42), 3, 4)
	TX_Votes.FinishPass(store, World(42), rec)
	H.eq(rec.newTeamID, 6)
	-- nothing changed: a reminder
	H.eq(EventsText(TX_Votes.TurnStart(store, World(43))), "REMIND_APPLY:1:4")
	-- another slot took team 6 before Apply
	local ev = TX_Votes.TurnStart(store, World(44, { [7] = { team = 6, alive = 1, major = 0, human = 0 } }))
	H.eq(rec.newTeamID, 7)
	H.eq(EventsText(ev), "TEAM_ID:1:4 REMIND_APPLY:1:4")
	-- gameplay reads the target on newTeamID with applied = 0 (the write came without WRITTEN)
	ev = TX_Votes.TurnStart(store, World(45, { [4] = { team = 7 } }))
	H.eq(rec.newTeamID, 7, "the target itself never moves the ID")
	H.eq(rec.applied, 1)
	H.eq(rec.appliedBy, -1)
	H.eq(rec.appliedTurn, 45)
	H.eq(EventsText(ev), "APPLIED:1:4 REMIND_APPLY:1:4")
	-- applied: another slot on the team no longer moves anything
	ev = TX_Votes.TurnStart(store, World(46, { [4] = { team = 7 }, [7] = { team = 7, alive = 1, major = 0, human = 0 } }))
	H.eq(rec.newTeamID, 7)
	H.eq(EventsText(ev), "REMIND_APPLY:1:4")
	-- no free ID left at the recompute
	local store2 = Fresh()
	local rec2 = TX_Votes.Propose(store2, World(42), 3, 4)
	TX_Votes.FinishPass(store2, World(42), rec2)
	local full = Slots()
	for _, s in ipairs(full) do
		if s.team == -1 then
			s.team = s.pid
		end
	end
	full[#full + 1] = { pid = 64, team = 6, alive = 0, major = 0, human = 0 }
	full[#full + 1] = { pid = 65, team = 62, alive = 0, major = 0, human = 0 }
	full[#full + 1] = { pid = 66, team = 63, alive = 0, major = 0, human = 0 }
	ev = TX_Votes.TurnStart(store2, TX_Votes.MakeWorld(43, full))
	H.eq(rec2.state, "CANCELLED")
	H.eq(rec2.reason, "NO_FREE_TEAM")
	H.eq(EventsText(ev), "CANCELLED:1:4:NO_FREE_TEAM")
end)

test("votes 18: a stored PASSED record is finished at the turn start", function()
	Load()
	local store = Fresh()
	local rec = TX_Votes.Propose(store, World(42), 0, 1)
	TX_Votes.Vote(store, World(42), 2, rec.id, "YES")
	H.eq(rec.state, "PASSED")
	local ev = TX_Votes.TurnStart(store, World(43))
	H.eq(rec.state, "PENDING_APPLY")
	H.eq(rec.newTeamID, 6)
	H.eq(rec.closedTurn, 42)
	H.eq(EventsText(ev), "PASSED:1:1")
end)

test("votes 19: events come in record-id order; the slot order of the input never matters", function()
	Load()
	local function Run(reverse)
		local slots = Slots(FOUR)
		if reverse then
			local r = {}
			for i = #slots, 1, -1 do
				r[#r + 1] = slots[i]
			end
			slots = r
		end
		local store = Fresh()
		local w = TX_Votes.MakeWorld(42, slots)
		TX_Votes.Propose(store, w, 3, 4)
		TX_Votes.Propose(store, w, 0, 1)
		local evs = {}
		for turn = 43, 48 do
			local wt = TX_Votes.MakeWorld(turn, slots)
			evs[#evs + 1] = EventsText(TX_Votes.TurnStart(store, wt))
		end
		return store, evs
	end
	local s1, e1 = Run(false)
	local s2, e2 = Run(true)
	H.eq(e1[1], "PASSED:1:4 REMIND_VOTE:2:2 REMIND_VOTE:2:7")
	H.eq(e1[6], "REMIND_APPLY:1:4")
	H.deq(e2, e1)
	H.deq(s2, s1)
end)

test("votes: TX_Votes is pure: no log line, no property write, no engine call", function()
	Load()
	local before = #FAKE.log
	local store = Fresh()
	local rec = TX_Votes.Propose(store, World(42, FOUR), 0, 1)
	TX_Votes.Vote(store, World(42, FOUR), 2, rec.id, "YES")
	TX_Votes.TurnStart(store, World(43, FOUR))
	TX_Votes.Vote(store, World(43, FOUR), 7, rec.id, "YES")
	TX_Votes.TurnStart(store, World(44, FOUR))
	TX_Votes.Victory(store, 45, 0)
	H.eq(#FAKE.log, before, "no print")
	H.deq(FAKE.propWrites, {})
	H.eq(TX_Store.Check(TX_Store.Shape(store))[1], nil, "the store stays storable")
	H.clean()
end)
