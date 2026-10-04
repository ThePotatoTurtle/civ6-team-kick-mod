-- Tests of TX/Scripts/TX_Store.lua (PLAN II.14 "test_tx_store.lua"), plus
-- TX_Config, TX_Util and the TX fake (tests/offline/lib/fake_txworld.lua),
-- which build chunk A (PLAN II.16) also delivers.

local function Load()
	include("TX_Store")
end

local function Rec(fields)
	local r = {
		teamID = 0, proposerID = 0, targetID = 1,
		voters = { { pid = 0, v = "YES" }, { pid = 2, v = "PENDING" } },
		openedTurn = 3, expiresTurn = 8, state = "OPEN", mode = "SOFT",
	}
	for _, k in ipairs(FAKE.SortedKeys(fields or {})) do
		r[k] = fields[k]
	end
	return r
end

local function Writes(key)
	return FAKE.propWrites[key] or 0
end

-- ---------------------------------------------------------------------------
-- TX_Config, TX_Util
-- ---------------------------------------------------------------------------
test("config: version 0.1.0 matches the modinfo title and description", function()
	include("TX_Config")
	H.eq(TX_Config.VERSION, "0.1.0")
	local mi = __py_read("TX/TX.modinfo")
	H.ok(string.find(mi, "<en_US>Team Kick v" .. TX_Config.VERSION .. "</en_US>", 1, true), "modinfo title")
	H.ok(string.find(mi, "Version " .. TX_Config.VERSION .. ".[NEWLINE]", 1, true), "modinfo description")
	H.eq(TX_Config.VOTE_TURNS, 5)
	H.eq(TX_Config.MAX_TEAM_ID, 63)
	H.eq(TX_Config.REQ_PROPOSE, "TX_Propose")
	H.eq(TX_Config.ALLOW_NETWORK_APPLY, true)
	H.eq(TX_Config.AUTO_RELOAD, false)
	-- the load-once guard keeps a changed value
	TX_Config.VOTE_TURNS = 9
	include("TX_Config")
	H.eq(TX_Config.VOTE_TURNS, 9)
end)

test("config: notification names match the SQL types", function()
	include("TX_Config")
	for _, k in ipairs(FAKE.SortedKeys(TX_Config.NOTIF)) do
		H.notnil(GameInfo.Types[TX_Config.NOTIF[k]], TX_Config.NOTIF[k])
		H.notnil(FAKE_TEXT["LOC_" .. TX_Config.NOTIF[k] .. "_MESSAGE"])
		H.notnil(FAKE_TEXT["LOC_" .. TX_Config.NOTIF[k] .. "_SUMMARY"])
	end
end)

test("util: log shape, level filter and the ERROR prefix", function()
	include("TX_Util")
	FAKE.turn = 7
	TX_Util.Log(2, "Votes", "rec=%d %s", 3, "open")
	TX_Util.Log(3, "Votes", "verbose")
	TX_Util.Log(2, "Votes", "%d bad format", "x")
	TX_Util.Log(2, "Votes", "plain %d")
	local lines = H.lines("[TX]")
	H.len(lines, 3)
	H.eq(lines[1], "[TX][T7][Votes] rec=3 open")
	local prefix = "[TX][T7][Votes] %d bad format [format error: "
	H.eq(string.sub(lines[2], 1, string.len(prefix)), prefix, "a format error is logged raw")
	H.eq(lines[3], "[TX][T7][Votes] plain %d", "no format without arguments")
	TX_Config.LOG_LEVEL = 3
	TX_Util.Log(3, "Votes", "verbose")
	H.ok(H.hasLine("[TX][T7][Votes] verbose"))
	TX_Util.Log(1, "Store", "boom")
	H.ok(H.hasLine("[TX][T7][Store] ERROR boom"))
	H.len(H.errorLines(), 1, "the runner sees the ERROR line")
end, { allowErrors = true })

test("util: SortedKeys, DeepCopy, B01, Str, Turn", function()
	include("TX_Util")
	H.deq(TX_Util.SortedKeys({ b = 1, a = 2, [3] = 0, [1] = 0 }), { 1, 3, "a", "b" })
	H.deq(TX_Util.SortedKeys(nil), {})
	local src = { a = { 1, 2, { x = "y" } }, n = 5 }
	local c = TX_Util.DeepCopy(src)
	H.deq(c, src)
	c.a[3].x = "z"
	H.eq(src.a[3].x, "y", "the copy is deep")
	local deep = {}
	local cur = deep
	for _ = 1, 30 do
		cur.k = {}
		cur = cur.k
	end
	H.throws(function() TX_Util.DeepCopy(deep) end, "nesting guard")
	H.isnil(TX_Util.B01(nil))
	H.eq(TX_Util.B01(true), 1)
	H.eq(TX_Util.B01(false), 0)
	H.eq(TX_Util.B01(0), 0, "a stored 0 stays 0")
	H.eq(TX_Util.B01(1), 1)
	H.eq(TX_Util.Str(nil), "nil")
	H.eq(TX_Util.Str(4), "4")
	FAKE.turn = 12
	H.eq(TX_Util.Turn(), 12)
	Game.GetCurrentGameTurn = function() error("no game") end
	H.eq(TX_Util.Turn(), -1)
	H.clean()
end)

-- ---------------------------------------------------------------------------
-- TX_Store
-- ---------------------------------------------------------------------------
test("store 1: no property gives a fresh store and writes nothing", function()
	Load()
	FAKE.turn = 4
	local store, repaired = TX_Store.Load()
	H.deq(store, { schema = 1, nextID = 1, lastTurn = 3, ids = {}, recs = {} })
	H.eq(repaired, false)
	H.eq(TX_Store.Rev(), 0)
	H.deq(FAKE.propWrites, {})
	H.clean()
end)

test("store 2: Commit writes TX_Store and TX_Rev + 1 with no storage violation", function()
	Load()
	local store = TX_Store.Load()
	TX_Store.Add(store, Rec())
	H.eq(TX_Store.Commit(store), true)
	H.eq(H.prop("TX_Rev"), 1)
	H.eq(Writes("TX_Store"), 1)
	H.eq(H.prop("TX_Store").nextID, 2)
	H.eq(TX_Store.Commit(TX_Store.Load()), true)
	H.eq(H.prop("TX_Rev"), 2)
	H.eq(TX_Store.Rev(), 2)
	H.deq(FAKE.propViolations, {})
	H.clean()
end)

test("store 3: empty tables are left out on write and restored by Load", function()
	Load()
	FAKE.turn = 10
	local store = TX_Store.Fresh(10)
	local shaped = TX_Store.Shape(store)
	H.deq(shaped, { schema = 1, nextID = 1, lastTurn = 9 })
	H.deq(TX_Store.Check(shaped), {})
	TX_Store.Commit(store)
	H.deq(H.prop("TX_Store"), { schema = 1, nextID = 1, lastTurn = 9 })
	local back, repaired = TX_Store.Load()
	H.deq(back, store)
	H.eq(repaired, false)
	-- an empty string and a nested empty table go too
	local r = Rec({ reason = "" })
	r.extra = { {}, { a = {} } }
	H.deq(TX_Store.Shape(r).extra, nil)
	H.isnil(TX_Store.Shape(r).reason)
	H.deq(FAKE.propViolations, {})
	H.clean()
end)

test("store 4: full round trip under dropEmpty; a loaded store is a copy", function()
	Load()
	H.eq(FAKE.dropEmpty, true)
	local store = TX_Store.Fresh(1)
	TX_Store.Add(store, Rec())
	TX_Store.Add(store, Rec({ state = "PENDING_APPLY", closedTurn = 5, newTeamID = 10, applied = 0 }))
	TX_Store.Add(store, Rec({ state = "CANCELLED", reason = "NO_FREE_TEAM", closedTurn = 6 }))
	TX_Store.Add(store, Rec({ state = "DONE", closedTurn = 5, newTeamID = 11, applied = 1, appliedTurn = 6, appliedBy = 2, doneTurn = 7,
		voters = { { pid = 0, v = "YES" }, { pid = 2, v = "YES" }, { pid = 7, v = "GONE" } } }))
	store.victoryTurn = 9
	store.victoryTeam = 0
	H.eq(TX_Store.Commit(store), true)
	local back, repaired = TX_Store.Load()
	H.deq(back, store)
	H.eq(repaired, false)
	H.eq(TX_Store.Get(back, 2).applied, 0, "0 survives")
	-- changes reach the property only at Commit
	back.recs.r1.state = "FAILED"
	TX_Store.Get(back, 1).voters[2].v = "NO"
	H.eq(H.prop("TX_Store").recs.r1.state, "OPEN")
	-- also when GetProperty hands out a live reference (EFV T03)
	Game.GetProperty = function(self, k) return FAKE.props[k] end
	local live = TX_Store.Load()
	live.recs.r1.state = "FAILED"
	live.ids[1] = 99
	H.eq(FAKE.props.TX_Store.recs.r1.state, "OPEN")
	H.eq(FAKE.props.TX_Store.ids[1], 1)
	H.deq(FAKE.propViolations, {})
	H.clean()
end)

test("store 5: repair: ids rebuilt from the record keys, nextID raised, malformed records dropped", function()
	Load()
	FAKE.props.TX_Store = {
		schema = 1, nextID = 2, lastTurn = 4, ids = { 1 },
		recs = {
			r1 = Rec({ id = 1 }), r3 = Rec({ id = 3, state = "FAILED", reason = "NO_VOTE" }), r5 = Rec({ id = 4 }),
			r7 = Rec({ state = "WEIRD" }), x9 = Rec(), r8 = Rec({ state = "PENDING_APPLY" }),
			r6 = Rec({ voters = {} }),
		},
	}
	local store, repaired = TX_Store.Load()
	H.eq(repaired, true)
	H.deq(store.ids, { 1, 3, 5 })
	H.eq(store.nextID, 6)
	H.eq(store.recs.r5.id, 5, "id fixed from the key")
	H.isnil(store.recs.r7)
	H.isnil(store.recs.r8, "PENDING_APPLY without newTeamID")
	H.isnil(store.recs.r6, "no voters")
	H.isnil(store.recs.x9)
	H.ok(H.hasLine("[Store] ERROR normalize: ids disagree"))
	H.ok(H.hasLine("[Store] ERROR normalize: nextID=2 not above the highest id 5; raised to 6"))
	H.ok(H.hasLine("ERROR normalize: dropped malformed record key=r7 (unknown state WEIRD)"))
	H.ok(H.hasLine("ERROR normalize: dropped malformed record key=x9 (bad key)"))
	H.ok(H.hasLine("ERROR normalize: record key=r5 had id=4; fixed"))
	H.eq(TX_Store.Commit(store), true)
	local again, rep2 = TX_Store.Load()
	H.eq(rep2, false, "the commit saved the repair")
	H.deq(again, store)
	-- pure Normalize: nil is a fresh store, a non-table is replaced
	local fresh, r0 = TX_Store.Normalize(nil, 3)
	H.deq(fresh, TX_Store.Fresh(3))
	H.eq(r0, false)
	local _, r1 = TX_Store.Normalize("junk", 3)
	H.eq(r1, true)
	-- a PENDING_APPLY record without applied gets 0
	local fixed = TX_Store.Normalize({ schema = 1, nextID = 2, lastTurn = 1, ids = { 1 },
		recs = { r1 = Rec({ id = 1, state = "PENDING_APPLY", newTeamID = 6 }) } }, 3)
	H.eq(fixed.recs.r1.applied, 0)
	H.deq(FAKE.propViolations, {})
end, { allowErrors = true })

test("store 6: booleans become 0/1; Check refuses mixed tables and holes; a broken store is never committed", function()
	Load()
	local store = TX_Store.Fresh(1)
	TX_Store.Add(store, Rec({ state = "PENDING_APPLY", newTeamID = 6, applied = true }))
	H.eq(TX_Store.Commit(store), true)
	H.eq(H.prop("TX_Store").recs.r1.applied, 1)
	H.eq(TX_Store.Load().recs.r1.applied, 1)
	local rev = H.prop("TX_Rev")
	local writes = Writes("TX_Store")
	-- a mixed table
	local bad = TX_Store.Load()
	bad.recs.r1.voters.extra = "x"
	H.eq(TX_Store.Commit(bad), false)
	H.ok(H.hasLine("ERROR commit refused, 1 storage problem(s): store.recs.r1.voters: mixed string and number keys"))
	-- an array with a hole
	local holes = TX_Store.Load()
	holes.ids = { [1] = 1, [3] = 3 }
	H.eq(TX_Store.Commit(holes), false)
	H.ok(H.hasLine("array with holes"))
	H.deq(TX_Store.Check({ ids = { [0] = 1 } }), { "store.ids: key 0" })
	H.deq(TX_Store.Check({ a = 0 / 0 }), { "store.a: not a finite number" })
	H.deq(TX_Store.Check({ a = {} }), { "store.a: empty table" })
	H.deq(TX_Store.Check({ a = "" }), { "store.a: empty string" })
	H.deq(TX_Store.Check({ a = true }), { "store.a: boolean value (store 0/1)" })
	-- a function is dropped with an ERROR, the rest is written
	local fn = TX_Store.Load()
	fn.recs.r1.callback = function() end
	H.eq(TX_Store.Commit(fn), true)
	H.ok(H.hasLine("ERROR shape: dropped store.recs.r1.callback (type function, not storable)"))
	H.isnil(H.prop("TX_Store").recs.r1.callback)
	rev = rev + 1
	writes = writes + 1
	-- a store that could not be read
	local realGet = Game.GetProperty
	Game.GetProperty = function(self, k)
		if k == "TX_Store" then error("read failed") end
		return realGet(self, k)
	end
	local broken = TX_Store.Load()
	H.eq(broken.broken, 1)
	H.ok(H.hasLine("ERROR load: cannot read TX_Store"))
	TX_Store.Add(broken, Rec())
	H.eq(TX_Store.Commit(broken), false)
	H.ok(H.hasLine("ERROR commit refused: the store could not be read in this handler (broken)"))
	H.eq(H.prop("TX_Rev"), rev, "TX_Rev unchanged by refused commits")
	H.eq(Writes("TX_Store"), writes, "nothing written by refused commits")
	H.deq(FAKE.propViolations, {})
end, { allowErrors = true })

test("store 7: the UI reads the store; it never commits; Trim keeps open records", function()
	Load()
	local store = TX_Store.Fresh(1)
	for i = 1, 3 do
		TX_Store.Add(store, Rec({ state = "FAILED", reason = "NO_VOTE", closedTurn = i }))
	end
	TX_Store.Add(store, Rec({ teamID = 1, proposerID = 3, targetID = 4 }))
	TX_Store.Add(store, Rec({ state = "DONE", closedTurn = 4, newTeamID = 6, applied = 1, appliedTurn = 4, appliedBy = 0, doneTurn = 5 }))
	TX_Store.Add(store, Rec({ teamID = 2, state = "PENDING_APPLY", closedTurn = 5, newTeamID = 7, applied = 0 }))
	TX_Store.Add(store, Rec({ teamID = 3, state = "PASSED", closedTurn = 6 }))
	TX_Store.Add(store, Rec({ state = "EXPIRED", closedTurn = 8 }))
	H.eq(TX_Store.Commit(store), true)
	FAKE_UI.Enable()
	H.notnil(UI)
	local ui, repaired = TX_Store.Load()
	H.deq(ui, store)
	H.eq(repaired, false)
	H.eq(TX_Store.Rev(), 1)
	H.eq(TX_Store.Commit(ui), false)
	H.ok(H.hasLine("ERROR commit refused: the UI never writes the store"))
	H.eq(TX_Store.Rev(), 1)
	-- Trim: 5 closed records, keep 2: the 3 oldest closed go
	H.eq(TX_Store.Trim(ui, 2), 3)
	H.deq(ui.ids, { 4, 5, 6, 7, 8 })
	H.eq(TX_Store.Get(ui, 4).state, "OPEN")
	H.eq(TX_Store.Get(ui, 6).state, "PENDING_APPLY")
	H.eq(TX_Store.Get(ui, 7).state, "PASSED")
	H.isnil(TX_Store.Get(ui, 1))
	H.eq(TX_Store.Trim(ui, 2), 0)
	H.eq(TX_Store.Trim(ui, 0), 2)
	H.deq(ui.ids, { 4, 6, 7 }, "open, pending and passed records are never dropped")
	H.eq(#TX_Store.Records(ui), 3)
	H.eq(TX_Store.Get(ui, "6").newTeamID, 7, "a numeric string id works")
	H.isnil(TX_Store.Get(ui, "x"))
end, { allowErrors = true })

-- ---------------------------------------------------------------------------
-- fake_txworld.lua (the TX fake itself)
-- ---------------------------------------------------------------------------
local function FakeWorld(opts)
	FAKE.dofile("tests/offline/lib/fake_txworld.lua")
	return FAKE_TX.World(opts)
end

test("fake_txworld: standard world, teams numbered like F5, empty slots, leader names", function()
	FakeWorld()
	H.deq(FAKE.TeamMembers(0), { 0, 1, 2 })
	H.deq(FAKE.TeamMembers(1), { 3, 4 })
	H.eq(Players[5]:GetTeam(), 2)
	H.eq(Players[6]:GetTeam(), 3)
	H.eq(Players[62]:GetTeam(), 4)
	H.eq(Players[63]:GetTeam(), 5)
	H.eq(Players[30]:GetTeam(), -1)
	H.eq(Players[30]:IsAlive(), false)
	H.eq(Players[30]:IsMajor(), false)
	H.eq(Players[4]:IsHuman(), false)
	H.eq(Players[3]:IsHuman(), true)
	H.eq(PlayerConfigurations[2]:GetLeaderName(), "LOC_LEADER_FAKE_2_NAME")
	H.eq(Players[0]:GetDiplomacy():HasMet(5), true)
	-- a config object made after Install still gets GetLeaderName
	FAKE.NewPlayer(9, { human = true, team = 0 })
	H.eq(PlayerConfigurations[9]:GetLeaderName(), "LOC_LEADER_FAKE_9_NAME")
	H.eq(Network.IsGameHost(), true)
	H.eq(Network.GetGameHostPlayerID(), 0)
	H.eq(GameConfiguration.IsNetworkMultiplayer(), false)
	H.eq(GameConfiguration.IsHotseat(), true)
	FakeWorld({ host = false, netMP = true, hotseat = false, met = false })
	H.eq(Network.IsGameHost(), false)
	H.eq(GameConfiguration.IsNetworkMultiplayer(), true)
	H.eq(GameConfiguration.IsHotseat(), false)
end)

test("fake_txworld: split model: gameplay reads the config write at once, the UI after a load (F1 to F4)", function()
	FakeWorld()
	FAKE_UI.Enable()
	PlayerConfigurations[1]:SetTeam(6)
	H.eq(Players[1]:GetTeam(), 0, "UI live team stays old (F3)")
	H.eq(PlayerConfigurations[1]:GetTeam(), 6, "config team changed at once (F1)")
	local inG
	FAKE_UI.AsGameplay(function() inG = Players[1]:GetTeam() end)
	H.eq(inG, 6, "gameplay reads the new team at once (F2)")
	TX_Config = { stale = 1 }
	FAKE_TX.Reload()
	H.eq(Players[1]:GetTeam(), 6, "after a load the UI agrees (F4)")
	-- The load drops the TX globals; since chunk B the gameplay script runs
	-- again and includes fresh modules (and registers its handlers once).
	H.ok(TX_Config == nil or TX_Config.stale == nil, "a load drops the TX globals")
	if FAKE_TX.Exists(FAKE_TX.GAMEPLAY) then
		H.eq(GameEvents.TX_Propose.Count(), 1, "gameplay ran again after the load")
	end
end)

test("fake_txworld: split = false: gameplay does not see the config write either", function()
	FakeWorld({ split = false })
	PlayerConfigurations[1]:SetTeam(6)
	H.eq(FAKE.context, "G")
	H.eq(Players[1]:GetTeam(), 0)
	H.reload({}, {}, { applyConfigTeams = true })
	H.eq(Players[1]:GetTeam(), 6)
end)

test("fake_txworld: Hotseat, Activate, LoadUI with the contexts of later chunks missing", function()
	FakeWorld()
	local changed = {}
	Events.LocalPlayerChanged.Add(function(now, prev) changed[#changed + 1] = prev .. ">" .. now end)
	FAKE_TX.Hotseat(2)
	H.eq(FAKE.localPlayer, 2)
	H.deq(changed, { "0>2" })
	local hits = {}
	Events.NotificationActivated.Add(function(pid, nid, byUser) hits[#hits + 1] = pid .. ":" .. nid .. ":" .. tostring(byUser) end)
	local hash = GameInfo.Types["NOTIFICATION_TX_VOTE_REQUIRED"].Hash
	NotificationManager.SendNotification(2, hash, {})
	local newest = NotificationManager.SendNotification(2, hash, {})
	NotificationManager.SendNotification(0, hash, {})
	H.eq(FAKE_TX.Activate(2, "NOTIFICATION_TX_VOTE_REQUIRED"), newest)
	H.deq(hits, { "2:" .. newest .. ":true" })
	H.isnil(FAKE_TX.Activate(2, "NOTIFICATION_TX_KICK_DONE"))
	local loaded = 0
	Events.LoadGameViewStateDone.Add(function() loaded = loaded + 1 end)
	local envs = FAKE_TX.LoadUI()
	H.notnil(UI)
	H.eq(loaded, 1)
	for _, c in ipairs(FAKE_TX.CONTEXTS) do
		H.eq(envs[c.name] ~= nil, FAKE_TX.Exists(c.rel), c.rel)
	end
end)

-- ---------------------------------------------------------------------------
-- Kick modes (DEC 2026-10-04): the record's mode and hardDone
-- ---------------------------------------------------------------------------
test("store modes: a record saved without a mode loads as SOFT (no repair, no ERROR); HARD and hardDone round trip", function()
	Load()
	local old = Rec({ id = 1, state = "DONE", newTeamID = 6, applied = 1, doneTurn = 5 })
	old.mode = nil
	FAKE.props.TX_Store = {
		schema = 1, nextID = 3, lastTurn = 4, ids = { 1, 2 },
		recs = { r1 = old, r2 = Rec({ id = 2, mode = "HARD", state = "DONE", newTeamID = 7, applied = 1, doneTurn = 6, hardDone = 1 }) },
	}
	local store, repaired = TX_Store.Load()
	H.eq(repaired, false, "an old record is not a repair")
	H.eq(TX_Store.Get(store, 1).mode, "SOFT")
	include("TX_Votes")
	H.eq(TX_Votes.RecMode(old), "SOFT", "RecMode of a raw old record")
	H.eq(TX_Store.Get(store, 2).mode, "HARD")
	H.eq(TX_Store.Get(store, 2).hardDone, 1)
	H.eq(TX_Store.Commit(store), true)
	local back = TX_Store.Load()
	H.deq(back, store)
	H.eq(H.prop("TX_Store").recs.r1.mode, "SOFT", "written with the mode from then on")
	H.deq(FAKE.propViolations, {})
	H.clean()
end)

test("store modes: an unknown mode string is repaired to SOFT with an ERROR; a non-string mode or hardDone drops the record", function()
	Load()
	FAKE.props.TX_Store = {
		schema = 1, nextID = 4, lastTurn = 4, ids = { 1, 2, 3 },
		recs = {
			r1 = Rec({ id = 1, mode = "MEDIUM" }),
			r2 = Rec({ id = 2, mode = 1 }),
			r3 = Rec({ id = 3, state = "DONE", newTeamID = 6, applied = 1, mode = "HARD", hardDone = "yes" }),
		},
	}
	local store, repaired = TX_Store.Load()
	H.eq(repaired, true)
	H.eq(TX_Store.Get(store, 1).mode, "SOFT")
	H.isnil(TX_Store.Get(store, 2))
	H.isnil(TX_Store.Get(store, 3))
	H.ok(H.hasLine("[Store] ERROR normalize: record 1 had mode=MEDIUM; set to SOFT"))
	H.ok(H.hasLine("ERROR normalize: dropped malformed record key=r2 (mode is not a string)"))
	H.ok(H.hasLine("ERROR normalize: dropped malformed record key=r3 (hardDone is not a number)"))
end, { allowErrors = true })
