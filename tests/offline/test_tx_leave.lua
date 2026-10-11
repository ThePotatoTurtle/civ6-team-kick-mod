-- Tests of Leave team (PLAN Part II notes "Leave team", 2026-10-11): a player
-- leaves their team on their own, soft or hard, with no vote. TX_Votes.Leave
-- and LeaveReasons on plain tables, the LEAVE record in TX_Store, the
-- gameplay TX_Leave handler and its notifications, the Team window's
-- two-click Leave buttons, and the whole way through the host's Apply, the
-- save and the load for soft and hard leaves.
--
-- Standard world (FAKE_TX.World): P0, P1, P2 human on team 0; P3 human and P4
-- AI on team 1; P5 human solo (team 2); city-state 6; slots 7..61 empty;
-- Free Cities 62; Barbarians 63. First free team ID 6. Split team model
-- (PLAN II.0 F1 to F3).

local GAMEPLAY = "TX/Scripts/TX_Gameplay.lua"
local VOTE_N = "NOTIFICATION_TX_VOTE_REQUIRED"
local PASSED_N = "NOTIFICATION_TX_KICK_PASSED"
local DONE_N = "NOTIFICATION_TX_KICK_DONE"
local HARD_DONE_N = "NOTIFICATION_TX_HARD_KICK_DONE"
local FAILED_N = "NOTIFICATION_TX_REQUEST_FAILED"
local HUMANS = { 0, 1, 2, 3, 5 }

local function T(key, ...) return Locale.Lookup(key, ...) end
local function Label(pid)
	return "LOC_LEADER_FAKE_" .. pid .. "_NAME (LOC_CIVILIZATION_FAKE_" .. pid .. "_NAME)"
end
local function SoftL() return T("LOC_TX_LEAVE_SOFT_SHORT") end
local function HardL() return T("LOC_TX_LEAVE_HARD_SHORT") end
local function Codes(list) return table.concat(list or {}, ",") end

-- ===========================================================================
-- TX_Votes (pure)
-- ===========================================================================
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

local function VWorld(over)
	return TX_Votes.MakeWorld(42, Slots(over))
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

test("leave votes 1: LeaveReasons and Leave refuse AI, dead, solo, a bad or switched-off mode, an open vote, a pending apply and a victory", function()
	include("TX_Votes")
	local w = VWorld()
	local store = TX_Store.Fresh(42)
	local function Reasons(pid, s, world) return Codes(TX_Votes.LeaveReasons(s or store, world or w, pid)) end
	H.eq(Reasons(0), "", "P0 may leave a team of 3")
	H.eq(Reasons(3), "", "P3 may leave a team of 2 (with an AI)")
	H.eq(Reasons(4), "NOT_HUMAN", "AI")
	H.eq(Reasons(5), "NO_TEAM", "solo")
	H.eq(Reasons(6), "NOT_HUMAN,NOT_ALIVE", "city-state")
	H.eq(Reasons(40), "NOT_HUMAN,NOT_ALIVE", "empty slot")
	H.eq(Reasons(99), "NOT_HUMAN,NOT_ALIVE", "no slot")
	H.eq(Reasons(1, store, VWorld({ [1] = { alive = 0 } })), "NOT_ALIVE", "dead")
	H.eq(Reasons(3, store, VWorld({ [4] = { alive = 0 } })), "NO_TEAM", "the only teammate is dead")
	-- bad modes, checked last
	for _, mode in ipairs({ "soft", "MEDIUM", 1, false }) do
		local rec, codes = TX_Votes.Leave(store, w, 0, mode)
		H.isnil(rec)
		H.eq(Codes(codes), "BAD_MODE", "mode " .. tostring(mode))
	end
	local rec0, codes0 = TX_Votes.Leave(store, w, 0, nil)
	H.isnil(rec0)
	H.eq(Codes(codes0), "BAD_MODE", "missing mode")
	local recS, codesS = TX_Votes.Leave(store, w, 5, "MEDIUM")
	H.isnil(recS)
	H.eq(Codes(codesS), "NO_TEAM,BAD_MODE", "BAD_MODE comes last")
	TX_Config.HARD_KICK_ENABLED = false
	local recH, codesH = TX_Votes.Leave(store, w, 0, "HARD")
	H.isnil(recH)
	H.eq(Codes(codesH), "BAD_MODE", "HARD while switched off")
	TX_Config.HARD_KICK_ENABLED = true
	H.len(store.ids, 0, "nothing stored")
	-- an open kick vote on team 0: VOTE_OPEN, the target TEAM_BUSY; team 1 is free
	local vote = TX_Votes.Propose(store, w, 0, 1, "SOFT")
	H.eq(vote.state, "OPEN")
	H.eq(Reasons(0), "VOTE_OPEN")
	H.eq(Reasons(2), "VOTE_OPEN")
	H.eq(Reasons(1), "TEAM_BUSY", "the target never learns of the vote")
	H.eq(Reasons(3), "")
	-- a pending leave on team 1: APPLY_PENDING for its team, and kicks there too
	local leave = TX_Votes.Leave(store, w, 3, "SOFT")
	H.eq(leave.state, "PENDING_APPLY")
	H.eq(Reasons(3), "APPLY_PENDING")
	H.eq(Codes(TX_Votes.ProposeReasons(store, w, 3, 4)), "APPLY_PENDING")
	-- victory
	local won = TX_Store.Fresh(42)
	won.victoryTurn = 40
	H.eq(Reasons(0, won), "VICTORY")
	KnownCodes(TX_Votes.LeaveReasons(store, VWorld({ [1] = { alive = 0 } }), 6))
	KnownCodes({ "NO_TEAM", "BAD_MODE", "VICTORY", "APPLY_PENDING", "TEAM_BUSY" })
end)

test("leave votes 2: the LEAVE record: proposer = target = the leaver, no voters, straight to PENDING_APPLY with the pass's newTeamID", function()
	include("TX_Votes")
	local w = VWorld()
	local store = TX_Store.Fresh(42)
	local rec, codes = TX_Votes.Leave(store, w, 2, "HARD")
	H.len(codes, 0)
	H.eq(rec.id, 1)
	H.eq(rec.kind, "LEAVE")
	H.eq(rec.mode, "HARD")
	H.eq(rec.teamID, 0)
	H.eq(rec.proposerID, 2)
	H.eq(rec.targetID, 2)
	H.deq(rec.voters, {})
	H.eq(rec.state, "PENDING_APPLY")
	H.eq(rec.newTeamID, 6, "the lowest free team ID, as for a pass")
	H.eq(rec.applied, 0)
	H.eq(rec.openedTurn, 42)
	H.eq(rec.closedTurn, 42)
	H.eq(rec.expiresTurn, 42)
	H.eq(TX_Votes.RecKind(rec), "LEAVE")
	H.eq(TX_Votes.IsLeave(rec), true)
	-- a second leave elsewhere reserves the next ID
	local rec2 = TX_Votes.Leave(store, w, 3, "SOFT")
	H.eq(rec2.newTeamID, 7)
	-- kicks are KICK records; an old record without kind reads as KICK
	local kick = TX_Votes.Propose(TX_Store.Fresh(42), w, 0, 1, "SOFT")
	H.eq(kick.kind, "KICK")
	H.eq(TX_Votes.RecKind({ state = "DONE" }), "KICK")
	H.eq(TX_Votes.IsLeave(nil), false)
	-- visibility: the leaver and its team, not other teams
	H.eq(TX_Votes.VisibleTo(rec, 2, 0), true)
	H.eq(TX_Votes.VisibleTo(rec, 2, 6), true, "the leaver after the load")
	H.eq(TX_Votes.VisibleTo(rec, 0, 0), true)
	H.eq(TX_Votes.VisibleTo(rec, 3, 1), false)
	-- turn start: the same as a passed kick (REMIND_APPLY); victory cancels an unapplied one
	local events = TX_Votes.TurnStart(store, TX_Votes.MakeWorld(43, Slots()))
	H.eq(#events, 2)
	H.eq(events[1].kind, "REMIND_APPLY")
	H.eq(events[1].pid, 2)
	H.deq(TX_Votes.Victory(store, 43, 1), { 1, 2 })
	H.eq(rec.state, "CANCELLED")
	H.eq(rec.reason, "VICTORY")
	H.eq(TX_Votes.VisibleTo(rec, 2, 0), true, "the leaver sees its own cancelled leave")
	-- no free team ID: CANCELLED NO_FREE_TEAM
	local full = {}
	for i = 0, 63 do
		full[#full + 1] = { pid = i, team = i, alive = 1, major = 1, human = 1 }
	end
	full[2].team = 0
	full[#full + 1] = { pid = 64, team = 1, alive = 0, major = 0, human = 0 }
	local recF = TX_Votes.Leave(TX_Store.Fresh(42), TX_Votes.MakeWorld(42, full), 1, "SOFT")
	H.eq(recF.state, "CANCELLED")
	H.eq(recF.reason, "NO_FREE_TEAM")
end)

-- ===========================================================================
-- TX_Store
-- ===========================================================================
test("leave store 1: a LEAVE record round trips under dropEmpty: no voters stored, restored on load, no repair", function()
	include("TX_Votes")
	H.eq(FAKE.dropEmpty, true)
	local store = TX_Store.Fresh(1)
	TX_Votes.Leave(store, VWorld(), 2, "SOFT")
	H.eq(TX_Store.Commit(store), true)
	local raw = H.prop("TX_Store").recs.r1
	H.isnil(raw.voters, "the empty voters list is left out")
	H.eq(raw.kind, "LEAVE")
	local back, repaired = TX_Store.Load()
	H.eq(repaired, false)
	H.deq(back, store)
	H.deq(TX_Store.Get(back, 1).voters, {})
	H.deq(FAKE.propViolations, {})
	H.clean()
end)

test("leave store 2: an old record without kind loads as KICK silently; an unknown kind is repaired; a bad kind or a kick without voters is dropped", function()
	include("TX_Store")
	local function R(fields)
		local r = {
			teamID = 0, proposerID = 0, targetID = 1, mode = "SOFT",
			voters = { { pid = 0, v = "YES" }, { pid = 2, v = "PENDING" } },
			openedTurn = 3, expiresTurn = 8, state = "OPEN",
		}
		for _, k in ipairs(FAKE.SortedKeys(fields)) do
			r[k] = fields[k]
		end
		return r
	end
	FAKE.props.TX_Store = {
		schema = 1, nextID = 3, lastTurn = 4, ids = { 1, 2 },
		recs = { r1 = R({ id = 1, state = "DONE", newTeamID = 6, applied = 1, doneTurn = 5 }), r2 = R({ id = 2 }) },
	}
	local store, repaired = TX_Store.Load()
	H.eq(repaired, false, "an old record is not a repair")
	H.eq(TX_Store.Get(store, 1).kind, "KICK")
	H.eq(TX_Store.Get(store, 2).kind, "KICK")
	H.clean()

	local leave = R({ id = 3, kind = "LEAVE", proposerID = 1, state = "PENDING_APPLY", newTeamID = 6, applied = 0 })
	leave.voters = nil
	local kickNoVoters = R({ id = 4, kind = "KICK" })
	kickNoVoters.voters = nil
	local bogusNoVoters = R({ id = 6, kind = "BOGUS" })
	bogusNoVoters.voters = nil
	FAKE.props.TX_Store = {
		schema = 1, nextID = 7, lastTurn = 4, ids = { 1, 2, 3, 4, 5, 6 },
		recs = {
			r1 = R({ id = 1, kind = "BOGUS" }),
			r2 = R({ id = 2, kind = 7 }),
			r3 = leave,
			r4 = kickNoVoters,
			r5 = R({ id = 5, kind = "LEAVE", state = "DONE", newTeamID = 7, applied = 1, doneTurn = 5 }),
			r6 = bogusNoVoters,
		},
	}
	local s2, rep2 = TX_Store.Load()
	H.eq(rep2, true)
	H.eq(TX_Store.Get(s2, 1).kind, "KICK")
	H.isnil(TX_Store.Get(s2, 2))
	H.eq(TX_Store.Get(s2, 3).kind, "LEAVE")
	H.deq(TX_Store.Get(s2, 3).voters, {})
	H.isnil(TX_Store.Get(s2, 4))
	H.eq(TX_Store.Get(s2, 5).kind, "LEAVE", "a LEAVE record that has voters is fine too")
	H.isnil(TX_Store.Get(s2, 6))
	H.ok(H.hasLine("[Store] ERROR normalize: record 1 had kind=BOGUS; set to KICK"))
	H.ok(H.hasLine("ERROR normalize: dropped malformed record key=r2 (kind is not a string)"))
	H.ok(H.hasLine("ERROR normalize: dropped malformed record key=r4 (no voters)"))
	H.ok(H.hasLine("ERROR normalize: dropped malformed record key=r6 (no voters)"))
end, { allowErrors = true })

-- ===========================================================================
-- Gameplay: TX_Leave
-- ===========================================================================
local function GSetup(opts)
	FAKE.dofile("tests/offline/lib/fake_txworld.lua")
	FAKE_TX.World(opts)
	H.load(GAMEPLAY)
end

local function Leave(pid, mode)
	H.request(pid, { OnStart = "TX_Leave", mode = mode })
end
local function Rec(id)
	local s = H.prop("TX_Store")
	return s and s.recs and s.recs["r" .. id]
end
local function Rev() return H.prop("TX_Rev") or 0 end
local function Summary(n) return n and n.data[ParameterTypes.SUMMARY] end
local function Message(n) return n and n.data[ParameterTypes.MESSAGE] end
local function Last(pid, typeName)
	local list = H.notifs(pid, typeName)
	return list[#list]
end
local function PidsOf(list)
	local out = {}
	for _, n in ipairs(list) do out[#out + 1] = n.pid end
	table.sort(out)
	return out
end

test("leave gameplay 1: refused requests store nothing and tell the sender with the reason", function()
	GSetup()
	H.len(H.lines("[Init] registered GameEvents.TX_Leave", true), 1)
	local function Refused(pid, mode, code)
		local rev, n = Rev(), #FAKE.notifications
		Leave(pid, mode)
		H.eq(Rev(), rev, "nothing stored for P" .. pid .. " " .. tostring(mode))
		H.ok(H.hasLine("refused leave from P" .. pid .. ": " .. code), code)
		if pid ~= 4 then
			H.eq(#FAKE.notifications, n + 1)
			H.eq(Summary(Last(pid, FAILED_N)), T("LOC_TX_REASON_" .. code))
		else
			H.eq(#FAKE.notifications, n, "an AI gets no notification")
		end
	end
	Refused(4, "SOFT", "NOT_HUMAN")
	Refused(5, "SOFT", "NO_TEAM")
	Refused(0, "soft", "BAD_MODE")
	Refused(0, nil, "BAD_MODE")
	Refused(0, 1, "BAD_MODE")
	TX_Config.HARD_KICK_ENABLED = false
	Refused(0, "HARD", "BAD_MODE")
	TX_Config.HARD_KICK_ENABLED = true
	H.kill(1)
	Refused(1, "SOFT", "NOT_ALIVE")
	H.isnil(Rec(1))
	H.clean()
end)

test("leave gameplay 1b: an open vote, a pending apply and a victory refuse a leave", function()
	GSetup()
	H.request(0, { OnStart = "TX_Propose", targetID = 1, mode = "SOFT" })
	H.eq(Rec(1).state, "OPEN")
	Leave(2, "SOFT")
	H.eq(Summary(Last(2, FAILED_N)), T("LOC_TX_REASON_VOTE_OPEN"))
	Leave(1, "SOFT")
	H.eq(Summary(Last(1, FAILED_N)), T("LOC_TX_REASON_TEAM_BUSY"), "the target only sees TEAM_BUSY")
	H.len(H.notifs(1, VOTE_N), 0)
	Leave(3, "SOFT")
	H.eq(Rec(2).state, "PENDING_APPLY")
	Leave(3, "HARD")
	H.eq(Summary(Last(3, FAILED_N)), T("LOC_TX_REASON_APPLY_PENDING"))
	H.isnil(Rec(3))
	H.request(0, { OnStart = "TX_Victory", team = 0 })
	H.eq(Rec(2).state, "CANCELLED", "the unapplied leave is cancelled by the victory")
	H.eq(Rec(2).reason, "VICTORY")
	Leave(3, "SOFT")
	H.eq(Summary(Last(3, FAILED_N)), T("LOC_TX_REASON_VICTORY"))
	H.isnil(Rec(3))
	H.clean()
end)

test("leave gameplay 2: a hard leave in a team of 3: the LEAVE record in PENDING_APPLY, KICK_PASSED with the left text to every living human, re-sent each turn", function()
	GSetup()
	Leave(2, "HARD")
	local r = Rec(1)
	H.eq(r.kind, "LEAVE")
	H.eq(r.mode, "HARD")
	H.eq(r.state, "PENDING_APPLY")
	H.eq(r.teamID, 0)
	H.eq(r.proposerID, 2)
	H.eq(r.targetID, 2)
	H.eq(r.newTeamID, 6)
	H.eq(r.applied, 0)
	H.isnil(r.voters, "no voters stored")
	H.ok(H.hasLine("rec=1 LEAVE team=0 P2 mode=HARD"))
	H.len(H.notifs(nil, VOTE_N), 0, "no vote")
	H.deq(PidsOf(H.notifs(nil, PASSED_N)), HUMANS)
	for _, pid in ipairs(HUMANS) do
		local n = Last(pid, PASSED_N)
		H.eq(Message(n), T("LOC_NOTIFICATION_TX_KICK_PASSED_LEAVE_MESSAGE"))
		H.eq(Summary(n), T("LOC_NOTIFICATION_TX_KICK_PASSED_LEAVE_SUMMARY", Label(2), HardL()))
		H.eq(n.data.TX_RecordID, 1)
	end
	H.ok(string.find(Summary(Last(0, PASSED_N)), "is leaving their team (hard)", 1, true) ~= nil)
	H.endTurn()
	H.eq(#H.notifs(nil, PASSED_N), 10, "re-sent to all at the turn start")
	H.eq(Rec(1).state, "PENDING_APPLY")
	-- the team is busy now: a kick is refused with APPLY_PENDING
	H.request(0, { OnStart = "TX_Propose", targetID = 1, mode = "SOFT" })
	H.eq(Summary(Last(0, FAILED_N)), T("LOC_TX_REASON_APPLY_PENDING"))
	H.deq(FAKE.propViolations, {})
	H.clean()
end)

test("leave gameplay 3: a soft leave in a team of 2 (the AI stays alone), and two runs give the same store", function()
	local stores = {}
	for run = 1, 2 do
		GSetup()
		Leave(3, "SOFT")
		H.eq(Rec(1).state, "PENDING_APPLY")
		H.eq(Rec(1).newTeamID, 6)
		H.eq(Summary(Last(3, PASSED_N)), T("LOC_NOTIFICATION_TX_KICK_PASSED_LEAVE_SUMMARY", Label(3), SoftL()))
		stores[run] = FAKE.DeepCopy(H.prop("TX_Store"))
		H.deq(FAKE.forbidden or {}, {})
		H.len(FAKE.rngCalls or {}, 0)
		H.clean()
	end
	H.deq(stores[1], stores[2])
end)

-- ===========================================================================
-- UI: the Team window's Leave row
-- ===========================================================================
local ENVS = nil

local function USetup(opts)
	opts = opts or {}
	FAKE.dofile("tests/offline/lib/fake_txworld.lua")
	FAKE_TX.World(opts)
	if opts.setup ~= nil then
		opts.setup()
	end
	FAKE_UI.Enable()
	FAKE.localPlayer = opts.localPlayer or 0
	FAKE_UI.AsGameplay(function() FAKE.dofile(GAMEPLAY) end)
	ENVS = FAKE_TX.LoadUI()
	H.markBody()
end

local function Win() return ENVS.TeamWindow end
local function Ban() return ENVS.ApplyBanner end
local function C() return Win().Controls end
local function Soft() return C().LeaveSoftButton end
local function Hard() return C().LeaveHardButton end

local function Requests(onStart)
	local out = {}
	for _, r in ipairs(FAKE_UI.requests) do
		if onStart == nil or r.params.OnStart == onStart then
			out[#out + 1] = r
		end
	end
	return out
end
local function Launch()
	local hit = nil
	for _, b in ipairs(FAKE_UI.builtInstances or {}) do
		if b.name == "TX_LaunchBarItem" then hit = b end
	end
	return hit and hit.inst
end
local function WindowOpen() return not C().TeamPanel:IsHidden() end
local function OpenWindow()
	if not WindowOpen() then Launch().LaunchItemButton:Click() end
	H.ok(WindowOpen(), "the window opens")
end
local function History()
	local hit = nil
	for _, im in ipairs(FAKE_UI.ims) do
		if im.instName == "TX_HistoryRow" then hit = im end
	end
	local out = {}
	for _, inst in ipairs(hit.list) do
		out[#out + 1] = { text = inst.HistoryLabel.text, tip = inst.HistoryButton.tooltip }
	end
	return out
end
local function Normal()
	H.eq(Soft().text, T("LOC_TX_LEAVE_SOFT"))
	H.eq(Hard().text, T("LOC_TX_LEAVE_HARD"))
end

test("leave ui 1: the Leave row: both buttons with their texts and one-line tooltips; shown for a team with an AI; Soft only while HARD is off", function()
	USetup()
	OpenWindow()
	H.eq(C().LeaveRow:IsHidden(), false)
	Normal()
	H.eq(Soft():IsHidden(), false)
	H.eq(Hard():IsHidden(), false)
	H.eq(Soft():IsDisabled(), false)
	H.eq(Hard():IsDisabled(), false)
	H.eq(Soft().tooltip, T("LOC_TX_LEAVE_SOFT_TT"))
	H.eq(Hard().tooltip, T("LOC_TX_LEAVE_HARD_TT"))
	H.eq(T("LOC_TX_LEAVE_LABEL"), "Leave team")
	-- P3 (team with an AI) sees it too
	FAKE_TX.Hotseat(3)
	OpenWindow()
	H.eq(C().LeaveRow:IsHidden(), false)
	H.eq(Soft():IsDisabled(), false)
	-- HARD switched off: no Hard button, and a click on it does nothing
	TX_Config.HARD_KICK_ENABLED = false
	Win().Controls.CloseButton:Click()
	OpenWindow()
	H.eq(Hard():IsHidden(), true)
	H.eq(Soft():IsHidden(), false)
	Hard():Click()
	Hard():Click()
	H.len(Requests("TX_Leave"), 0)
	TX_Config.HARD_KICK_ENABLED = true
	H.clean()
end)

test("leave ui 2: the first click relabels the button and sends nothing; the second click on it sends TX_Leave; then disabled with APPLY_PENDING", function()
	USetup()
	OpenWindow()
	Soft():Click()
	H.eq(Soft().text, T("LOC_TX_LEAVE_ARMED"))
	H.eq(Soft().text, "Confirm")
	H.eq(Hard().text, T("LOC_TX_LEAVE_HARD"))
	H.len(Requests("TX_Leave"), 0, "no send on a single click")
	H.len(FAKE_UI.popups, 0, "no popup")
	H.isnil(Rec(1))
	Soft():Click()
	local reqs = Requests("TX_Leave")
	H.len(reqs, 1)
	H.eq(reqs[1].params.mode, "SOFT")
	H.eq(reqs[1].pid, 0)
	H.eq(Rec(1).kind, "LEAVE")
	H.eq(Rec(1).targetID, 0)
	H.eq(Rec(1).state, "PENDING_APPLY")
	Normal()
	H.eq(Soft():IsDisabled(), true)
	H.eq(Hard():IsDisabled(), true)
	H.eq(Soft().tooltip, T("LOC_TX_REASON_APPLY_PENDING"))
	-- a third click sends nothing more
	Soft():Click()
	Soft():Click()
	H.len(Requests("TX_Leave"), 1)
	H.clean()
end)

test("leave ui 3: clicking the other button moves the confirmation to it; Hard sends HARD only on its own second click", function()
	USetup()
	OpenWindow()
	Soft():Click()
	H.eq(Soft().text, T("LOC_TX_LEAVE_ARMED"))
	Hard():Click()
	H.eq(Hard().text, T("LOC_TX_LEAVE_ARMED"))
	H.eq(Soft().text, T("LOC_TX_LEAVE_SOFT"), "the other button resets")
	Soft():Click()
	H.eq(Soft().text, T("LOC_TX_LEAVE_ARMED"))
	H.eq(Hard().text, T("LOC_TX_LEAVE_HARD"))
	H.len(Requests("TX_Leave"), 0, "alternating clicks never send")
	Hard():Click()
	H.len(Requests("TX_Leave"), 0)
	Hard():Click()
	local reqs = Requests("TX_Leave")
	H.len(reqs, 1)
	H.eq(reqs[1].params.mode, "HARD")
	H.eq(Rec(1).mode, "HARD")
	H.clean()
end)

test("leave ui 4: the confirmation resets on a hotseat hand-off, on closing the window, and after the timeout", function()
	USetup()
	-- hand-off: the window closes; the next player starts from normal
	OpenWindow()
	Soft():Click()
	FAKE_TX.Hotseat(2)
	H.eq(WindowOpen(), false)
	OpenWindow()
	Normal()
	Soft():Click()
	H.len(Requests("TX_Leave"), 0, "P2's first click only arms it")
	-- a player change without the event: P0's armed button is not P1's
	FAKE.localPlayer = 1
	Soft():Click()
	H.len(Requests("TX_Leave"), 0, "a click by another player arms it again")
	H.eq(Soft().text, T("LOC_TX_LEAVE_ARMED"))
	-- close and reopen
	FAKE_TX.Hotseat(0)
	OpenWindow()
	Hard():Click()
	C().CloseButton:Click()
	OpenWindow()
	Normal()
	Hard():Click()
	H.len(Requests("TX_Leave"), 0)
	-- timeout: still armed before LEAVE_ARM_SECONDS, normal after
	FAKE_UI.Update(Win(), 3)
	H.eq(Hard().text, T("LOC_TX_LEAVE_ARMED"))
	FAKE_UI.Update(Win(), 2.5)
	Normal()
	Hard():Click()
	H.len(Requests("TX_Leave"), 0, "after the timeout a click arms it again")
	Hard():Click()
	H.len(Requests("TX_Leave"), 1)
	H.eq(Requests("TX_Leave")[1].pid, 0)
	H.clean()
end)

test("leave ui 5: disabled with the reason: open vote (VOTE_OPEN, the target TEAM_BUSY), pending apply, victory; a vote opening disarms", function()
	USetup({ localPlayer = 2 })
	OpenWindow()
	Soft():Click()
	H.eq(Soft().text, T("LOC_TX_LEAVE_ARMED"))
	H.request(0, { OnStart = "TX_Propose", targetID = 1, mode = "SOFT" })
	FAKE_UI.Update(Win(), 0.6)
	Normal()
	H.eq(Soft():IsDisabled(), true)
	H.eq(Hard():IsDisabled(), true)
	H.eq(Soft().tooltip, T("LOC_TX_REASON_VOTE_OPEN"))
	Soft():Click()
	Soft():Click()
	H.len(Requests("TX_Leave"), 0, "a disabled button never sends")
	FAKE_TX.Hotseat(1)
	OpenWindow()
	H.eq(Soft().tooltip, T("LOC_TX_REASON_TEAM_BUSY"), "the target sees TEAM_BUSY only")
	H.eq(Soft():IsDisabled(), true)
	-- the vote passes: APPLY_PENDING
	H.request(2, { OnStart = "TX_Vote", recordID = 1, vote = "YES" })
	FAKE_UI.Update(Win(), 0.6)
	H.eq(Soft().tooltip, T("LOC_TX_REASON_APPLY_PENDING"))
	-- victory: the pass is cancelled, VICTORY
	H.request(0, { OnStart = "TX_Victory", team = 1 })
	FAKE_UI.Update(Win(), 0.6)
	H.eq(Soft().tooltip, T("LOC_TX_REASON_VICTORY"))
	H.eq(Hard().tooltip, T("LOC_TX_REASON_VICTORY"))
	H.eq(Soft():IsDisabled(), true)
	H.clean()
end)

-- ===========================================================================
-- End to end: leave -> Apply -> save -> load -> DONE
-- Every text a LEAVE record shows is the leave version (TX_ApplyBanner
-- TextKey, TX_Votes.IsLeave), and never says "kick" (the save name
-- TeamKick_... is the mod's name and is cut out before the check).
-- ===========================================================================
local function Poll() FAKE_UI.Update(Ban(), 0.6) end
local function BannerText() return Ban().Controls.BannerLabel.text end
local function LastDialog() return FAKE_UI.popups[#FAKE_UI.popups] end
local function DialogText(d) return table.concat(d.texts, "|") end
local function SaveName(i) return FAKE_TX.saveCalls[i or #FAKE_TX.saveCalls].file.Name end

-- text without the plain substring cut (the save name).
local function Without(text, cut)
	if cut == nil or cut == "" then
		return text
	end
	local out, i = {}, 1
	while true do
		local a, b = string.find(text, cut, i, true)
		if a == nil then
			out[#out + 1] = string.sub(text, i)
			break
		end
		out[#out + 1] = string.sub(text, i, a - 1)
		i = b + 1
	end
	return table.concat(out)
end
local function NoKick(text, what, cut)
	H.ok(type(text) == "string" and text ~= "", what .. ": has a text")
	H.ok(string.find(string.lower(Without(text, cut)), "kick", 1, true) == nil, what .. " says kick: " .. tostring(text))
end
local function NoKickDialog(d, cut)
	NoKick(d.title, d.id .. " title", cut)
	NoKick(DialogText(d), d.id .. " text", cut)
end

local function LeaveVia(mode)
	OpenWindow()
	local b = Soft()
	if mode == "HARD" then b = Hard() end
	b:Click()
	H.eq(b.text, T("LOC_TX_LEAVE_ARMED"))
	H.eq(b.text, "Confirm")
	b:Click()
	H.len(Requests("TX_Leave"), 1)
end
-- Apply rec through the banner: the confirm (returned), yes; the save finishes unless keepSave.
local function Apply(keepSave)
	Poll()
	H.eq(Ban().Controls.ApplyButton:IsHidden(), false, "the host has Apply")
	local n = #FAKE_UI.popups
	Ban().Controls.ApplyButton:Click()
	H.eq(#FAKE_UI.popups, n + 1)
	local d = LastDialog()
	H.eq(d.id, "TX_ConfirmApply")
	d.confirm()
	if not keepSave then
		H.eq(FAKE_TX.FinishSave(), 1, "the automatic save")
	end
	return d
end
-- The leave apply confirm: leave title and text (+ the hard leave line).
local function LeaveConfirm(d, pid, extra)
	H.eq(d.title, T("LOC_TX_APPLY_TITLE_LEAVE"))
	H.eq(d.title, "Apply the leave")
	H.eq(DialogText(d), T("LOC_TX_APPLY_CONFIRM_LEAVE", Label(pid)) .. (extra or ""))
	H.ok(string.find(DialogText(d), Label(pid) .. " leaves the team", 1, true) == 1)
	NoKickDialog(d)
end
-- The saved dialog of a leave: title and the text for this kind of game.
local function LeaveSaved(textKey)
	local name = SaveName()
	local r = LastDialog()
	H.eq(r.id, "TX_KickSaved")
	H.eq(r.title, T("LOC_TX_SAVED_TITLE_LEAVE"))
	H.eq(r.title, "Load the save to finish leaving")
	H.eq(DialogText(r), T(textKey, name))
	H.ok(string.find(DialogText(r), "Saved as " .. name .. ".", 1, true) == 1)
	H.ok(string.find(DialogText(r), "To finish leaving,", 1, true) ~= nil)
	NoKickDialog(r, name)
	H.eq(BannerText(), T("LOC_TX_BANNER_SAVED_LEAVE", name))
	H.eq(BannerText(), "Leave applied and saved as " .. name .. ". Everyone loads this save to finish it. Don't click leader portraits until then.")
	NoKick(BannerText(), "saved banner", name)
	return name
end

test("leave e2e soft: P2 leaves a team of 3: window line, banner, Apply, save, load, DONE, Team changed with the left text, history", function()
	USetup({ localPlayer = 2 })
	FAKE_TX.AllyTeam(0)
	LeaveVia("SOFT")
	-- the passed line in the window, the launch tooltip, the banner, the notification
	H.eq(C().VoteLabel.text, T("LOC_TX_LEAVE_PASSED_LINE", Label(2), SoftL()))
	H.ok(string.find(Launch().LaunchItemButton.tooltip, T("LOC_TX_LEAVE_PASSED_LINE", Label(2), SoftL()), 1, true) ~= nil)
	NoKick(C().VoteLabel.text, "passed line")
	local passed = Last(0, PASSED_N)
	H.eq(Message(passed), T("LOC_NOTIFICATION_TX_KICK_PASSED_LEAVE_MESSAGE"))
	H.eq(Summary(passed), T("LOC_NOTIFICATION_TX_KICK_PASSED_LEAVE_SUMMARY", Label(2), SoftL()))
	NoKick(Message(passed), "passed message")
	NoKick(Summary(passed), "passed summary")
	Poll()
	H.eq(BannerText(), T("LOC_TX_BANNER_HOST_LEAVE", Label(2)))
	H.eq(BannerText(), Label(2) .. " is leaving the team. Apply it, then load the save.")
	-- P0 (hotseat host) applies
	FAKE_TX.Hotseat(0)
	OpenWindow()
	H.eq(History()[1].text, T("LOC_TX_HIST_LEAVE_PENDING_APPLY", 1, Label(2), SoftL()))
	H.eq(History()[1].tip, T("LOC_TX_HIST_LEAVE_TT", Label(2)))
	NoKick(History()[1].text, "history row")
	NoKick(History()[1].tip, "history tooltip")
	local d = Apply(true)
	LeaveConfirm(d, 2)
	H.eq(Rec(1).applied, 1)
	H.len(FAKE_TX.saveCalls, 1)
	H.ok(string.find(SaveName(1), "TeamKick_", 1, true) == 1, "the save name keeps the mod's name")
	-- saving, then saved
	H.eq(BannerText(), T("LOC_TX_BANNER_SAVING_LEAVE"))
	H.eq(BannerText(), "Leave applied. Saving the game...")
	H.eq(FAKE_TX.FinishSave(), 1)
	local name = LeaveSaved("LOC_TX_SAVED_TEXT_HOTSEAT_LEAVE")
	-- the applied line in the window and the launch tooltip
	Win().Controls.CloseButton:Click()
	OpenWindow()
	H.eq(C().VoteLabel.text, T("LOC_TX_LEAVE_APPLIED_LINE", Label(2), SoftL()))
	H.ok(string.find(Launch().LaunchItemButton.tooltip, T("LOC_TX_LEAVE_APPLIED_LINE", Label(2), SoftL()), 1, true) ~= nil)
	NoKick(C().VoteLabel.text, "applied line")
	-- every local player sees the saved banner
	FAKE_TX.Hotseat(1)
	H.eq(BannerText(), T("LOC_TX_BANNER_SAVED_LEAVE", name))
	H.len(H.notifs(nil, DONE_N), 0, "nothing done before the load")
	-- the load
	ENVS = FAKE_TX.Reload()
	H.eq(Rec(1).state, "DONE")
	H.isnil(Rec(1).hardDone)
	H.len(FAKE_TX.diploCalls, 0, "no war for a soft leave")
	H.eq(FAKE_TX.DiploState(2, 0), "ALLIED")
	H.deq(PidsOf(H.notifs(nil, DONE_N)), HUMANS)
	for _, pid in ipairs(HUMANS) do
		local n = Last(pid, DONE_N)
		H.eq(Message(n), T("LOC_NOTIFICATION_TX_KICK_DONE_LEAVE_MESSAGE"))
		H.eq(Summary(n), T("LOC_NOTIFICATION_TX_KICK_DONE_LEAVE_SUMMARY", Label(2)))
		NoKick(Message(n), "done message")
		NoKick(Summary(n), "done summary")
	end
	H.ok(string.find(Summary(Last(0, DONE_N)), "left their team (soft)", 1, true) ~= nil)
	H.len(H.notifs(nil, HARD_DONE_N), 0)
	H.eq(Ban().Controls.Banner:IsHidden(), true)
	-- teams: P0 and P1 keep a team, P2 plays alone
	H.eq(Players[2]:GetTeam(), 6)
	FAKE_TX.Hotseat(0)
	OpenWindow()
	H.eq(History()[1].text, T("LOC_TX_HIST_LEAVE_DONE", 1, Label(2), SoftL()))
	H.ok(string.find(History()[1].text, "left the team (soft)", 1, true) ~= nil)
	NoKick(History()[1].text, "history row after the load")
	NoKick(History()[1].tip, "history tooltip after the load")
	FAKE_TX.Hotseat(2)
	H.eq(Launch().LaunchItemButton:IsHidden(), true, "P2 has no team any more")
	H.clean()
end)

test("leave e2e hard: P1 leaves hard: the apply confirm says hard leave; after the load P1 declares war and makes peace, the team holds the grievances, once", function()
	USetup({ localPlayer = 1 })
	FAKE_TX.AllyTeam(0)
	LeaveVia("HARD")
	H.eq(Rec(1).mode, "HARD")
	H.eq(Summary(Last(0, PASSED_N)), T("LOC_NOTIFICATION_TX_KICK_PASSED_LEAVE_SUMMARY", Label(1), HardL()))
	NoKick(Summary(Last(0, PASSED_N)), "passed summary")
	FAKE_TX.Hotseat(0)
	Poll()
	H.eq(BannerText(), T("LOC_TX_BANNER_HOST_LEAVE", Label(1)))
	local d = Apply(true)
	LeaveConfirm(d, 1, T("LOC_TX_APPLY_CONFIRM_HARD_LEAVE"))
	H.ok(string.find(DialogText(d), "This is a hard leave.", 1, true) ~= nil)
	H.eq(BannerText(), T("LOC_TX_BANNER_SAVING_LEAVE"))
	FAKE_TX.FinishSave()
	LeaveSaved("LOC_TX_SAVED_TEXT_HOTSEAT_LEAVE")
	H.len(FAKE_TX.diploCalls, 0, "nothing before the load")
	ENVS = FAKE_TX.Reload()
	H.eq(Rec(1).state, "DONE")
	H.eq(Rec(1).hardDone, 1)
	local order = {}
	for _, call in ipairs(FAKE_TX.diploCalls) do
		order[#order + 1] = call.fn .. " " .. call.a .. ">" .. call.b .. " " .. call.context
	end
	H.deq(order, { "DeclareWarOn 1>0 G", "MakePeaceWith 1>0 G" }, "the leaver declares")
	H.eq(FAKE_TX.DiploState(1, 0), "UNFRIENDLY")
	H.eq(FAKE_TX.DiploState(1, 2), "UNFRIENDLY")
	H.eq(FAKE_TX.Grievance(0, 1), 100, "the team holds the grievances against the leaver")
	H.eq(FAKE_TX.Grievance(1, 0), 0)
	H.deq(PidsOf(H.notifs(nil, HARD_DONE_N)), HUMANS)
	for _, pid in ipairs(HUMANS) do
		local n = Last(pid, HARD_DONE_N)
		H.eq(Message(n), T("LOC_NOTIFICATION_TX_HARD_KICK_DONE_LEAVE_MESSAGE"))
		H.eq(Summary(n), T("LOC_NOTIFICATION_TX_HARD_KICK_DONE_LEAVE_SUMMARY", Label(1), T("LOC_TX_HARD_OUTCOME_OK")))
		NoKick(Message(n), "hard done message")
		NoKick(Summary(n), "hard done summary")
	end
	H.len(H.notifs(nil, DONE_N), 0)
	-- run once: more reports, another load, turns
	local calls, count = #FAKE_TX.diploCalls, #FAKE.notifications
	FAKE_TX.Hotseat(2)
	Events.PlayerTurnActivated(2, true)
	ENVS = FAKE_TX.Reload()
	FAKE_UI.AsGameplay(H.endTurn)
	H.eq(#FAKE_TX.diploCalls, calls)
	H.eq(#FAKE.notifications, count)
	FAKE_TX.Hotseat(0)
	OpenWindow()
	H.eq(History()[1].text, T("LOC_TX_HIST_LEAVE_DONE", 1, Label(1), HardL()))
	NoKick(History()[1].text, "history row")
	H.clean()
end)

test("leave e2e 2: a team of 2: P3 leaves its AI teammate (soft): the team dissolves after the load, no Team button for P3", function()
	USetup({ localPlayer = 3 })
	LeaveVia("SOFT")
	H.eq(Rec(1).teamID, 1)
	H.eq(Rec(1).newTeamID, 6)
	Poll()
	local d = Apply()
	LeaveConfirm(d, 3)
	LeaveSaved("LOC_TX_SAVED_TEXT_HOTSEAT_LEAVE")
	ENVS = FAKE_TX.Reload()
	H.eq(Rec(1).state, "DONE")
	H.eq(Players[3]:GetTeam(), 6)
	H.eq(Players[4]:GetTeam(), 1)
	FAKE_TX.Hotseat(3)
	H.eq(Launch().LaunchItemButton:IsHidden(), true)
	H.clean()
end)

test("leave e2e online: network MP: the apply confirm adds the online load steps; the saved dialog has the online leave text", function()
	USetup({ netMP = true, localPlayer = 2 })
	FAKE_TX.AllyTeam(0)
	LeaveVia("HARD")
	local d = Apply(true)
	LeaveConfirm(d, 2, T("LOC_TX_APPLY_CONFIRM_HARD_LEAVE") .. T("LOC_TX_APPLY_CONFIRM_NETMP"))
	H.eq(BannerText(), T("LOC_TX_BANNER_SAVING_LEAVE"))
	FAKE_TX.FinishSave()
	LeaveSaved("LOC_TX_SAVED_TEXT_NETMP_LEAVE")
	H.ok(string.find(DialogText(LastDialog()), "Multiplayer > Host Game > Load Game", 1, true) ~= nil)
	H.clean()
end)

test("leave e2e local: a single machine (neither hotseat nor network MP): the saved dialog has the local leave text", function()
	USetup({ hotseat = false, localPlayer = 2 })
	LeaveVia("SOFT")
	LeaveConfirm(Apply(), 2)
	LeaveSaved("LOC_TX_SAVED_TEXT_LOCAL_LEAVE")
	H.ok(string.find(DialogText(LastDialog()), "To finish leaving, load this save: Menu > Load Game.", 1, true) ~= nil)
	H.clean()
end)

-- The save failed: the manual reload dialog and the reload banner, in the leave version.
for _, case in ipairs({
	{ name = "hotseat", opts = {}, key = "LOC_TX_RELOAD_TEXT_LEAVE" },
	{ name = "network MP", opts = { netMP = true }, key = "LOC_TX_RELOAD_TEXT_NETMP_LEAVE" },
	{ name = "single machine", opts = { hotseat = false }, key = "LOC_TX_RELOAD_TEXT_LOCAL_LEAVE" },
}) do
	test("leave e2e save failed (" .. case.name .. "): the manual reload dialog and the reload banner say leave", function()
		local opts = { saveFail = true, localPlayer = 2 }
		for _, k in ipairs(FAKE.SortedKeys(case.opts)) do opts[k] = case.opts[k] end
		USetup(opts)
		LeaveVia("SOFT")
		local extra = nil
		if case.opts.netMP then extra = T("LOC_TX_APPLY_CONFIRM_NETMP") end
		LeaveConfirm(Apply(true), 2, extra)
		local r = LastDialog()
		H.eq(r.id, "TX_ReloadNow")
		H.eq(r.title, T("LOC_TX_RELOAD_TITLE"))
		H.eq(DialogText(r), T(case.key))
		H.ok(string.find(DialogText(r), "The leave is applied, but the game couldn't save itself.", 1, true) == 1)
		NoKickDialog(r)
		H.eq(BannerText(), T("LOC_TX_BANNER_RELOAD_LEAVE"))
		H.ok(string.find(BannerText(), "Leave applied. Everyone loads the save made for it", 1, true) == 1)
		NoKick(BannerText(), "reload banner")
		H.eq(Rec(1).applied, 1, "the leave stays applied")
	end, { allowErrors = true })
end

test("leave e2e reload banner: a fresh UI (another Lua state) before the load shows the leave reload banner", function()
	USetup({ localPlayer = 2 })
	LeaveVia("SOFT")
	Apply()
	LeaveSaved("LOC_TX_SAVED_TEXT_HOTSEAT_LEAVE")
	-- a UI that did not make the save (no saved name in its Lua state): the reload banner
	ENVS = FAKE_TX.LoadUI()
	Poll()
	H.eq(BannerText(), T("LOC_TX_BANNER_RELOAD_LEAVE"))
	NoKick(BannerText(), "reload banner")
	H.clean()
end)

test("leave e2e not host: the wait banner says leaving; no Apply", function()
	USetup({ host = false, localPlayer = 2 })
	LeaveVia("SOFT")
	Poll()
	H.eq(BannerText(), T("LOC_TX_BANNER_WAIT_LEAVE", Label(2)))
	H.eq(BannerText(), Label(2) .. " is leaving the team. Waiting for the host to apply it.")
	H.eq(Ban().Controls.ApplyButton:IsHidden(), true)
	H.clean()
end)

test("leave e2e apply failed: gameplay does not see the write: the failed dialog says leave; Apply again", function()
	USetup({ split = false, localPlayer = 2 })
	LeaveVia("SOFT")
	Apply(true)
	local d = LastDialog()
	H.eq(d.id, "TX_ApplyFailed")
	H.eq(d.title, T("LOC_TX_APPLY_FAILED_TITLE_LEAVE"))
	H.eq(d.title, "Leave not applied")
	H.eq(DialogText(d), T("LOC_TX_APPLY_FAILED_TEXT"))
	NoKickDialog(d)
	H.eq(Rec(1).applied, 0)
	H.eq(BannerText(), T("LOC_TX_BANNER_HOST_LEAVE", Label(2)))
end, { allowErrors = true })

test("leave e2e conflict: the new team number is taken: the conflict dialog has the leave title", function()
	USetup({ localPlayer = 2 })
	LeaveVia("SOFT")
	Poll()
	H.team(5, 6)                              -- P5 now uses team 6
	Ban().Controls.ApplyButton:Click()
	local d = LastDialog()
	H.eq(d.id, "TX_ApplyConflict")
	H.eq(d.title, T("LOC_TX_APPLY_TITLE_LEAVE"))
	H.eq(DialogText(d), T("LOC_TX_APPLY_CONFLICT_TEXT"))
	NoKickDialog(d)
	H.len(FAKE.teamSets, 0)
	H.clean()
end)

test("leave e2e kick and leave in one game: the kick record keeps the kick texts, the leave record gets the leave texts", function()
	USetup({ localPlayer = 3 })
	FAKE_TX.AllyTeam(0)
	-- rec 1: P3 kicks its AI teammate P4 (AI only: passes at once); rec 2: P2 leaves hard
	H.request(3, { OnStart = "TX_Propose", targetID = 4, mode = "SOFT" })
	H.request(2, { OnStart = "TX_Leave", mode = "HARD" })
	H.eq(Rec(1).kind, "KICK")
	H.eq(Rec(1).state, "PENDING_APPLY")
	H.eq(Rec(2).kind, "LEAVE")
	H.eq(Rec(2).state, "PENDING_APPLY")
	H.eq(Summary(Last(0, PASSED_N)), T("LOC_NOTIFICATION_TX_KICK_PASSED_LEAVE_SUMMARY", Label(2), HardL()))
	H.eq(Summary(Last(3, PASSED_N)), T("LOC_NOTIFICATION_TX_KICK_PASSED_LEAVE_SUMMARY", Label(2), HardL()))
	H.eq(#H.notifs(3, PASSED_N) >= 2, true)
	-- the kick first (the banner takes the lowest id): kick texts
	Poll()
	H.eq(BannerText(), T("LOC_TX_BANNER_HOST", Label(4)))
	local d = Apply(true)
	H.eq(d.title, T("LOC_TX_APPLY_TITLE"))
	H.eq(DialogText(d), T("LOC_TX_APPLY_CONFIRM", Label(4)))
	H.eq(BannerText(), T("LOC_TX_BANNER_SAVING"))
	FAKE_TX.FinishSave()
	local kickName = SaveName(1)
	H.eq(LastDialog().title, T("LOC_TX_SAVED_TITLE"))
	H.eq(DialogText(LastDialog()), T("LOC_TX_SAVED_TEXT_HOTSEAT", kickName))
	H.eq(BannerText(), T("LOC_TX_BANNER_SAVED", kickName))
	-- the leave from P3's newest KICK_PASSED (the host's click opens Apply): leave texts
	FAKE_TX.Activate(3, PASSED_N)
	d = LastDialog()
	H.eq(d.id, "TX_ConfirmApply")
	LeaveConfirm(d, 2, T("LOC_TX_APPLY_CONFIRM_HARD_LEAVE"))
	d.confirm()
	H.eq(FAKE_TX.FinishSave(), 1)
	H.len(FAKE_TX.saveCalls, 2)
	local r = LastDialog()
	H.eq(r.title, T("LOC_TX_SAVED_TITLE_LEAVE"))
	H.eq(DialogText(r), T("LOC_TX_SAVED_TEXT_HOTSEAT_LEAVE", SaveName(2)))
	H.eq(BannerText(), T("LOC_TX_BANNER_SAVED", kickName), "the banner still shows the kick, in kick words")
	-- the load: the kick's KICK_DONE in kick words, the leave's HARD_KICK_DONE in leave words
	ENVS = FAKE_TX.Reload()
	H.eq(Rec(1).state, "DONE")
	H.eq(Rec(2).state, "DONE")
	H.eq(Summary(Last(0, DONE_N)), T("LOC_NOTIFICATION_TX_KICK_DONE_SUMMARY", Label(4)))
	H.eq(Message(Last(0, HARD_DONE_N)), T("LOC_NOTIFICATION_TX_HARD_KICK_DONE_LEAVE_MESSAGE"))
	H.eq(Summary(Last(0, HARD_DONE_N)), T("LOC_NOTIFICATION_TX_HARD_KICK_DONE_LEAVE_SUMMARY", Label(2), T("LOC_TX_HARD_OUTCOME_OK")))
	-- history: each team sees its own record in its own words
	FAKE_TX.Hotseat(0)
	OpenWindow()
	H.eq(History()[1].text, T("LOC_TX_HIST_LEAVE_DONE", 1, Label(2), HardL()))
	H.clean()
end)

-- ===========================================================================
-- Static: no text a LEAVE record can show says "kick"
-- ===========================================================================
test("leave texts: every key that says kick has a leave version or is never shown for a LEAVE record; no leave text says kick", function()
	local xml = __py_read("TX/Data/TX_Text.xml")
	local text, order = {}, {}
	for tag, body in string.gmatch(xml, '<Row Tag="([%w_]+)" Language="en_US">%s*<Text>(.-)</Text>') do
		text[tag] = body
		order[#order + 1] = tag
	end
	-- Shown only for a kick (or the mod's name); the leave path uses the key on the right.
	local KICK_ONLY = {
		LOC_TX_LAUNCH_TT = "the mod's name (Team Kick)",
		LOC_TX_WINDOW_TITLE = "the mod's name (Team Kick)",
		LOC_TX_KICK = "Kick button",
		LOC_TX_KICK_TT = "Kick button",
		LOC_TX_CONFIRM_TITLE = "kick confirm",
		LOC_TX_CONFIRM_VOTE = "kick confirm",
		LOC_TX_MODE_SOFT = "kick confirm",
		LOC_TX_MODE_HARD = "kick confirm",
		LOC_TX_MODE_SOFT_INFO = "kick confirm",
		LOC_TX_MODE_SOFT_SHORT = "LOC_TX_LEAVE_SOFT_SHORT",
		LOC_TX_MODE_HARD_SHORT = "LOC_TX_LEAVE_HARD_SHORT",
		LOC_TX_VOTE_LINE = "open vote (a LEAVE record is never OPEN)",
		LOC_TX_HIST_DONE = "LOC_TX_HIST_LEAVE_DONE",
		LOC_TX_HIST_FAILED = "a vote (a LEAVE record never fails)",
		LOC_TX_HIST_EXPIRED = "a vote (a LEAVE record never expires)",
		LOC_TX_HIST_CANCELLED = "LOC_TX_HIST_LEAVE_CANCELLED",
		LOC_TX_POPUP_TEXT = "vote popup",
		LOC_TX_POPUP_YES = "vote popup",
		LOC_NOTIFICATION_TX_VOTE_REQUIRED_SUMMARY = "a vote",
		LOC_TX_REASON_TARGET_SELF = "kick request",
		LOC_TX_REASON_TARGET_INVALID = "kick request",
	}
	local said = 0
	for _, tag in ipairs(order) do
		local kick = string.find(string.lower(text[tag]), "kick", 1, true) ~= nil
		local leaveTag = string.find(tag, "_LEAVE", 1, true) ~= nil or string.find(tag, "LOC_TX_LEAVE_", 1, true) == 1
		if leaveTag then
			H.ok(not kick, tag .. " (a leave text) says kick")
		elseif kick then
			said = said + 1
			local variant = text[tag .. "_LEAVE"] ~= nil
			local base, suffix = string.match(tag, "^(LOC_NOTIFICATION_TX_[%w_]-)_(%u+)$")
			if base ~= nil and (suffix == "MESSAGE" or suffix == "SUMMARY") then
				variant = text[base .. "_LEAVE_" .. suffix] ~= nil
			end
			local other = KICK_ONLY[tag]
			if other ~= nil and string.find(other, "LOC_", 1, true) == 1 then
				H.ok(text[other] ~= nil, tag .. ": " .. other .. " exists")
			end
			H.ok(variant or other ~= nil, tag .. " says kick and has no leave version: " .. text[tag])
		end
	end
	H.ok(said > 20, "the check saw the kick texts")
	-- the leave keys TX_ApplyBanner picks for a LEAVE record are all defined
	local src = __py_read("TX/UI/TX_ApplyBanner.lua")
	local n = 0
	for kick, leave in string.gmatch(src, '\n\t(LOC_TX_[%w_]+) = "(LOC_TX_[%w_]+)",') do
		H.eq(leave, kick .. "_LEAVE")
		H.ok(text[kick] ~= nil and text[leave] ~= nil, leave)
		n = n + 1
	end
	H.eq(n, 16, "TX_ApplyBanner LEAVE_TEXT entries")
	H.eq(text.LOC_TX_LEAVE_ARMED, "Confirm")
	H.isnil(text.LOC_TX_LEAVE_SOFT_ARMED)
	H.isnil(text.LOC_TX_LEAVE_HARD_ARMED)
end)
